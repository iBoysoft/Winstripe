import AppKit
import ApplicationServices
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

@MainActor
enum ScreenRecordingAccess {
    static var preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    static var request: () -> Bool = { CGRequestScreenCaptureAccess() }
}

@MainActor
enum PreviewLog {
    static var enabled = false

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        print(line, terminator: "")
        let url = URL(fileURLWithPath: "/tmp/winstripe-preview.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Owns hover timing and a non-activating panel. Capture work exists only for a visible panel.
@MainActor
final class WindowPreviewController {
    private let now: () -> Date
    private let windowProvider: ((AppEntry) -> [WindowEntry])?
    private var panel: NSPanel?
    private var popup: WindowPreviewView?
    private var candidate: String?
    private var candidateSince = Date()
    private var outsideSince: Date?
    private var shownKey: String?
    private var app: AppEntry?
    private var selectedID: CGWindowID?
    private var settings = TaskbarSettings()
    private var anchor = NSRect.zero
    private var screenBounds = NSRect.zero
    private var refreshTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var generation = UUID()
    private var cache: [CGWindowID: (Date, NSImage)] = [:]
    private var monitors: [Any] = []
    private var menuObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var menuTracking = false
    private var mouseDown = false
    private var suppressedKey: String?
    private var hoveredButtonKey: String?
    private var hoveredButtonRect = NSRect.zero
    private var debugUntil: Date?
    var onWindowsChanged: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?

    init(now: @escaping () -> Date = Date.init,
         windowProvider: ((AppEntry) -> [WindowEntry])? = nil) {
        self.now = now
        self.windowProvider = windowProvider
    }

    var isVisible: Bool { panel?.isVisible == true }
    var hasPopupContent: Bool { popup != nil }
    var isShowingThumbnails: Bool { popup?.thumbnails == true }

    func startMonitoring() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                          .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleMouseEvent(event, local: true)
            }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event, local: false) }
        }) { monitors.append(global) }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true; self?.hide() }
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.menuTracking = false } }
    }

    private func handleMouseEvent(_ event: NSEvent, local: Bool) {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            mouseDown = false
        default:
            mouseDown = true
            if !local || event.window !== panel || event.type != .leftMouseDown {
                if event.type == .leftMouseDown,
                   let hoveredButtonKey, hoveredButtonRect.contains(NSEvent.mouseLocation) {
                    suppressedKey = hoveredButtonKey
                }
                hide()
            }
        }
    }

    /// Test hook for the task-button portion of a click. Popup-panel clicks use the normal event path.
    func selfTestMouseDownOnTaskButton() {
        suppressedKey = hoveredButtonKey ?? candidate
        mouseDown = true
        hide()
    }

    func selfTestMouseUp() { mouseDown = false }

    func stop() {
        hide()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        menuObserver = nil
        menuEndObserver = nil
    }

    func poll(button: (pid: pid_t, windowID: CGWindowID?, rect: NSRect)?,
              apps: [AppEntry], settings: TaskbarSettings, screen: NSScreen?, blocked: Bool) {
        if isVisible, let app, !apps.contains(where: { $0.pid == app.pid }) {
            hide()
            return
        }
        if let debugUntil {
            if now() >= debugUntil { hide() }
            return
        }
        let currentKey: String? = button.flatMap { button in
            apps.first(where: { $0.pid == button.pid }).map { _ in "\(button.pid):\(button.windowID ?? 0)" }
        }
        if suppressedKey != nil, currentKey != suppressedKey { suppressedKey = nil }
        guard settings.showWindowPreviews, !blocked, !menuTracking, !mouseDown else {
            // A press in the popup must be allowed to finish its click.
            if mouseDown && panel?.frame.contains(NSEvent.mouseLocation) == true && !menuTracking && !blocked { return }
            hide()
            return
        }
        if let button, let app = apps.first(where: { $0.pid == button.pid }) {
            let key = "\(button.pid):\(button.windowID ?? 0)"
            hoveredButtonKey = key
            hoveredButtonRect = button.rect
            outsideSince = nil
            if suppressedKey == key {
                candidate = nil
                return
            }
            if candidate != key {
                candidate = key
                candidateSince = now()
            }
            if shownKey == key {
                self.anchor = button.rect
                update(app: app)
                position()
            } else if now().timeIntervalSince(candidateSince) >= 0.4 {
                show(app: app, windowID: button.windowID, anchor: button.rect,
                     settings: settings, screen: screen, key: key)
            }
        } else {
            hoveredButtonKey = nil
            hoveredButtonRect = .zero
            candidate = nil
            if panel?.frame.contains(NSEvent.mouseLocation) == true {
                outsideSince = nil
                if let app = apps.first(where: { $0.pid == self.app?.pid }) { update(app: app) }
            } else if isVisible {
                if outsideSince == nil { outsideSince = now() }
                if now().timeIntervalSince(outsideSince ?? now()) >= 0.3 { hide() }
            }
        }
    }

    func debugShow(app: AppEntry, windowID: CGWindowID?, anchor: NSRect,
                   settings: TaskbarSettings, screen: NSScreen?) {
        PreviewLog.enabled = true
        show(app: app, windowID: windowID, anchor: anchor, settings: settings, screen: screen,
             key: "\(app.pid):\(windowID ?? 0)")
        debugUntil = now().addingTimeInterval(5)
        PreviewLog.write("preview pid=\(app.pid) windows=\(popup?.entries.count ?? 0) frame=\(panel.map { NSStringFromRect($0.frame) } ?? "none") visible=\(isVisible)")
    }

    func hide() {
        let wasVisible = isVisible
        captureTask?.cancel()
        captureTask = nil
        generation = UUID()
        refreshTimer?.invalidate()
        refreshTimer = nil
        panel?.orderOut(nil)
        popup = nil
        panel?.contentView = nil
        app = nil
        shownKey = nil
        candidate = nil
        outsideSince = nil
        debugUntil = nil
        if wasVisible { onVisibilityChanged?() }
    }

    private func show(app: AppEntry, windowID: CGWindowID?, anchor: NSRect,
                      settings: TaskbarSettings, screen: NSScreen?, key: String) {
        hide()
        self.app = app
        self.selectedID = windowID
        self.settings = settings
        self.anchor = anchor
        screenBounds = screen.map {
            NSRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width,
                   height: $0.visibleFrame.maxY - $0.frame.minY)
        } ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let classic = WindowPreviewView.titleListTheme(settings.theme)
        let recording = ScreenRecordingAccess.preflight()
        // CGWindowListCreateImage is obsoleted in the current SDK; macOS 13 uses titles.
        let thumbnails: Bool
        // Capturing needs the macOS 14 SDK, so a build from Xcode 14 shows no thumbnails.
        #if compiler(>=5.9)
        if #available(macOS 14, *) { thumbnails = recording && !classic }
        else { thumbnails = false }
        #else
        thumbnails = false
        #endif
        let entries = windows(for: app)
        let content = WindowPreviewView(app: app, entries: entries, settings: settings,
                                        thumbnails: thumbnails, maximumSize: availableSize())
        content.onActivate = { [weak self] entry in self?.activate(entry) }
        content.onClose = { [weak self] entry in self?.close(entry) }
        popup = content
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isReleasedWhenClosed = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            panel = p
        }
        // Assigning contentView resizes the view to the panel's current content size,
        // so size the panel to the popup's preferred size first.
        let preferred = content.frame.size
        panel?.setContentSize(preferred)
        panel?.contentView = content
        content.frame.size = preferred
        position()
        panel?.orderFrontRegardless()
        shownKey = key
        for entry in entries {
            PreviewLog.write("pid=\(app.pid) id=\(entry.id) title=\(entry.title) \(thumbnails && !entry.minimized ? "pending" : "title-only")")
        }
        refreshCaptures()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let app = self.app else { return }
                self.update(app: app)
                self.refreshCaptures()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func availableSize() -> NSSize {
        let gap: CGFloat = 4
        switch settings.edge {
        case .bottom: return NSSize(width: screenBounds.width - 8, height: screenBounds.maxY - anchor.maxY - gap)
        case .top: return NSSize(width: screenBounds.width - 8, height: anchor.minY - screenBounds.minY - gap)
        case .left: return NSSize(width: screenBounds.maxX - anchor.maxX - gap, height: screenBounds.height - 8)
        case .right: return NSSize(width: anchor.minX - screenBounds.minX - gap, height: screenBounds.height - 8)
        }
    }

    private func position() {
        guard let panel, let popup else { return }
        var rect = NSRect(origin: .zero, size: popup.frame.size)
        switch settings.edge {
        case .bottom: rect.origin = NSPoint(x: anchor.midX - rect.width / 2, y: anchor.maxY + 4)
        case .top: rect.origin = NSPoint(x: anchor.midX - rect.width / 2, y: anchor.minY - rect.height - 4)
        case .left: rect.origin = NSPoint(x: anchor.maxX + 4, y: anchor.midY - rect.height / 2)
        case .right: rect.origin = NSPoint(x: anchor.minX - rect.width - 4, y: anchor.midY - rect.height / 2)
        }
        rect.origin.x = max(screenBounds.minX, min(rect.minX, screenBounds.maxX - rect.width))
        rect.origin.y = max(screenBounds.minY, min(rect.minY, screenBounds.maxY - rect.height))
        panel.setFrame(rect, display: true)
    }

    private func windows(for app: AppEntry) -> [WindowEntry] {
        if let windowProvider { return windowProvider(app) }
        // Some apps expose no AXStandardWindow entries even when Accessibility is
        // trusted (custom-rendered windows such as WeChat are a common example).
        // Fall back to CGWindowList whenever the AX result is empty so a hover
        // preview still has content.
        let axEntries = app.windows
        let discovered = AXIsProcessTrusted() && !axEntries.isEmpty
            ? axEntries
            : Self.cgWindows(app: app, language: settings.resolvedLanguage)
        // A sandboxed App Store build can be trusted by TCC while both AX and
        // CGWindowList still return no per-window data. Keep the hover useful
        // by showing a title row that activates the application as a whole.
        let entries = discovered.isEmpty ? [Self.fallbackWindow(for: app)] : discovered
        guard let selectedID else { return entries }
        let selected = entries.filter { $0.id == selectedID }
        // AX and CGWindowList can briefly disagree while a window is being
        // created or rebuilt. Show the available app windows in that case.
        return selected.isEmpty ? entries : selected
    }

    static func fallbackWindow(for app: AppEntry) -> WindowEntry {
        WindowEntry(id: 0, title: app.name, minimized: false, frame: .zero,
                    element: nil, firstSeen: 0, idSource: "app-fallback")
    }

    static func cgWindows(app: AppEntry, language: Language) -> [WindowEntry] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { item -> WindowEntry? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  // .optionAll also returns ordered-out backing windows; keep real, visible document windows.
                  (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  frame.width >= 40, frame.height >= 40 else { return nil }
            let title = (item[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WindowEntry(id: id, title: title ?? "", minimized: false, frame: frame,
                               element: nil, firstSeen: UInt64(id), idSource: "CGWindowList")
        }.sorted { $0.id < $1.id }.enumerated().map { index, entry in
            guard entry.title.isEmpty else { return entry }
            return WindowEntry(id: entry.id, title: "\(app.name) - \(L.t("Window", language)) \(index + 1)",
                               minimized: false, frame: entry.frame, element: nil,
                               firstSeen: entry.firstSeen, idSource: entry.idSource)
        }
    }

    private func update(app: AppEntry) {
        guard isVisible, let popup else { return }
        self.app = app
        let entries = windows(for: app)
        guard !entries.isEmpty else { hide(); return }
        if entries != popup.entries {
            popup.replace(entries: entries, maximumSize: availableSize())
            position()
        }
    }

    private func activate(_ entry: WindowEntry) {
        guard let app else { return }
        if let element = entry.element {
            _ = WindowActivator.activateWindow(pid: app.pid, window: element, minimized: entry.minimized)
        } else if let running = NSRunningApplication(processIdentifier: app.pid) {
            WindowActivator.activate(pid: app.pid, app: running, state: WindowActivator.ReopenState())
        }
        hide()
    }

    private func close(_ entry: WindowEntry) {
        guard let element = entry.element, AXIsProcessTrusted() else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let button = unsafeBitCast(value, to: AXUIElement.self)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        PreviewLog.write("close id=\(entry.id) result=\(result.rawValue)")
        // A successful press can open a save dialog; wait for the tracker to confirm destruction.
        if result == .success { onWindowsChanged?() }
    }

    private func refreshCaptures() {
        guard isVisible, let popup, popup.thumbnails, captureTask == nil,
              ScreenRecordingAccess.preflight() else { return }
        cache = cache.filter { now().timeIntervalSince($0.value.0) < 2 }
        let entries = popup.entries.filter { !$0.minimized }
        let uncached = entries.filter { cache[$0.id] == nil }
        for entry in entries {
            if let image = cache[entry.id]?.1 {
                popup.setImage(image, id: entry.id)
                PreviewLog.write("id=\(entry.id) captured ok (cached)")
            }
        }
        guard !uncached.isEmpty else { return }
        let token = generation
        let scale = panel?.screen?.backingScaleFactor ?? 2
        let targetPID = app?.pid
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.captureTask = nil } }
            guard #available(macOS 12.3, *) else { return }
            #if canImport(ScreenCaptureKit) && compiler(>=5.9)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                for entry in uncached {
                    guard !Task.isCancelled, self.generation == token, self.isVisible else { return }
                    guard self.popup?.entries.contains(where: { $0.id == entry.id && !$0.minimized }) == true else { continue }
                    let window = content.windows.first(where: { $0.windowID == entry.id })
                        ?? (entry.id == 0 ? content.windows.first(where: {
                            $0.owningApplication?.processID == targetPID && $0.isOnScreen
                        }) : nil)
                    guard let window else {
                        PreviewLog.write("id=\(entry.id) failed: SCWindow not found")
                        continue
                    }
                    do {
                        let ratio = min(200 / max(1, window.frame.width), 130 / max(1, window.frame.height))
                        let config = SCStreamConfiguration()
                        config.width = max(1, Int(window.frame.width * ratio * scale))
                        config.height = max(1, Int(window.frame.height * ratio * scale))
                        config.showsCursor = false
                        guard #available(macOS 14.0, *) else { continue }
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                        guard !Task.isCancelled, self.generation == token, self.isVisible else { return }
                        let thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                                          height: CGFloat(image.height) / scale))
                        self.cache[entry.id] = (self.now(), thumbnail)
                        self.popup?.setImage(thumbnail, id: entry.id)
                        PreviewLog.write("id=\(entry.id) captured ok")
                    } catch {
                        guard self.generation == token else { return }
                        PreviewLog.write("id=\(entry.id) failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                guard self.generation == token else { return }
                for entry in uncached {
                    PreviewLog.write("id=\(entry.id) failed: \(error.localizedDescription)")
                }
            }
            #endif
        }
    }
}

