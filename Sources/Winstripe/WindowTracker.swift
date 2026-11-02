import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

@MainActor
final class WindowTracker {
    typealias Update = ([pid_t: [WindowEntry]], CGWindowID?) -> Void

    private var timer: Timer?
    private var observers: [pid_t: AXObserver] = [:]
    private var firstSeen: [CGWindowID: UInt64] = [:]
    private var nextStamp: UInt64 = 0
    private var update: Update?
    private var pending = false
    private var refreshInFlight = false

    private struct RawWindow {
        let pid: pid_t
        let title: String
        let minimized: Bool
        let frame: CGRect
        let element: AXUIElement
        let id: CGWindowID
        let idSource: String
    }

    func start(update: @escaping Update) {
        self.update = update
        refresh()
        timer?.invalidate()
        // Window changes arrive via AXObserver + NSWorkspace events; this is only a
        // slow safety net for anything an app fails to notify (e.g. moved windows).
        timer = Timer.scheduledTimer(withTimeInterval: Self.fallbackPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    static let fallbackPollInterval: TimeInterval = 15
    private var lastDelivered: (windows: [pid_t: [WindowEntry]], focused: CGWindowID?)?

    func stop() {
        timer?.invalidate()
        timer = nil
        for pid in observers.keys { tearDownObserver(pid: pid) }
    }

    func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            update?([:], nil)
            return
        }
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me
        }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = Self.query(apps: apps)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                self.apply(raw, apps: apps)
            }
        }
    }

    nonisolated private static func query(apps: [NSRunningApplication]) -> ([pid_t: [RawWindow]], CGWindowID?) {
        var result: [pid_t: [RawWindow]] = [:]
        for app in apps {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            var used = Set<CGWindowID>()
            let entries = windows.compactMap { window -> RawWindow? in
                // Minimized windows keep their taskbar button (like Windows). Some apps
                // (e.g. Safari) report AXDialog as the subrole while a window is in the
                // Dock, so a minimized AXWindow counts regardless of subrole.
                let minimized = Self.boolAttribute(window, kAXMinimizedAttribute as String)
                let standard = Self.stringAttribute(window, kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String
                guard standard || (minimized && Self.stringAttribute(window, kAXRoleAttribute as String) == kAXWindowRole as String) else { return nil }
                let title = Self.stringAttribute(window, kAXTitleAttribute as String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? app.localizedName ?? "Window"
                let frame = Self.axFrame(window) ?? .zero
                let lookup = Self.windowID(window, pid: pid, frame: frame, title: title, excluding: used)
                guard let id = lookup.id, used.insert(id).inserted else { return nil }
                return RawWindow(pid: pid, title: title, minimized: minimized, frame: frame,
                                 element: window, id: id, idSource: lookup.source)
            }
            result[pid] = entries
        }
        let focused = Self.focusedWindowID(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        return (result, focused)
    }

    private func apply(_ raw: ([pid_t: [RawWindow]], CGWindowID?), apps: [NSRunningApplication]) {
        let live = Set(apps.map(\.processIdentifier))
        for pid in observers.keys where !live.contains(pid) { tearDownObserver(pid: pid) }
        let byPID = Dictionary(firstWins: apps.map { ($0.processIdentifier, $0) })
        var result: [pid_t: [WindowEntry]] = [:]
        for (pid, windows) in raw.0 {
            guard let app = byPID[pid] else { continue }
            let elements = windows.map(\.element)
            let axApp = AXUIElementCreateApplication(pid)
            registerObserver(for: app, axApp: axApp, windows: elements)
            let entries = windows.map { window -> WindowEntry in
                if firstSeen[window.id] == nil { nextStamp += 1; firstSeen[window.id] = nextStamp }
                return WindowEntry(id: window.id, title: window.title, minimized: window.minimized,
                                  frame: window.frame, element: window.element,
                                  firstSeen: firstSeen[window.id] ?? 0, idSource: window.idSource)
            }.sorted { $0.firstSeen < $1.firstSeen }
            result[pid] = entries
        }
        // Only wake the taskbar when something actually changed.
        if let last = lastDelivered, last.windows == result, last.focused == raw.1 { return }
        lastDelivered = (result, raw.1)
        update?(result, raw.1)
    }

    private func registerObserver(for app: NSRunningApplication, axApp: AXUIElement, windows: [AXUIElement]) {
        let pid = app.processIdentifier
        if observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, Self.observerCallback, &observer) == .success, let observer else { return }
            observers[pid] = observer
            AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, nil)
            AXObserverAddNotification(observer, axApp, kAXUIElementDestroyedNotification as CFString, nil)
            AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard let observer = observers[pid] else { return }
        for window in windows {
            for notification in [kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(observer, window, notification as CFString, nil)
            }
        }
    }

    private func tearDownObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, _ in
        Task { @MainActor in NotificationCenter.default.post(name: .winstripeAXWindowChanged, object: nil) }
    }

    nonisolated private static func focusedWindowID(frontmostPID: pid_t?) -> CGWindowID? {
        guard let pid = frontmostPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        return windowID(window, pid: pid, frame: axFrame(window) ?? .zero, title: nil).id
    }

    nonisolated private static func windowID(_ element: AXUIElement, pid: pid_t, frame: CGRect, title: String?,
                                             excluding used: Set<CGWindowID> = []) -> (id: CGWindowID?, source: String) {
        // AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *) — returns
        // kAXErrorSuccess (0) on success, so it must not be read as a Bool.
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            let fn = unsafeBitCast(symbol, to: GetWindow.self)
            var id: CGWindowID = 0
            if fn(element, &id) == 0, id != 0, !used.contains(id) { return (id, "_AXUIElementGetWindow") }
        }
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return (nil, "fallback-matching")
        }
        let candidates = info.compactMap { entry -> (CGWindowID, CGRect, String?)? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let candidate = entry[kCGWindowNumber as String] as? NSNumber, !used.contains(candidate.uint32Value),
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (number.uint32Value, rect, entry[kCGWindowName as String] as? String)
        }
        return (candidates.min { score($0, frame: frame, title: title) < score($1, frame: frame, title: title) }?.0, "fallback-matching")
    }

    nonisolated private static func score(_ item: (CGWindowID, CGRect, String?), frame: CGRect, title: String?) -> CGFloat {
        let distance = abs(item.1.midX - frame.midX) + abs(item.1.midY - frame.midY) +
            abs(item.1.width - frame.width) + abs(item.1.height - frame.height)
        return distance + (title == nil || item.2 == title ? 0 : 1000)
    }

    nonisolated private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    nonisolated private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let p = position, let s = size else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(p, to: AXValue.self)
        let sizeValue = unsafeBitCast(s, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

extension Notification.Name {
    static let winstripeAXWindowChanged = Notification.Name("WinstripeAXWindowChanged")
}
