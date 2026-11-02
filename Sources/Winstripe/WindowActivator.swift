import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

@MainActor
enum WindowActivationResult: String {
    case raised
    case restoredMinimized
    case noWindows
    case notTrusted
    case axError
}

@MainActor
enum ActivationLog {
    static var fileEnabled = false
    static var noAXPrompt = false
    private static let fileURL = URL(fileURLWithPath: "/tmp/winstripe-activate.log")

    static func write(_ message: String) {
        debugLog(message)
        guard fileEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

@MainActor
enum WindowActivator {
    final class ReopenState {
        var sent = false
    }

    static func visibleFrontWindowPID(excluding excludedPID: pid_t = getpid()) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 50, rect.height >= 50,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value != excludedPID else { continue }
            return ownerPID.int32Value
        }
        return nil
    }

    static func hasVisibleFrontWindow(pid: pid_t) -> Bool {
        visibleFrontWindowPID() == pid
    }

    static func hasAnyVisibleWindow(pid: pid_t) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return info.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 50, rect.height >= 50,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber else { return false }
            return ownerPID.int32Value == pid
        }
    }

    static func activate(pid: pid_t, app: NSRunningApplication, state: ReopenState) {
        let trusted = AXIsProcessTrusted()
        ActivationLog.write("activate target=\(app.localizedName ?? "?") pid=\(pid) trusted=\(trusted)")

        let visible = hasAnyVisibleWindow(pid: pid)
        if !trusted && !visible && !ActivationLog.noAXPrompt &&
            !Prefs.defaults.bool(forKey: "askedAccessibility") {
            Prefs.defaults.set(true, forKey: "askedAccessibility")
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            )
            ActivationLog.write("accessibility prompt requested")
        }

        var result: WindowActivationResult = .notTrusted
        if trusted {
            result = raiseWindow(pid: pid)
            ActivationLog.write("AX result=\(result.rawValue)")
        } else {
            ActivationLog.write("AX result=notTrusted")
        }

        if result == .noWindows || (!trusted && !visible) {
            sendReopen(pid: pid, app: app, state: state)
        }
        bringToFront(app)
    }

    static func verifyAndRetry(pid: pid_t, app: NSRunningApplication, state: ReopenState) {
        if hasVisibleFrontWindow(pid: pid) {
            ActivationLog.write("verify visible front window pid=\(pid)")
            return
        }
        ActivationLog.write("verify failed; retrying AX")
        if AXIsProcessTrusted() {
            let result = raiseWindow(pid: pid)
            ActivationLog.write("AX retry result=\(result.rawValue)")
        }
        bringToFront(app)
        if !hasVisibleFrontWindow(pid: pid) {
            ActivationLog.write("verify still has no visible window")
            sendReopen(pid: pid, app: app, state: state)
        } else {
            ActivationLog.write("verify succeeded after retry")
        }
    }

    static func activateWindow(pid: pid_t, window: AXUIElement, minimized: Bool) -> WindowActivationResult {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .axError }
        let application = AXUIElementCreateApplication(pid)
        if minimized {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.unhide()
        // Xcode 14's SDK has neither call; Swift 5.9 came with the macOS 14 SDK.
        #if compiler(>=5.9)
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: [.activateAllWindows])
        }
        #else
        app.activate(options: [.activateAllWindows])
        #endif
        return raise == .success ? (minimized ? .restoredMinimized : .raised) : .axError
    }

    private static func raiseWindow(pid: pid_t) -> WindowActivationResult {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let windowsStatus = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard windowsStatus == .success, let windowArray = value as? [AXUIElement] else {
            return windowsStatus == .attributeUnsupported ? .noWindows : .axError
        }

        let standard = windowArray.filter { window in
            let subrole = stringAttribute(window, kAXSubroleAttribute as String)
            let role = stringAttribute(window, kAXRoleAttribute as String)
            return subrole == kAXStandardWindowSubrole as String ||
                (subrole == nil && role == kAXWindowRole as String)
        }
        guard !standard.isEmpty else { return .noWindows }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attribute as CFString, &focused) == .success,
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(focused, to: AXUIElement.self)
                guard standard.contains(where: { CFEqual($0, window) }),
                      !boolAttribute(window, kAXMinimizedAttribute as String) else { continue }
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                return .raised
            }
        }

        if let window = standard.first(where: { !boolAttribute($0, kAXMinimizedAttribute as String) }) {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            return .raised
        }

        guard let window = standard.first else { return .noWindows }
        let restoreStatus = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard restoreStatus == .success else { return .axError }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return .restoredMinimized
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func sendReopen(pid: pid_t, app: NSRunningApplication, state: ReopenState) {
        guard !state.sent else { return }
        state.sent = true
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let status = AESendMessage(event.aeDesc, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
        ActivationLog.write("reopen pid=\(pid) OSStatus=\(status)")
        if status != noErr, let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            ActivationLog.write("reopen fallback Launch Services requested")
        }
    }

    private static func bringToFront(_ app: NSRunningApplication) {
        app.unhide()
        // Xcode 14's SDK has neither call; Swift 5.9 came with the macOS 14 SDK.
        #if compiler(>=5.9)
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: [.activateAllWindows])
        }
        #else
        app.activate(options: [.activateAllWindows])
        #endif
    }
}