@MainActor
enum WindowPreviewSelfTest {
    static func run() -> Int {
        let originalPreflight = ScreenRecordingAccess.preflight
        let originalRequest = ScreenRecordingAccess.request
        defer {
            ScreenRecordingAccess.preflight = originalPreflight
            ScreenRecordingAccess.request = originalRequest
        }

        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        var clock = Date(timeIntervalSince1970: 10_000)
        let window = WindowEntry(id: 7, title: "Demo", minimized: false, frame: .zero,
                                 element: nil, firstSeen: 1, idSource: "selftest")
        let app = AppEntry(pid: 42, name: "Demo", icon: nil, windowCount: 1, isHidden: false,
                           windows: [window])
        let button = (pid: app.pid, windowID: Optional(window.id), rect: NSRect(x: 10, y: 10, width: 80, height: 30))
        var settings = TaskbarSettings()
        settings.theme = .win95
        settings.showWindowPreviews = true
        ScreenRecordingAccess.preflight = { true }
        ScreenRecordingAccess.request = { failures.append("unexpected request"); return false }

        let controller = WindowPreviewController(now: { clock }, windowProvider: { $0.windows })
        controller.poll(button: button, apps: [app], settings: settings, screen: nil, blocked: false)
        check(!controller.hasPopupContent, "hover before 400ms")
        clock = clock.addingTimeInterval(0.41)
        controller.poll(button: button, apps: [app], settings: settings, screen: nil, blocked: false)
        check(controller.hasPopupContent, "hover at 400ms")

        controller.selfTestMouseDownOnTaskButton()
        controller.selfTestMouseUp()
        clock = clock.addingTimeInterval(1.1)
        controller.poll(button: button, apps: [app], settings: settings, screen: nil, blocked: false)
        check(!controller.hasPopupContent, "same button stays suppressed after click")

        clock = clock.addingTimeInterval(0.1)
        controller.poll(button: nil, apps: [app], settings: settings, screen: nil, blocked: false)
        controller.poll(button: button, apps: [app], settings: settings, screen: nil, blocked: false)
        clock = clock.addingTimeInterval(0.41)
        controller.poll(button: button, apps: [app], settings: settings, screen: nil, blocked: false)
        check(controller.hasPopupContent, "rehover after leaving button")

        let otherWindow = WindowEntry(id: 8, title: "Other", minimized: false, frame: .zero,
                                      element: nil, firstSeen: 2, idSource: "selftest")
        let otherApp = AppEntry(pid: 43, name: "Other", icon: nil, windowCount: 1, isHidden: false,
                                windows: [otherWindow])
        let otherButton = (pid: otherApp.pid, windowID: Optional(otherWindow.id), rect: NSRect(x: 100, y: 10, width: 80, height: 30))
        controller.selfTestMouseDownOnTaskButton()
        controller.selfTestMouseUp()
        controller.poll(button: otherButton, apps: [app, otherApp], settings: settings, screen: nil, blocked: false)
        clock = clock.addingTimeInterval(0.41)
        controller.poll(button: otherButton, apps: [app, otherApp], settings: settings, screen: nil, blocked: false)
        check(controller.hasPopupContent, "different button rearms hover")

        var requestCount = 0
        ScreenRecordingAccess.preflight = { false }
        ScreenRecordingAccess.request = { requestCount += 1; return false }
        var modernSettings = settings
        modernSettings.theme = .win10
        var modernClock = clock
        let modernController = WindowPreviewController(now: { modernClock }, windowProvider: { $0.windows })
        modernController.poll(button: button, apps: [app], settings: modernSettings, screen: nil, blocked: false)
        modernClock = modernClock.addingTimeInterval(0.41)
        modernController.poll(button: button, apps: [app], settings: modernSettings, screen: nil, blocked: false)
        check(modernController.hasPopupContent, "permission denied still shows preview")
        check(!modernController.isShowingThumbnails, "permission denied shows title-only")
        check(requestCount == 0, "hover never requests screen recording")

        if failures.isEmpty {
            print("PASS preview click selftest")
            return 0
        }
        fputs("FAIL preview click selftest \(failures.joined(separator: ","))\n", stderr)
        return 1
    }
}

