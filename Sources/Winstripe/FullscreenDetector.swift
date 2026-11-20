import AppKit
import ApplicationServices
import CoreGraphics

enum FullscreenDetector {
    private static let axFullscreenAttribute = "AXFullScreen" as CFString

    static func isFullscreen(frontmostPID: pid_t?, screen: NSScreen,
                             windowInfo: [[String: Any]]? = nil) -> Bool {
        guard let pid = frontmostPID else { return false }
        let info = windowInfo ?? (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                              kCGNullWindowID) as? [[String: Any]] ?? [])
        let screenFrame = screen.frame
        let cgFrame = Self.cgDisplayFrame(for: screen)
        if Self.hasCoveringWindow(info: info, ownerPID: pid, screenFrame: screenFrame, cgScreenFrame: cgFrame) {
            return true
        }
        return Self.axHasFullscreenWindow(pid: pid, screenFrame: screenFrame, cgScreenFrame: cgFrame)
    }

    static func hasCoveringWindow(info: [[String: Any]], ownerPID: pid_t,
                                  screenFrame: CGRect, cgScreenFrame: CGRect? = nil) -> Bool {
        info.contains { entry in
            guard let pid = Self.number(entry[kCGWindowOwnerPID as String])?.int32Value,
                  pid == ownerPID,
                  Self.number(entry[kCGWindowLayer as String])?.intValue == 0,
                  let bounds = Self.rect(entry[kCGWindowBounds as String]) else { return false }
            return Self.matches(bounds, screenFrame) ||
                (cgScreenFrame.map { Self.matches(bounds, $0) } ?? false)
        }
    }

    private static func axHasFullscreenWindow(pid: pid_t, screenFrame: CGRect, cgScreenFrame: CGRect?) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var fullscreen: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, Self.axFullscreenAttribute, &fullscreen) == .success,
                  (fullscreen as? NSNumber)?.boolValue == true else { continue }
            guard let frame = Self.axFrame(window) else { continue }
            if Self.matches(frame, screenFrame) || (cgScreenFrame.map { Self.matches(frame, $0) } ?? false) {
                return true
            }
        }
        return false
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func cgDisplayFrame(for screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private static func rect(_ value: Any?) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}

enum FullscreenSelfTest {
    @MainActor
    static func run() -> Int {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func window(pid: Int32, frame: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: 0),
             kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary]
        }
        let covering = [[String: Any]](arrayLiteral: window(pid: 42, frame: screen))
        let normal = [[String: Any]](arrayLiteral: window(pid: 42, frame: CGRect(x: 100, y: 100, width: 800, height: 600)))
        let otherScreen = [[String: Any]](arrayLiteral: window(pid: 42, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)))
        let checks = [
            ("panels-follow-desktop-spaces", TaskbarController.panelCollectionBehavior.contains(.canJoinAllSpaces)),
            ("panels-leave-fullscreen-edge-to-system", TaskbarController.panelCollectionBehavior.contains(.fullScreenNone)
                && !TaskbarController.panelCollectionBehavior.contains(.fullScreenAuxiliary)),
            ("covering-window", FullscreenDetector.hasCoveringWindow(info: covering, ownerPID: 42, screenFrame: screen)),
            ("normal-window", !FullscreenDetector.hasCoveringWindow(info: normal, ownerPID: 42, screenFrame: screen)),
            ("other-screen", !FullscreenDetector.hasCoveringWindow(info: otherScreen, ownerPID: 42, screenFrame: screen)),
            ("other-screen-target", FullscreenDetector.hasCoveringWindow(info: otherScreen, ownerPID: 42,
                                                                          screenFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)))
        ]
        let failed = checks.filter { !$0.1 }
        for check in checks {
            print("fullscreen " + check.0 + "=" + (check.1 ? "PASS" : "FAIL"))
        }
        if failed.isEmpty {
            print("PASS fullscreen-selftest")
            return 0
        }
        print("FAIL fullscreen-selftest")
        return 1
    }
}