/// Snapshot fixtures share the actual popup and taskbar renderers; no capture or permission requests.
@MainActor
final class WindowPreviewSnapshotView: NSView {
    init(settings: TaskbarSettings, app: AppEntry) {
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 250))
        var demo = settings
        demo.edge = .bottom
        demo.taskbarGrouping = .alwaysCombine
        let barHeight = TaskbarView.thickness(for: demo)
        let bar = TaskbarView(frame: NSRect(x: 0, y: bounds.height - barHeight,
                                           width: bounds.width, height: barHeight))
        bar.isPreview = true
        bar.settings = demo
        bar.apps = [app]
        bar.activePID = app.pid
        bar.clockText = "10:24"
        bar.reload()
        addSubview(bar)
        let popup = WindowPreviewView(app: app, entries: app.windows, settings: demo,
                                      thumbnails: !WindowPreviewView.titleListTheme(demo.theme),
                                      maximumSize: NSSize(width: 600, height: 190))
        popup.frame.origin = NSPoint(x: 80, y: bar.frame.minY - popup.frame.height - 4)
        for (index, entry) in app.windows.enumerated() {
            let fake = SyntheticPreviewWindow(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            fake.title = entry.title
            fake.tint = index == 0 ? NSColor(hex: 0x3C87B7) : NSColor(hex: 0x4F9463)
            if SnapshotFixture.isActive { fake.appearance = NSAppearance(named: .aqua) }
            if let rep = SnapshotFixture.bitmap(for: fake) {
                fake.cacheDisplay(in: fake.bounds, to: rep)
                let image = NSImage(size: fake.bounds.size)
                image.addRepresentation(rep)
                popup.setImage(image, id: entry.id)
            }
        }
        popup.syntheticHover()
        addSubview(popup)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x008080).setFill()
        bounds.fill()
    }
}

@MainActor
private final class SyntheticPreviewWindow: NSView {
    var title = ""
    var tint = NSColor.systemBlue
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0xF4F5F6).setFill()
        bounds.fill()
        tint.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 20).fill()
        Retro.drawText(title, in: NSRect(x: 6, y: 0, width: 150, height: 20),
                       font: .systemFont(ofSize: 10), color: .white, smoothing: true)
        NSColor.white.setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: 185, y: 7)); cross.line(to: NSPoint(x: 191, y: 13))
        cross.move(to: NSPoint(x: 191, y: 7)); cross.line(to: NSPoint(x: 185, y: 13))
        cross.stroke()
        tint.withAlphaComponent(0.25).setFill()
        NSRect(x: 8, y: 28, width: 42, height: 84).fill()
        for row in 0..<4 {
            NSColor(hex: 0xC5CCD2).setFill()
            NSRect(x: 60, y: 32 + CGFloat(row) * 18, width: row == 3 ? 85 : 130, height: 7).fill()
        }
    }
}

@MainActor
final class WindowPreviewView: NSView {
    private(set) var entries: [WindowEntry]
    let thumbnails: Bool
    let app: AppEntry
    let settings: TaskbarSettings
    var onActivate: ((WindowEntry) -> Void)?
    var onClose: ((WindowEntry) -> Void)?
    private let scroll = NSScrollView()
    private let document = NSView()
    private var items: [WindowPreviewItem] = []
    private var images: [CGWindowID: NSImage] = [:]

    static func titleListTheme(_ kind: ThemeKind) -> Bool { kind.capabilities.previewStyle == .titleList }

    init(app: AppEntry, entries: [WindowEntry], settings: TaskbarSettings,
         thumbnails: Bool, maximumSize: NSSize) {
        self.app = app
        self.entries = entries
        self.settings = settings
        self.thumbnails = thumbnails
        super.init(frame: .zero)
        if settings.theme == .win11 {
            let acrylic = NSVisualEffectView()
            acrylic.material = .popover
            acrylic.blendingMode = .behindWindow
            acrylic.state = .active
            acrylic.wantsLayer = true
            acrylic.layer?.cornerRadius = 8
            acrylic.layer?.masksToBounds = true
            acrylic.autoresizingMask = [.width, .height]
            addSubview(acrylic)
        }
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        addSubview(scroll)
        replace(entries: entries, maximumSize: maximumSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func replace(entries: [WindowEntry], maximumSize: NSSize) {
        self.entries = entries
        items.forEach { $0.removeFromSuperview() }
        let width: CGFloat = thumbnails ? 216 : 300
        let height: CGFloat = thumbnails ? 166 : 30
        let docSize = thumbnails ? NSSize(width: width * CGFloat(entries.count), height: height)
            : NSSize(width: width, height: height * CGFloat(entries.count))
        let size = NSSize(width: min(docSize.width + 12, max(32, maximumSize.width)),
                          height: min(docSize.height + 12, max(32, maximumSize.height)))
        frame.size = size
        subviews.first(where: { $0 is NSVisualEffectView })?.frame = bounds
        scroll.frame = bounds.insetBy(dx: 6, dy: 6)
        scroll.hasHorizontalScroller = docSize.width > scroll.frame.width
        scroll.hasVerticalScroller = docSize.height > scroll.frame.height
        scroll.autohidesScrollers = true
        document.frame = NSRect(origin: .zero, size: docSize)
        items = entries.enumerated().map { index, entry in
            let rect = thumbnails
                ? NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
                : NSRect(x: 0, y: docSize.height - CGFloat(index + 1) * height, width: width, height: height)
            let item = WindowPreviewItem(frame: rect, entry: entry, app: app, settings: settings,
                                         thumbnails: thumbnails)
            item.image = images[entry.id]
            item.onActivate = { [weak self] in self?.onActivate?(entry) }
            item.onClose = { [weak self] in self?.onClose?(entry) }
            document.addSubview(item)
            return item
        }
        needsDisplay = true
    }

    func setImage(_ image: NSImage, id: CGWindowID) {
        images[id] = image
        items.first { $0.entry.id == id }?.image = image
    }

    func syntheticHover() { items.first?.syntheticHover = true }

    override func draw(_ dirtyRect: NSRect) {
        let kind = settings.theme
        if Self.titleListTheme(kind) {
            NSColor(hex: 0xFFFFE1).setFill()
            bounds.fill()
            let frameTheme = Theme.make(.win95)
            if let c = frameTheme.classicConfig { c.bevel("raised", in: bounds) }
            else { Retro.raised(bounds, frameTheme) }
        } else if kind == .vista || kind == .win7 {
            Retro.fill(bounds.insetBy(dx: 0.5, dy: 0.5),
                       [NSColor(hex: 0x41617E, alpha: 0.96), NSColor(hex: 0x111D28, alpha: 0.96)], radius: 6)
            NSColor(white: 1, alpha: 0.5).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).stroke()
        } else if kind == .win11 {
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        } else {
            NSColor(hex: 0x2B2B2B).setFill()
            bounds.fill()
        }
    }
}

@MainActor
private final class WindowPreviewItem: NSView {
    let entry: WindowEntry
    let app: AppEntry
    let settings: TaskbarSettings
    let thumbnails: Bool
    var image: NSImage? { didSet { needsDisplay = true } }
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var syntheticHover = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var closeHovered = false
    private var downInClose: Bool?
    private var canClose: Bool { syntheticHover || (entry.element != nil && AXIsProcessTrusted()) }
    private var closeRect: NSRect { NSRect(x: bounds.width - 28, y: 2, width: 26, height: 24) }

    init(frame: NSRect, entry: WindowEntry, app: AppEntry, settings: TaskbarSettings, thumbnails: Bool) {
        self.entry = entry
        self.app = app
        self.settings = settings
        self.thumbnails = thumbnails
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityLabel(entry.title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        closeHovered = closeRect.contains(convert(event.locationInWindow, from: nil))
        toolTip = closeHovered && canClose ? L.t("Close window", settings.resolvedLanguage) : entry.title
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        closeHovered = false
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        downInClose = canClose && closeRect.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { downInClose = nil }
        guard let downInClose, bounds.contains(point) else { return }
        if downInClose {
            if closeRect.contains(point) { onClose?() }
        } else if !closeRect.contains(point) || !canClose { onActivate?() }
    }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let classic = WindowPreviewView.titleListTheme(settings.theme)
        let aero = settings.theme == .vista || settings.theme == .win7
        let hot = hovered || syntheticHover
        let text: NSColor = classic ? .black : (settings.theme == .win11 ? .labelColor : .white)
        if hot {
            if aero { AeroDrawing.button(bounds.insetBy(dx: 1, dy: 1), active: false, hovered: true, pressed: false) }
            else {
                (classic ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.15)
                    : text.withAlphaComponent(0.10)).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                             xRadius: settings.theme == .win11 ? 4 : 0,
                             yRadius: settings.theme == .win11 ? 4 : 0).fill()
            }
        }
        if let icon = app.icon { Retro.drawImage(icon, in: NSRect(x: 6, y: 6, width: 16, height: 16)) }
        Retro.drawText(entry.title, in: NSRect(x: 28, y: 0, width: bounds.width - 60, height: 28),
                       font: classic ? NSFont.menuFont(ofSize: 12) : NSFont.systemFont(ofSize: 12),
                       color: text, smoothing: settings.fontSmoothing)
        if hot && canClose {
            if closeHovered {
                NSColor(hex: 0xE81123).setFill()
                closeRect.fill()
            }
            let color: NSColor = closeHovered ? .white : text
            let path = NSBezierPath()
            let center = NSPoint(x: closeRect.midX, y: closeRect.midY)
            path.move(to: NSPoint(x: center.x - 4, y: center.y - 4))
            path.line(to: NSPoint(x: center.x + 4, y: center.y + 4))
            path.move(to: NSPoint(x: center.x + 4, y: center.y - 4))
            path.line(to: NSPoint(x: center.x - 4, y: center.y + 4))
            path.lineWidth = 1.5
            color.setStroke()
            path.stroke()
        }
        guard thumbnails else { return }
        let area = NSRect(x: 8, y: 30, width: 200, height: 130)
        if entry.minimized {
            if let icon = app.icon { Retro.drawImage(icon, in: NSRect(x: area.midX - 24, y: area.midY - 24, width: 48, height: 48)) }
        } else if let image {
            let ratio = min(area.width / max(1, image.size.width), area.height / max(1, image.size.height))
            let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let rect = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height)
            Retro.drawImage(image, in: rect)
            text.withAlphaComponent(0.4).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
        } else if let icon = app.icon {
            Retro.drawImage(icon, in: NSRect(x: area.midX - 24, y: area.midY - 24, width: 48, height: 48))
        }
    }
}
