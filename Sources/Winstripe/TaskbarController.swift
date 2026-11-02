import AppKit
import Carbon
import SwiftUI

private final class TaskMenuWindowContext {
    let pid: pid_t
    let window: WindowEntry
    init(pid: pid_t, window: WindowEntry) {
        self.pid = pid
        self.window = window
    }
}

private final class TaskMenuAppContext {
    let pid: pid_t
    let bundleID: String?
    let path: String?
    init(pid: pid_t, bundleID: String?, path: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.path = path
    }
}

private final class TaskMenuCloseContext {
    let app: AppEntry
    let windowID: CGWindowID?
    init(app: AppEntry, windowID: CGWindowID?) {
        self.app = app
        self.windowID = windowID
    }
}

@MainActor
private final class TaskbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the taskbar panel and wires it to NSWorkspace, timers, and settings.
@MainActor
final class TaskbarController: NSObject, TaskbarViewDelegate {
    private(set) var displayID: CGDirectDisplayID?
    /// The primary bar uses the primary screen as its last-resort fallback; extra bars hide.
    var followsPrimaryScreen = true
    /// Called when transient bar UI closes so active-display tracking can retry.
    var onTransientUIChanged: (@MainActor () -> Void)?
    /// Injectable for the screen-change self-test.
    var screenProvider: () -> [ScreenInfo] = { DisplayGeometry.current() }
    private var screenUpdateGeneration = 0
    private var lastScreenSignature: ScreenInfo?
    private(set) var screenGeometryApplyCount = 0
    private var store: SettingsStore { SettingsStore.shared }
    private let pinStore = PinStore()
    private var panelStorage: NSPanel?
    private var viewStorage: TaskbarView?
    private var panel: NSPanel {
        guard let panelStorage else { preconditionFailure("Taskbar panel accessed before start") }
        return panelStorage
    }
    private var view: TaskbarView {
        guard let viewStorage else { preconditionFailure("Taskbar view accessed before start") }
        return viewStorage
    }
    private lazy var startMenu = StartMenuController(owner: self)
    private let properties = PropertiesWindowController()

    private var order: [pid_t] = []
    private(set) var apps: [AppEntry] = []
    private(set) var activePID: pid_t?
    private var badges: [String: String] = [:]
    private var lastBadgeFetch = Date.distantPast
    private var hiddenByShowDesktop: [NSRunningApplication] = []
    private var trayExpanded = false
    private var isAutoHidden = false
    private var hiddenByFullscreen = false
    private var fullscreenCheckGeneration = 0
    private weak var trackedMenu: NSMenu?
    private var lastInside = Date()
    private var lastPreviewPoll = Date.distantPast
    private var appliedThemeID: String?
    private var themeApplyGeneration = 0
    private var timers: [Timer] = []
    private var blockObservers: [NSObjectProtocol] = []
    private(set) var isStopped = false
    private var clockTimer: Timer?
    private var orbPanel: NSPanel?
    private var orbButton: RetroButton?
    private let windowTracker = WindowTracker()
    private var trackedWindows: [pid_t: [WindowEntry]] = [:]
    private var focusedWindowID: CGWindowID?
    private let windowPreview = WindowPreviewController()
    private let themeWatcher = ThemeHotReloadCore()

    var isBarMenuOpen: Bool {
        startMenu.isOpen || windowPreview.isVisible || viewStorage?.tray.isOverflowPanelOpen == true ||
            trackedMenu != nil || NSApp.modalWindow != nil
    }

    init(screen: NSScreen? = nil) {
        displayID = screen.flatMap(DisplayGeometry.displayID(of:))
        super.init()
    }

    init(displayID: CGDirectDisplayID?) {
        self.displayID = displayID
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        // Resolve the saved theme before first layout/paint so launch never shows
        // the fallback style or a half-built bar.
        let launchID = store.current.activeThemeID
        if let result = try? ThemeResolutionCache.shared.loadSync(launchID) {
            Theme.preload(launchID, result: result)
        }
        ThemeResolutionCache.shared.prewarmBuiltIns()
        try? FileManager.default.createDirectory(at: ThemePaths.userThemesDirectory, withIntermediateDirectories: true)
        themeWatcher.onReload = { [weak self] result in
            guard let self else { return }
            let id = self.store.current.activeThemeID
            ThemeResolutionCache.shared.accept(result, for: id)
            if result.succeeded { Theme.preload(id, result: result) }
            if result.succeeded { self.applySettings() }
            self.properties.model.themeWarning = result.diagnostics.first(where: { $0.severity == .error })?.message
        }
        #if DEBUG
        if let override = ThemeLoader.debugThemeDirectory {
            themeWatcher.watch(directories: [ThemePaths.userThemesDirectory, override], themeID: store.current.activeThemeID)
        } else {
            themeWatcher.watch(directory: ThemePaths.userThemesDirectory, themeID: store.current.activeThemeID)
        }
        #else
        themeWatcher.watch(directory: ThemePaths.userThemesDirectory, themeID: store.current.activeThemeID)
        #endif
        makePanel()
        windowPreview.onWindowsChanged = { [weak self] in self?.windowTracker.refreshSoon() }
        windowPreview.onVisibilityChanged = { [weak self] in self?.onTransientUIChanged?() }
        view.tray.onOverflowPanelChanged = { [weak self] in self?.onTransientUIChanged?() }
        windowPreview.startMonitoring()
        startPanelBody()
    }

    private func makePanel() {
        viewStorage = TaskbarView(frame: NSRect(x: 0, y: 0, width: 800, height: TaskbarView.thickness))
        view.delegate = self
        panelStorage = TaskbarPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: TaskbarView.thickness),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        lastScreenSignature = targetScreenInfo()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            center.addObserver(self, selector: #selector(panelScreenChanged(_:)), name: name, object: panel)
        }
    }

    private func startPanelBody() {
        properties.model.previewApps = { [weak self] in self?.apps ?? [] }
        properties.model.previewActivePID = { [weak self] in self?.activePID }
        properties.model.onPermissionsRefresh = { [weak self] in
            self?.windowTracker.refreshSoon()
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: SettingsStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged),
                                               name: PinStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: .winstripeDisplaysReconfigured, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(axWindowChanged),
                                               name: .winstripeAXWindowChanged, object: nil)
        blockObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated { self?.trackedMenu = note.object as? NSMenu }
        })
        blockObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.trackedMenu = nil }
        })
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)

        scheduleClock()
        addTimer(interval: 0.1, selector: #selector(pollMouse))
        // Badges / input source / tray state; app and window changes are event-driven.
        addTimer(interval: 5, selector: #selector(statusTick))

        statusTick()
        applySettings()
        refreshApps(force: true)
        view.layoutSubtreeIfNeeded()
        panel.display()
        windowTracker.start { [weak self] windows, focused in
            self?.trackedWindows = windows
            self?.focusedWindowID = focused
            self?.refreshApps()
        }
        panel.orderFrontRegardless()
        updateFullscreenVisibility()
        debugLog("Winstripe started")
    }

    private func addTimer(interval: TimeInterval, selector: Selector) {
        let t = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func scheduleClock() {
        clockTimer?.invalidate()
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(60)
        let t = Timer(fireAt: next, interval: 60, target: self, selector: #selector(clockTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    // MARK: Geometry

    /// The screen this bar lives on. Retargets when the tracked display id disappears.
    func targetScreenInfo() -> ScreenInfo? {
        let resolved = DisplayGeometry.resolve(tracked: displayID, screens: screenProvider(), followPrimary: followsPrimaryScreen)
        if let resolved, resolved.id != displayID {
            if displayID != nil { debugLog("SCREEN retarget \(displayID.map(String.init) ?? "nil") -> \(resolved.id)") }
            displayID = resolved.id
        }
        return resolved
    }

    private func targetScreen() -> NSScreen? {
        guard let info = targetScreenInfo() else { return nil }
        return DisplayGeometry.screen(id: info.id) ?? NSScreen.main
    }

    static func frame(settings: TaskbarSettings, screenFrame f: NSRect, visibleFrame v: NSRect, hidden: Bool) -> NSRect {
        let h = TaskbarView.thickness(for: settings), w = TaskbarView.verticalWidth(for: settings)
        let top = v.maxY   // just below the menu bar
        var r: NSRect
        switch settings.edge {
        case .bottom: r = NSRect(x: f.minX, y: f.minY, width: f.width, height: h)
        case .top: r = NSRect(x: f.minX, y: top - h, width: f.width, height: h)
        case .left: r = NSRect(x: f.minX, y: f.minY, width: w, height: top - f.minY)
        case .right: r = NSRect(x: f.maxX - w, y: f.minY, width: w, height: top - f.minY)
        }
        if hidden {
            switch settings.edge {
            case .bottom: r.origin.y -= h
            case .top: r.origin.y += h
            case .left: r.origin.x -= w
            case .right: r.origin.x += w
            }
        }
        return r
    }

    private func frame(hidden: Bool) -> NSRect {
        guard let screen = targetScreenInfo() else {
            // No usable screen (mid-reconfiguration): keep the last good frame rather than
            // shrinking to a placeholder; the reconfiguration callback re-applies geometry.
            if let panelStorage, panelStorage.frame.width > 1 { return panelStorage.frame }
            return Self.frame(settings: store.current, screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
                              visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600), hidden: hidden)
        }
        return Self.frame(settings: store.current, screenFrame: screen.frame, visibleFrame: screen.visibleFrame, hidden: hidden)
    }

    // MARK: Model -> view

    private func applySettings() {
        guard !isStopped else { return }
        let s = store.current
        #if DEBUG
        if let override = ThemeLoader.debugThemeDirectory {
            themeWatcher.watch(directories: [ThemePaths.userThemesDirectory, override], themeID: s.activeThemeID)
        } else {
            themeWatcher.watch(directory: ThemePaths.userThemesDirectory, themeID: s.activeThemeID)
        }
        #else
        themeWatcher.watch(directory: ThemePaths.userThemesDirectory, themeID: s.activeThemeID)
        #endif
        view.settings = s
        view.usesStartOverflowPanel = s.capabilities.startButtonOverflow && !s.edge.isVertical
        view.quickLaunchItems = s.showQuickLaunch ? QuickLaunch.items(at: s.quickLaunchPath) : []
        view.clockText = Clock.time(s.resolvedLanguage)
        view.dateText = Clock.date()
        view.shortDateText = Clock.shortDate()
        view.inputText = InputSource.abbreviation()
        view.trayExpanded = trayExpanded
        if !s.autoHide { isAutoHidden = false }
        lastInside = Date()
        panel.alphaValue = isAutoHidden ? 0 : 1
        panel.setFrame(frame(hidden: isAutoHidden), display: false)
        if hiddenByFullscreen {
            panel.orderOut(nil)
            orbPanel?.orderOut(nil)
        }
        view.reload()
        prewarmAeroIconColors()
        updateOrbPanel()
        if SnapshotFixture.isActive {
            panel.display()
        } else {
            panel.viewsNeedDisplay = true
            view.needsDisplay = true
        }
        appliedThemeID = s.activeThemeID
    }

    private func scheduleThemeApply() {
        themeApplyGeneration += 1
        let generation = themeApplyGeneration
        let id = store.current.activeThemeID
        if SnapshotFixture.isActive {
            applySettings()
            refreshApps(force: true)
            return
        }
        ThemeResolutionCache.shared.loadAsync(id) { [weak self] result in
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          generation == self.themeApplyGeneration,
                          self.store.current.activeThemeID == id else { return }
                    if let result { Theme.preload(id, result: result) }
                    self.applySettings()
                    self.refreshApps(force: true)
                }
            }
        }
    }

    private func orbFrame(bar: NSRect) -> NSRect {
        let overflow = Theme.make(store.current).startStyle.overflow
        let size = overflow.panelSize, inset = overflow.panelInset
        return NSRect(x: bar.minX, y: store.current.edge == .bottom ? bar.minY - inset : bar.maxY + inset - size.height,
                      width: size.width, height: size.height)
    }

    private func updateOrbPanel() {
        guard !isStopped else { return }
        if hiddenByFullscreen {
            orbPanel?.orderOut(nil)
            return
        }
        let theme = Theme.make(store.current)
        let overflow = theme.startStyle.overflow
        guard overflow.enabled, !store.current.edge.isVertical else {
            orbPanel?.orderOut(nil)
            orbPanel = nil
            orbButton = nil
            return
        }
        if orbPanel == nil {
            let button = RetroButton(frame: NSRect(origin: .zero, size: overflow.panelSize))
            button.kind = .start
            button.theme = theme
            button.actsOnMouseDown = true
            button.onClick = { [weak self] in self?.taskbarStartPressed() }
            button.onMenu = { [weak self] event in self?.taskbarStartMenu(for: event) }
            let p = NSPanel(contentRect: orbFrame(bar: panel.frame),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = button
            orbPanel = p
            orbButton = button
        }
        orbButton?.theme = theme
        orbButton?.smoothing = theme.layoutStyle.forcedSmoothing || store.current.fontSmoothing
        orbButton?.frame = NSRect(origin: .zero, size: overflow.panelSize)
        orbButton?.title = L.t(theme.startStyle.label.key, store.current.resolvedLanguage)
        orbButton?.isOn = startMenu.isOpen
        orbButton?.toolTip = L.t("Start", store.current.resolvedLanguage)
        orbPanel?.level = NSWindow.Level(rawValue: (startMenu.isOpen ? NSWindow.Level.popUpMenu.rawValue : panel.level.rawValue) + 1)
        orbPanel?.setFrame(orbFrame(bar: panel.frame), display: true)
        orbPanel?.alphaValue = isAutoHidden ? 0 : 1
        if isAutoHidden { orbPanel?.orderOut(nil) } else { orbPanel?.orderFrontRegardless() }
    }

    func hideOrbForTermination() {
        orbPanel?.orderOut(nil)
        windowPreview.stop()
    }

    private func refreshApps(force: Bool = false) {
        let me = getpid()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me
        }
        let pids = Set(running.map { $0.processIdentifier })
        order.removeAll { !pids.contains($0) }
        for app in running where !order.contains(app.processIdentifier) { order.append(app.processIdentifier) }
        var byPid: [pid_t: NSRunningApplication] = [:]
        for app in running { byPid[app.processIdentifier] = app }

        let s = store.current
        let counts = s.showWindowPreviews ? WindowInfo.counts() : [:]
        let newApps: [AppEntry] = order.compactMap { pid in
            guard let app = byPid[pid] else { return nil }
            let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App"
            let windows = trackedWindows[pid] ?? []
            return AppEntry(pid: pid, name: name, icon: app.icon, badge: s.showBadges ? badges[name] : nil,
                            windowCount: windows.isEmpty ? (counts[pid] ?? 0) : windows.count,
                            isHidden: app.isHidden, windows: windows, bundleID: app.bundleIdentifier, path: app.bundleURL?.path)
        }
        let front = NSWorkspace.shared.frontmostApplication
        let newActive: pid_t? = front.flatMap { app in
            app.isHidden == false && pids.contains(app.processIdentifier) ? app.processIdentifier : nil
        }
        guard force || newApps != apps || newActive != activePID || focusedWindowID != activeWindowID else { return }
        apps = newApps
        activePID = newActive
        activeWindowID = focusedWindowID
        view.apps = apps
        view.pinnedApps = pinStore.apps
        view.taskOrder = pinStore.taskOrder
        view.activePID = activePID
        view.activeWindowID = focusedWindowID
        view.reload()
        prewarmAeroIconColors()
    }

    private func prewarmAeroIconColors() {
        guard !SnapshotFixture.isActive, Theme.make(store.current).modernButton?.aero.hotTrack == true else { return }
        let icons = view.aeroPrewarmIcons
        AeroDrawing.prewarmAverageColors(icons) { [weak self] in
            self?.view.needsDisplay = true
        }
    }

    private var activeWindowID: CGWindowID?

    // MARK: Notifications & timers

    @objc private func pinsChanged() {
        view.pinnedApps = pinStore.apps
        view.taskOrder = pinStore.taskOrder
        view.reload()
    }

    func debugPins(arguments: [String]) {
        var messages: [String] = []
        for index in arguments.indices where ["--pin", "--unpin"].contains(arguments[index]) && index + 1 < arguments.count {
            let id = arguments[index + 1]
            if arguments[index] == "--unpin" {
                if let pin = pinStore.apps.first(where: { $0.bundleID == id }) { pinStore.toggle(pin) }
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                if !pinStore.contains(bundleID: id) { pinStore.insert(PinnedApp(bundleID: id, path: url.path), at: pinStore.apps.count) }
            } else { messages.append("Application not found: \(id)") }
        }
        messages.append("pinnedApps: " + pinStore.apps.map { "\($0.bundleID ?? "(no bundle ID)")=\($0.path)" }.joined(separator: ", "))
        messages.append("buttons: " + view.buttonOrderDescription)
        let text = messages.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        try? text.write(toFile: "/tmp/winstripe-pins.log", atomically: true, encoding: .utf8)
    }

    @objc private func workspaceChanged(_ note: Notification) {
        if note.name == NSWorkspace.didTerminateApplicationNotification,
           let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            hiddenByShowDesktop.removeAll { $0.processIdentifier == app.processIdentifier }
        }
        if note.name == NSWorkspace.activeSpaceDidChangeNotification {
            scheduleFullscreenChecks()
        } else if note.name == NSWorkspace.didActivateApplicationNotification {
            updateFullscreenVisibility()
        }
        windowTracker.refreshSoon()
        refreshApps()
    }

    @objc private func settingsChanged() {
        debugLog("Settings changed: \(store.current)")
        windowPreview.hide()
        startMenu.close()
        let themeChanged = store.current.activeThemeID != appliedThemeID
        if themeChanged {
            // Do not statusTick/apply on this turn — scheduleThemeApply already
            // hops off the menu-tracking / dismiss path.
            scheduleThemeApply()
            return
        }
        statusTick()
        applySettings()
        refreshApps(force: true)
    }

    @objc private func screensChanged() { scheduleScreenGeometryUpdate("screens") }

    @objc private func panelScreenChanged(_ note: Notification) {
        scheduleScreenGeometryUpdate(note.name == NSWindow.didChangeBackingPropertiesNotification ? "backing" : "window-screen")
    }

    /// Coalesces bursts (CG reports each display twice, AppKit adds its own notifications).
    func scheduleScreenGeometryUpdate(_ reason: String, delay: TimeInterval = 0.12) {
        screenUpdateGeneration += 1
        let generation = screenUpdateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.screenUpdateGeneration else { return }
                self.applyScreenGeometry(reason)
            }
        }
    }

    /// Recomputes everything that depends on the screen: bar frame for the edge and auto-hide
    /// state, the orb overflow panel, popup anchors (open popups close and re-anchor on next
    /// open), and layer scale after a Retina/backing change.
    func applyScreenGeometry(_ reason: String) {
        guard !isStopped else { return }
        guard panelStorage != nil else { return }
        screenGeometryApplyCount += 1
        let info = targetScreenInfo()
        if info == nil && !followsPrimaryScreen {
            panel.orderOut(nil)
            orbPanel?.orderOut(nil)
            return
        }
        let changed = info != lastScreenSignature
        if changed {
            windowPreview.hide()
            if startMenu.isOpen { startMenu.close() }
            view.tray.closeOverflowPanel()
            trackedMenu?.cancelTracking()
        }
        if let info, info.scale != lastScreenSignature?.scale { refreshBacking(scale: info.scale) }
        if info != nil { lastScreenSignature = info }
        applySettings()
        if info != nil, !hiddenByFullscreen, !isAutoHidden, !SnapshotFixture.isActive, NSApp.isRunning { panel.orderFrontRegardless() }
        scheduleFullscreenChecks()
        debugLog("SCREEN \(reason) id=\(info.map { String($0.id) } ?? "none") frame=\(info.map { NSStringFromRect($0.frame) } ?? "-") scale=\(info?.scale ?? 0) bar=\(NSStringFromRect(panel.frame))")
    }

    /// Cached layer bitmaps were rasterized for the old scale; update and redraw them.
    private func refreshBacking(scale: CGFloat) {
        func walk(_ v: NSView) {
            if let layer = v.layer {
                layer.contentsScale = scale
                layer.sublayers?.forEach { $0.contentsScale = scale }
            }
            v.needsDisplay = true
            v.subviews.forEach(walk)
        }
        walk(view)
        if let orb = orbPanel?.contentView { walk(orb) }
        view.reload()
    }

    /// Tears the bar down for good: its display went away or "all displays" was turned off.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        clockTimer?.invalidate()
        clockTimer = nil
        NotificationCenter.default.removeObserver(self)
        blockObservers.forEach { NotificationCenter.default.removeObserver($0) }
        blockObservers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        windowTracker.stop()
        windowPreview.stop()
        themeWatcher.stop()
        guard panelStorage != nil else { return }
        windowPreview.hide()
        if startMenu.isOpen { startMenu.close() }
        view.tray.closeOverflowPanel()
        trackedMenu?.cancelTracking()
        orbPanel?.orderOut(nil)
        orbPanel?.close()
        orbPanel = nil
        panel.orderOut(nil)
        panel.close()
        debugLog("SCREEN bar stopped id=\(displayID.map(String.init) ?? "nil")")
    }

    func retarget(to id: CGDirectDisplayID) {
        displayID = id
        applyScreenGeometry("retarget")
    }

    var testPanel: NSPanel? { panelStorage }
    var testViewLayerScale: CGFloat? { viewStorage?.layer?.contentsScale }

    /// Self-test hook: builds the panel without starting trackers, timers or observers of app state.
    func prepareForScreenTest() {
        makePanel()
        applySettings()
    }

    private func scheduleFullscreenChecks() {
        fullscreenCheckGeneration += 1
        let generation = fullscreenCheckGeneration
        updateFullscreenVisibility()
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    guard let self, self.fullscreenCheckGeneration == generation else { return }
                    self.updateFullscreenVisibility()
                }
            }
        }
    }

    private func updateFullscreenVisibility() {
        guard !isStopped else { return }
        guard let screen = targetScreen(), panelStorage != nil else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fullscreen = FullscreenDetector.isFullscreen(frontmostPID: frontmostPID, screen: screen)
        guard fullscreen != hiddenByFullscreen else { return }
        hiddenByFullscreen = fullscreen
        if fullscreen {
            windowPreview.hide()
            startMenu.close()
            view.tray.closeOverflowPanel()
            trayExpanded = false
            trackedMenu?.cancelTracking()
            NSApp.mainMenu?.cancelTracking()
            panel.orderOut(nil)
            orbPanel?.orderOut(nil)
        } else {
            panel.setFrame(frame(hidden: isAutoHidden), display: false)
            panel.alphaValue = isAutoHidden ? 0 : 1
            if !isAutoHidden { panel.orderFrontRegardless() }
            updateOrbPanel()
        }
        let id = displayID.map(String.init) ?? "default"
        debugLog("FULLSCREEN screen=\(id) hidden=\(fullscreen)")
    }

    @objc private func didWake() {
        scheduleClock()
        clockTick()
    }

    @objc private func inputSourceChanged() {
        view.inputText = InputSource.abbreviation()
        view.reload()
    }

    @objc private func clockTick() {
        view.clockText = Clock.time(store.current.resolvedLanguage)
        view.dateText = Clock.date()
        view.shortDateText = Clock.shortDate()
        view.reload()
    }

    @objc private func statusTick() {
        let s = store.current
        var needsReload = false
        let shouldFetchBadges = s.showBadges || s.collapseTrayIcons || !s.trayApps.isEmpty
        if shouldFetchBadges && Date().timeIntervalSince(lastBadgeFetch) >= 2 {
            badges = DockBadges.fetch()
            lastBadgeFetch = Date()
        } else if !shouldFetchBadges {
            badges = [:]
        }
        if !s.trayApps.isEmpty {
            var trayBadges: [String: String] = [:]
            for path in s.trayApps {
                guard let app = TrayAppInfo.resolve(path), let badge = DockBadges.badge(for: app, in: badges) else { continue }
                trayBadges[app.path] = badge
            }
            if view.trayBadges != trayBadges {
                view.trayBadges = trayBadges
                needsReload = true
            }
        } else if !view.trayBadges.isEmpty {
            view.trayBadges = [:]
            needsReload = true
        }
        let input = InputSource.abbreviation()
        if input != view.inputText {
            view.inputText = input
            needsReload = true
        }
        if needsReload { view.reload() }
        refreshApps()
    }

    /// Auto-hide: slide away when the mouse leaves, slide back when it touches the screen edge.
    @objc private func pollMouse() {
        if hiddenByFullscreen { return }
        let s = store.current
        if !s.autoHide && !s.showWindowPreviews { return }
        let mouse = NSEvent.mouseLocation
        if s.showWindowPreviews {
            let now = Date()
            let overTaskbar = frame(hidden: false).insetBy(dx: -2, dy: -2).contains(mouse)
            let interval: TimeInterval = (s.autoHide || windowPreview.isVisible || overTaskbar) ? 0.1 : 0.25
            if now.timeIntervalSince(lastPreviewPoll) >= interval {
                windowPreview.poll(button: isAutoHidden ? nil : view.taskButton(at: mouse),
                                   apps: apps, settings: s, screen: targetScreen(),
                                   blocked: startMenu.isOpen || NSApp.modalWindow != nil)
                lastPreviewPoll = now
            }
        }
        guard s.autoHide, let screen = targetScreenInfo() else { return }
        let p = mouse
        let f = screen.frame, v = screen.visibleFrame
        let inX = p.x >= f.minX && p.x <= f.maxX
        let inY = p.y >= f.minY && p.y <= v.maxY
        let atEdge: Bool
        switch s.edge {
        case .bottom: atEdge = inX && p.y <= f.minY + 1
        case .top: atEdge = inX && p.y >= v.maxY - 2 && p.y <= v.maxY + 1
        case .left: atEdge = inY && p.x <= f.minX + 1
        case .right: atEdge = inY && p.x >= f.maxX - 2
        }
        let inside = frame(hidden: false).insetBy(dx: -2, dy: -2).contains(p) || startMenu.isOpen || windowPreview.isVisible
            || (orbPanel?.isVisible == true && orbPanel?.frame.contains(p) == true) || NSApp.modalWindow != nil
        if isAutoHidden {
            if atEdge { setAutoHidden(false) }
        } else if inside {
            lastInside = Date()
        } else if Date().timeIntervalSince(lastInside) > 0.8 {
            setAutoHidden(true)
        }
    }

    private func setAutoHidden(_ hidden: Bool) {
        guard !isStopped else { return }
        guard hidden != isAutoHidden else { return }
        isAutoHidden = hidden
        lastInside = Date()
        let target = frame(hidden: hidden)
        let panel = self.panel
        if !hidden { orbPanel?.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = hidden ? 0 : 1
            orbPanel?.animator().setFrame(orbFrame(bar: target), display: true)
            orbPanel?.animator().alphaValue = hidden ? 0 : 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                if self?.isAutoHidden == true { self?.orbPanel?.orderOut(nil) }
            }
        }
    }

    // MARK: Start menu

    @objc func openStartMenu() {
        openStartMenu(focusMenu: true)
    }

    private func openStartMenu(focusMenu: Bool) {
        guard !hiddenByFullscreen else { return }
        windowPreview.hide()
        let s = store.current
        if isAutoHidden { setAutoHidden(false) }
        let btn = view.startButton
        let rectInWindow = btn.convert(btn.bounds, to: nil)
        let rectOnScreen = panel.convertToScreen(rectInWindow)
        startMenu.show(buttonRect: rectOnScreen, barFrame: frame(hidden: false), edge: s.edge,
                       settings: s, screen: targetScreen(), searchText: view.searchText, focusMenu: focusMenu)
        view.startMenuOpen = true
        updateOrbPanel()
    }

    func startMenuDidClose() {
        view.startMenuOpen = false
        orbButton?.isOn = false
        if let orbPanel { orbPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1) }
        onTransientUIChanged?()
    }

    func isStartButtonEvent(_ event: NSEvent) -> Bool {
        if let orbPanel, event.window === orbPanel { return true }
        guard event.window === panel else { return false }
        let p = view.convert(event.locationInWindow, from: nil)
        return view.startButton.frame.contains(p)
    }

    func showProperties() {
        windowPreview.hide()
        startMenu.close()
        properties.show()
    }

    func runDialog() {
        Dialogs.run(lang: store.current.resolvedLanguage)
    }

    func shutDown() {
        if Dialogs.confirmShutDown(lang: store.current.resolvedLanguage) {
            NSApp.terminate(nil)
        }
    }

    // MARK: TaskbarViewDelegate

    func taskbarStartPressed() {
        if startMenu.isOpen { startMenu.close() } else { openStartMenu() }
    }

    func taskbarSearchChanged(_ text: String) {
        view.searchText = text
        if startMenu.isOpen {
            startMenu.updateSearch(text)
        } else {
            openStartMenu(focusMenu: false)
        }
    }

    func taskbarSearchSubmitted(_ text: String) {
        view.searchText = text
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = Win10StartMenuView.firstApplication(matching: query)
        if let match {
            if !startMenu.isOpen { openStartMenu(focusMenu: false) }
            startMenu.close()
            AppCollections.open(match.listEntry)
        } else if !startMenu.isOpen {
            openStartMenu(focusMenu: false)
        } else {
            startMenu.updateSearch(text)
        }
    }

    func taskbarAppClicked(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let isActive = pid == activePID || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if isActive, let windows = apps.first(where: { $0.pid == pid })?.windows, windows.count > 1 {
            let index = focusedWindowID.flatMap { id in windows.firstIndex { $0.id == id } } ?? -1
            let next = windows[(index + 1) % windows.count]
            if let element = next.element {
                _ = WindowActivator.activateWindow(pid: pid, window: element, minimized: next.minimized)
                return
            }
        }
        let hasVisibleWindow = WindowActivator.hasVisibleFrontWindow(pid: pid)
        if isActive && !app.isHidden && hasVisibleWindow {
            ActivationLog.write("toggle hide target=\(app.localizedName ?? "?") pid=\(pid)")
            app.hide()
            return
        }
        ActivationLog.write("activating target=\(app.localizedName ?? "?") pid=\(pid) active=\(isActive) visible=\(hasVisibleWindow)")
        let reopenState = WindowActivator.ReopenState()
        WindowActivator.activate(pid: pid, app: app, state: reopenState)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            WindowActivator.verifyAndRetry(pid: pid, app: app, state: reopenState)
        }
    }

    func taskbarWindowClicked(_ pid: pid_t, windowID: CGWindowID) {
        guard let app = apps.first(where: { $0.pid == pid }),
              let window = app.windows.first(where: { $0.id == windowID }),
              let element = window.element else { return }
        if pid == activePID && focusedWindowID == windowID && !window.minimized {
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }
        let result = WindowActivator.activateWindow(pid: pid, window: element, minimized: window.minimized)
        ActivationLog.write("activate-window pid=\(pid) id=\(windowID) result=\(result.rawValue)")
    }

    @objc private func axWindowChanged() {
        windowTracker.refreshSoon()
    }

    func writeWindowDebugLog() {
        let trusted = AXIsProcessTrusted()
        let recording = ScreenRecordingAccess.preflight()
        var lines = ["axTrusted=\(trusted)", "screenRecording=\(recording)"]
        for app in apps {
            lines.append("\(app.name) pid=\(app.pid) windows:")
            for window in app.windows {
                lines.append("  pid=\(app.pid) id=\(window.id) source=\(window.idSource) title=\(window.title) minimized=\(window.minimized) frame=\(window.frame)")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        try? text.write(toFile: "/tmp/winstripe-windows.log", atomically: true, encoding: .utf8)
    }

    func activateWindowDebug(pid: pid_t, titleSubstring: String) {
        guard let app = apps.first(where: { $0.pid == pid }),
              let window = app.windows.first(where: { $0.title.localizedCaseInsensitiveContains(titleSubstring) }),
              window.element != nil else {
            ActivationLog.write("activate-window pid=\(pid) title=\(titleSubstring) not found")
            return
        }
        taskbarWindowClicked(pid, windowID: window.id)
    }

    func previewDebug(pid: pid_t) {
        PreviewLog.enabled = true
        guard let app = apps.first(where: { $0.pid == pid }),
              let button = view.taskButton(pid: pid) else {
            PreviewLog.write("preview pid=\(pid) failed: no visible task button")
            return
        }
        windowPreview.debugShow(app: app, windowID: button.windowID, anchor: button.rect,
                                settings: store.current, screen: targetScreen())
    }

    func taskbarQuickLaunch(_ url: URL) {
        debugLog("Quick Launch \(url.path)")
        NSWorkspace.shared.open(url)
    }

    func taskbarShowDesktop() {
        if !hiddenByShowDesktop.isEmpty {
            let stillHidden = hiddenByShowDesktop.filter { !$0.isTerminated && $0.isHidden }
            stillHidden.forEach { _ = $0.unhide() }
            hiddenByShowDesktop = []
            // A window may have been restored or its app may have exited since
            // the previous toggle. In that case, treat this as a fresh request
            // instead of turning a stale toggle into a no-op.
            if !stillHidden.isEmpty { return }
        }
        let me = getpid()
        let visible = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != me
        }
        hiddenByShowDesktop = visible.filter { $0.hide() }
    }

    func taskbarToggleTray() {
        guard !hiddenByFullscreen else { return }
        let s = store.current
        if !Theme.make(s).classic && s.collapseTrayIcons && !view.tray.collapsedTrayAppsForPanel.isEmpty {
            view.tray.toggleOverflowPanel(taskbarFrame: panel.frame, edge: s.edge)
            trayExpanded = view.tray.isOverflowPanelOpen
        } else {
            trayExpanded.toggle()
        }
        applySettings()
        onTransientUIChanged?()
    }

    func taskbarMoved(to edge: TaskbarEdge) {
        store.mutate { $0.edge = edge }
    }

    func taskbarShowProperties() {
        showProperties()
    }

    func taskbarToggleLock() {
        store.mutate { $0.locked.toggle() }
    }

    // MARK: Context menus

    func taskbarMenu(for event: NSEvent) -> NSMenu? {
        windowPreview.hide()
        startMenu.close()
        return makeEmptyMenu(language: store.current.resolvedLanguage)
    }

    private func makeEmptyMenu(language lang: Language) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let toolbars = NSMenuItem(title: L.t("Toolbars", lang), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let quick = NSMenuItem(title: L.t("Quick Launch", lang), action: #selector(toggleQuickLaunchAction), keyEquivalent: "")
        quick.target = self
        quick.state = store.current.showQuickLaunch ? .on : .off
        submenu.addItem(quick)
        toolbars.submenu = submenu
        menu.addItem(toolbars)
        menu.addItem(.separator())

        let desktop = NSMenuItem(title: L.t("Show the desktop", lang), action: #selector(showDesktopAction), keyEquivalent: "")
        desktop.target = self
        menu.addItem(desktop)
        menu.addItem(.separator())

        let manager = NSMenuItem(title: L.t("Task Manager…", lang), action: #selector(taskManagerAction), keyEquivalent: "")
        manager.target = self
        menu.addItem(manager)
        menu.addItem(.separator())

        let lock = NSMenuItem(title: L.t("Lock the taskbar", lang), action: #selector(toggleLockAction), keyEquivalent: "")
        lock.target = self
        lock.state = store.current.locked ? .on : .off
        menu.addItem(lock)
        let props = NSMenuItem(title: L.t("Winstripe Settings…", lang), action: #selector(propertiesAction), keyEquivalent: "")
        props.target = self
        menu.addItem(props)
        let updates = NSMenuItem(title: L.t("Check for Updates…", lang), action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        return menu
    }

    func taskbarStartMenu(for event: NSEvent) -> NSMenu? {
        windowPreview.hide()
        startMenu.close()
        return makeStartMenu(language: store.current.resolvedLanguage)
    }

    private func makeStartMenu(language lang: Language) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let properties = NSMenuItem(title: L.t("Winstripe Settings…", lang), action: #selector(propertiesAction), keyEquivalent: "")
        properties.target = self
        menu.addItem(properties)
        let updates = NSMenuItem(title: L.t("Check for Updates…", lang), action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        let open = NSMenuItem(title: L.t("Open", lang), action: #selector(openApplicationsAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let explore = NSMenuItem(title: L.t("Explore", lang), action: #selector(exploreHomeAction), keyEquivalent: "")
        explore.target = self
        menu.addItem(explore)
        return menu
    }

    func taskbarTaskMenu(pid: pid_t, windowID: CGWindowID?, event: NSEvent) -> NSMenu? {
        windowPreview.hide()
        startMenu.close()
        guard let app = apps.first(where: { $0.pid == pid }) else { return nil }
        return makeTaskMenu(app: app, windowID: windowID, language: store.current.resolvedLanguage)
    }

    private func makeTaskMenu(app: AppEntry, windowID: CGWindowID?, language: Language) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let running = NSRunningApplication(processIdentifier: app.pid)
        let bundleID = running?.bundleIdentifier
        let path = running?.bundleURL?.path
        let axTrusted = AXIsProcessTrusted()

        let finder = NSMenuItem(title: L.t("Show in Finder", language), action: #selector(showMenuAppInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = running?.bundleURL
        finder.isEnabled = running?.bundleURL != nil
        menu.addItem(finder)

        if windowID == nil && !app.windows.isEmpty {
            for window in app.windows {
                let item = NSMenuItem(title: window.title, action: #selector(activateMenuWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = TaskMenuWindowContext(pid: app.pid, window: window)
                item.state = app.pid == activePID && window.id == focusedWindowID ? .on : .off
                item.isEnabled = axTrusted && window.element != nil
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let pinTitle = path.map { pinStore.contains(PinnedApp(bundleID: bundleID, path: $0)) ? "Unpin from taskbar" : "Pin to taskbar" } ?? "Pin to taskbar"
        let pin = NSMenuItem(title: L.t(pinTitle, language), action: #selector(togglePinAction(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = TaskMenuAppContext(pid: app.pid, bundleID: bundleID, path: path)
        pin.isEnabled = path != nil
        menu.addItem(pin)

        let closeTitle = windowID == nil ? "Close all windows" : "Close window"
        let close = NSMenuItem(title: L.t(closeTitle, language), action: #selector(closeMenuWindows(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = TaskMenuCloseContext(app: app, windowID: windowID)
        close.isEnabled = axTrusted && (windowID != nil ? app.windows.contains { $0.id == windowID && $0.element != nil } : app.windows.contains { $0.element != nil })
        menu.addItem(close)

        let quit = NSMenuItem(title: L.t("Quit", language), action: #selector(quitMenuApp(_:)), keyEquivalent: "")
        quit.target = self
        quit.representedObject = running
        quit.isEnabled = running != nil
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleQuickLaunchAction() {
        store.mutate { $0.showQuickLaunch.toggle() }
    }

    @objc private func showDesktopAction() { taskbarShowDesktop() }
    @objc private func toggleLockAction() { taskbarToggleLock() }
    @objc private func propertiesAction() { showProperties() }
    @objc private func checkForUpdatesAction() { AppUpdater.shared.checkForUpdates() }

    @objc private func taskManagerAction() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openApplicationsAction() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "/Applications")])
    }

    @objc private func exploreHomeAction() {
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser])
    }

    @objc private func activateMenuWindow(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? TaskMenuWindowContext,
              let element = context.window.element else { return }
        _ = WindowActivator.activateWindow(pid: context.pid, window: element, minimized: context.window.minimized)
    }

    @objc private func togglePinAction(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? TaskMenuAppContext,
              let path = context.path else { return }
        pinStore.toggle(PinnedApp(bundleID: context.bundleID, path: path))
    }

    @objc private func closeMenuWindows(_ sender: NSMenuItem) {
        guard AXIsProcessTrusted(), let context = sender.representedObject as? TaskMenuCloseContext else { return }
        let windows = context.windowID.flatMap { id in context.app.windows.filter { $0.id == id } } ?? context.app.windows
        for window in windows { pressCloseButton(window.element) }
        windowTracker.refreshSoon()
    }

    @objc private func quitMenuApp(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.terminate()
    }

    @objc private func showMenuAppInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func pressCloseButton(_ element: AXUIElement?) {
        guard let element else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let button = unsafeBitCast(value, to: AXUIElement.self)
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    func dumpMenus() {
        let demoWindow = WindowEntry(id: 1, title: "Demo window", minimized: false, frame: .zero,
                                     element: nil, firstSeen: 1, idSource: "demo")
        let demo = AppEntry(pid: getpid(), name: "Demo App", icon: nil, badge: nil, windowCount: 1,
                            isHidden: false, windows: [demoWindow])
        for language in Language.allCases {
            print("language=\(language.rawValue)")
            printMenu("combined", makeTaskMenu(app: demo, windowID: nil, language: language))
            printMenu("window", makeTaskMenu(app: demo, windowID: demoWindow.id, language: language))
            printMenu("empty", makeEmptyMenu(language: language))
            printMenu("start", makeStartMenu(language: language))
        }
    }

    private func printMenu(_ label: String, _ menu: NSMenu, indent: String = "") {
        for item in menu.items {
            print("\(label) \(indent)\(item.isSeparatorItem ? "<separator>" : item.title) state=\(item.state == .on ? "on" : "off") enabled=\(item.isEnabled)")
            if let submenu = item.submenu { printMenu(label, submenu, indent: indent + "  ") }
        }
    }

    // MARK: Snapshots (debug / verification)

    private var snapshotDir = ""
    private var snapshotNames: Set<String> = []

    private func savePNG(_ view: NSView, _ name: String) {
        if view.appearance == nil { view.appearance = NSAppearance(named: .aqua) }
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = SnapshotFixture.bitmap(for: view) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let url = URL(fileURLWithPath: snapshotDir).appendingPathComponent(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        snapshotNames.insert(name)
    }

    private func savePNG(_ image: NSImage, _ name: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        let url = URL(fileURLWithPath: snapshotDir).appendingPathComponent(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        snapshotNames.insert(name)
    }

    @objc func writeSnapshots(_ dir: NSString) {
        precondition(SnapshotFixture.isActive)
        snapshotDir = dir as String
        try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
        snapshotNames = []
        let s = SnapshotFixture.settings
        NSApp.appearance = NSAppearance(named: .aqua)
        let bar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: TaskbarView.thickness(for: s)))
        bar.settings = s
        let sampleApps = SnapshotFixture.sampleApps
        precondition(self.apps.isEmpty, "Snapshots require an offscreen controller")
        let apps = sampleApps
        let win8Apps = sampleApps
        let activePID = apps.first?.pid
        bar.apps = apps
        bar.activePID = activePID
        bar.clockText = Clock.time(s.resolvedLanguage)
        bar.shortDateText = Clock.shortDate()
        bar.inputText = InputSource.abbreviation()
        bar.reload()
        savePNG(bar, "taskbar.png")
        let perWindowApps: [AppEntry] = [
            AppEntry(pid: 101, name: "Safari", icon: sampleApps[0].icon, badge: nil, windowCount: 2, isHidden: false,
                     windows: [WindowEntry(id: 1001, title: "Apple", minimized: false, frame: .zero, element: nil, firstSeen: 1, idSource: "demo"),
                               WindowEntry(id: 1002, title: "GitHub", minimized: false, frame: .zero, element: nil, firstSeen: 2, idSource: "demo")]),
            AppEntry(pid: 102, name: "Notes", icon: sampleApps[1].icon, badge: nil, windowCount: 1, isHidden: false,
                     windows: [WindowEntry(id: 1003, title: "Shopping list", minimized: false, frame: .zero, element: nil, firstSeen: 3, idSource: "demo")]),
            AppEntry(pid: 103, name: "TextEdit", icon: sampleApps[2].icon, badge: nil, windowCount: 2, isHidden: false,
                     windows: [WindowEntry(id: 1004, title: "Untitled", minimized: false, frame: .zero, element: nil, firstSeen: 4, idSource: "demo"),
                               WindowEntry(id: 1005, title: "Untitled 2", minimized: true, frame: .zero, element: nil, firstSeen: 5, idSource: "demo")])
        ]
        for (theme, name) in [(ThemeKind.win95, "win95"), (.vista, "vista"), (.win7, "win7"),
                              (.win10, "win10"), (.win11, "win11")] {
            var previewSettings = s
            previewSettings.theme = theme
            savePNG(WindowPreviewSnapshotView(settings: previewSettings, app: perWindowApps[0]),
                    "preview-popup-\(name).png")
        }
        for (theme, name, grouping) in [(ThemeKind.win95, "win95", TaskbarGrouping.neverCombine),
                                        (.win7, "win7", .neverCombine), (.win10, "win10", .neverCombine),
                                        (.win11, "win11", .neverCombine), (.win11, "win11-combined", .alwaysCombine)] {
            var perWindow = s
            perWindow.theme = theme
            perWindow.taskbarGrouping = grouping
            let perWindowBar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: TaskbarView.thickness(for: perWindow)))
            perWindowBar.settings = perWindow
            perWindowBar.apps = perWindowApps
            perWindowBar.activePID = 101
            perWindowBar.activeWindowID = 1001
            perWindowBar.reload()
            savePNG(perWindowBar, "taskbar-perwindow-\(name).png")
        }
        // Fixtures use explicit pins and identities, independent of the user's saved lists.
        for (kind, slug) in [(ThemeKind.win7, "win7"), (.win10, "win10"), (.win95, "win95")] {
            var pinnedSettings = s
            pinnedSettings.theme = kind
            pinnedSettings.taskbarGroupingChoice = nil
            let pinnedBar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000,
                                                       height: TaskbarView.thickness(for: pinnedSettings)))
            pinnedBar.isPreview = true
            pinnedBar.settings = pinnedSettings
            pinnedBar.pinnedApps = [
                PinnedApp(bundleID: "com.apple.calculator", path: "/System/Applications/Calculator.app"),
                PinnedApp(bundleID: "com.apple.Maps", path: "/System/Applications/Maps.app"),
                PinnedApp(bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
            ]
            pinnedBar.apps = [
                AppEntry(pid: 101, name: "Safari", icon: sampleApps[0].icon, windowCount: 1, isHidden: false,
                         bundleID: "com.apple.Safari", path: "/Applications/Safari.app"),
                AppEntry(pid: 102, name: "Notes", icon: sampleApps[1].icon, windowCount: 1, isHidden: false,
                         bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app")
            ]
            pinnedBar.activePID = 101
            pinnedBar.clockText = "10:09"
            pinnedBar.reload()
            savePNG(pinnedBar, "taskbar-pinned-\(slug).png")
        }
        savePNG(snapshotStartMenu(settings: s), "startmenu.png")
        var demo = s
        demo.showInputLanguage = true
        demo.showDesktopButton = true
        for theme in ThemeKind.allCases {
            demo.theme = theme
            demo.edge = .bottom
            let themeApps = theme == .win8 ? win8Apps : apps
            let slug = theme.rawValue.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "")
            savePNG(PreviewRenderer.image(settings: demo, apps: themeApps, activePID: activePID), "preview-\(slug).png")
            savePNG(snapshotStartMenu(settings: demo), "startmenu-\(slug).png")
            if theme == .vista || theme == .win7 {
                let name = theme == .vista ? "vista" : "win7"
                demo.taskbarGrouping = .alwaysCombine
                savePNG(AeroSnapshotView(settings: demo, apps: win8Apps), "taskbar-\(name).png")
                savePNG(AeroSnapshotView(settings: demo, apps: win8Apps, menu: true), "startmenu-\(name).png")
                savePNG(AeroSnapshotView(settings: demo, apps: win8Apps, menu: true, allApps: true),
                        "startmenu-\(name)-allapps.png")
                savePNG(aeroAllAppsNoLineSnapshot(settings: demo), "startmenu-\(name)-allapps-noline.png")
                savePNG(aeroScrollHoverSnapshot(settings: demo), "startmenu-\(name)-scroll-hover.png")
                var left = demo
                left.edge = .left
                savePNG(AeroSnapshotView(settings: left, apps: win8Apps), "taskbar-\(name)-left.png")
                if theme == .win7 {
                    var labels = demo
                    labels.taskbarGrouping = .neverCombine
                    savePNG(AeroSnapshotView(settings: labels, apps: win8Apps), "taskbar-win7-labels.png")
                }
            }
            if theme == .win11 {
                savePNG(snapshotStartMenu(settings: demo), "startmenu-win11.png")
                savePNG(StartMenuRendering.view(settings: demo, allApps: true), "startmenu-win11-allapps.png")
                if !AppCollections.folders(settings: demo).isEmpty {
                    let expanded = Win11StartMenuView(settings: demo, allApps: true)
                    expanded.expandCollectionFoldersForTesting()
                    savePNG(expanded, "startmenu-win11-allapps-collections.png")
                }
                if let folder = AppCollections.folders(settings: demo).first, let item = folder.items.first {
                    let pinned = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 48))
                    pinned.isPreview = true
                    pinned.settings = demo
                    pinned.pinnedApps = [PinnedApp(collectionItem: item), PinnedApp(collectionFolder: folder)]
                    pinned.reload()
                    pinned.layoutSubtreeIfNeeded()
                    savePNG(pinned, "taskbar-win11-collection-pins.png")
                }
                savePNG(StartMenuRendering.view(settings: demo, searchText: "Safari"), "startmenu-win11-search.png")
                let bar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 48))
                bar.settings = demo
                bar.apps = apps
                bar.activePID = activePID
                bar.clockText = Clock.time(demo.resolvedLanguage)
                bar.shortDateText = Clock.shortDate()
                bar.inputText = InputSource.abbreviation()
                bar.reload()
                savePNG(bar, "taskbar-win11.png")
                bar.appearance = NSAppearance(named: .darkAqua)
                savePNG(bar, "taskbar-win11-dark.png")
                let darkMenu = snapshotStartMenu(settings: demo)
                darkMenu.appearance = NSAppearance(named: .darkAqua)
                savePNG(darkMenu, "startmenu-win11-dark.png")
                bar.appearance = NSAppearance(named: .aqua)
                demo.alignment = .left
                bar.settings = demo
                bar.reload()
                savePNG(bar, "taskbar-win11-left.png")
                demo.alignment = .center
                for edge in [TaskbarEdge.top, .left, .right] {
                    demo.edge = edge
                    savePNG(PreviewRenderer.image(settings: demo, apps: apps, activePID: activePID),
                            "preview-win11-\(edge.rawValue).png")
                }
                demo.edge = .bottom
            }
            if theme == .win10 {
                let bar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
                bar.settings = demo
                bar.apps = apps
                bar.activePID = activePID
                bar.clockText = Clock.time(demo.resolvedLanguage)
                bar.shortDateText = Clock.shortDate()
                bar.inputText = "ENG"
                bar.reload()
                bar.appearance = NSAppearance(named: .darkAqua)
                savePNG(bar, "taskbar-win10.png")
                bar.appearance = NSAppearance(named: .aqua)
                savePNG(bar, "taskbar-win10-light.png")
                var verticalDemo = demo
                verticalDemo.edge = .left
                let verticalBar = TaskbarView(frame: NSRect(x: 0, y: 0,
                                                            width: TaskbarView.verticalWidth(for: verticalDemo), height: 800))
                verticalBar.settings = verticalDemo
                verticalBar.apps = apps
                verticalBar.activePID = activePID
                verticalBar.clockText = Clock.time(verticalDemo.resolvedLanguage)
                verticalBar.shortDateText = Clock.shortDate()
                verticalBar.inputText = "ENG"
                verticalBar.appearance = NSAppearance(named: .darkAqua)
                verticalBar.reload()
                savePNG(verticalBar, "taskbar-win10-left.png")
                let darkMenu = snapshotStartMenu(settings: demo)
                darkMenu.appearance = NSAppearance(named: .darkAqua)
                savePNG(darkMenu, "startmenu-win10.png")
                let lightMenu = snapshotStartMenu(settings: demo)
                lightMenu.appearance = NSAppearance(named: .aqua)
                savePNG(lightMenu, "startmenu-win10-light.png")
                let searchMenu = snapshotStartMenu(settings: demo, searchText: "Ca")
                searchMenu.appearance = NSAppearance(named: .darkAqua)
                savePNG(searchMenu, "startmenu-win10-search.png")
                let searchOpen = snapshotStartMenu(settings: demo)
                searchOpen.appearance = NSAppearance(named: .darkAqua)
                savePNG(searchOpen, "search-open.png")
                let searchFilter = snapshotStartMenu(settings: demo, searchText: "Ca")
                searchFilter.appearance = NSAppearance(named: .darkAqua)
                savePNG(searchFilter, "search-filter.png")
                let searchField = Win10SearchBox(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
                searchField.appearance = NSAppearance(named: .darkAqua)
                searchField.placeholderString = L.t("Type here to search", demo.resolvedLanguage)
                searchField.layoutSubtreeIfNeeded()
                savePNG(searchField, "search-field.png")
                let clickedOpen = snapshotStartMenu(settings: demo)
                clickedOpen.appearance = NSAppearance(named: .darkAqua)
                savePNG(clickedOpen, "search-clicked-open.png")
                let previousCatalog = ApplicationCatalog.override
                ApplicationCatalog.override = SnapshotFixture.denseWin10Catalog
                let allAppsScrolled = Win10StartMenuView(settings: demo)
                allAppsScrolled.appearance = NSAppearance(named: .darkAqua)
                allAppsScrolled.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
                allAppsScrolled.layoutSubtreeIfNeeded()
                savePNG(allAppsScrolled, "allapps.png")
                allAppsScrolled.scrollAllAppsForTesting(by: -220)
                savePNG(allAppsScrolled, "allapps-scrolled.png")
                ApplicationCatalog.override = previousCatalog
                if !AppCollections.folders(settings: demo).isEmpty {
                    let expanded = Win10StartMenuView(settings: demo)
                    expanded.appearance = NSAppearance(named: .darkAqua)
                    expanded.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
                    expanded.expandCollectionFoldersForTesting()
                    savePNG(expanded, "allapps-collections.png")
                }
                for (index, name) in [(0, "rail-hover-user.png"), (2, "rail-hover-pictures.png")] {
                    let hoverMenu = snapshotStartMenu(settings: demo)
                    hoverMenu.appearance = NSAppearance(named: .darkAqua)
                    (hoverMenu as? Win10StartMenuView)?.debugHoverRail = index
                    savePNG(hoverMenu, name)
                }
                for edge in [TaskbarEdge.left, .right] {
                    demo.edge = edge
                    savePNG(PreviewRenderer.image(settings: demo, apps: apps, activePID: activePID),
                            "preview-win10-\(edge.rawValue).png")
                }
                demo.edge = .bottom
            }
            if theme == .win8 {
                let bar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
                bar.settings = demo
                bar.apps = win8Apps
                bar.activePID = activePID
                bar.clockText = Clock.time(demo.resolvedLanguage)
                bar.shortDateText = Clock.shortDate()
                bar.inputText = "ENG"
                bar.reload()
                savePNG(bar, "taskbar-win8.png")
                var left = demo
                left.edge = .left
                let verticalBar = TaskbarView(frame: NSRect(x: 0, y: 0,
                                                            width: TaskbarView.verticalWidth(for: left), height: 800))
                verticalBar.settings = left
                verticalBar.apps = win8Apps
                verticalBar.activePID = activePID
                verticalBar.clockText = Clock.time(left.resolvedLanguage)
                verticalBar.shortDateText = Clock.shortDate()
                verticalBar.inputText = "ENG"
                verticalBar.reload()
                savePNG(verticalBar, "taskbar-win8-left.png")
                savePNG(StartMenuRendering.view(settings: demo), "startscreen-win8.png")
                savePNG(StartMenuRendering.view(settings: demo, allApps: true), "startscreen-win8-apps.png")
                savePNG(StartMenuRendering.view(settings: demo, searchText: "Ca"), "startscreen-win8-search.png")
                for edge in [TaskbarEdge.left, .right] {
                    demo.edge = edge
                    savePNG(PreviewRenderer.image(settings: demo, apps: win8Apps, activePID: activePID),
                            "preview-win8-\(edge.rawValue).png")
                }
                demo.edge = .bottom
            }
        }
        demo.theme = .win95
        for edge in [TaskbarEdge.top, .left, .right] {
            demo.edge = edge
            savePNG(PreviewRenderer.image(settings: demo, apps: apps, activePID: activePID), "preview-edge-\(edge.rawValue).png")
        }
        SnapshotFixture.clearUserThemeFixtures()
        var propertiesSettings = s
        propertiesSettings.collapseTrayIcons = true
        propertiesSettings.trayApps = SnapshotFixture.trayAppPaths
        for (language, appearance, name) in [(Language.english, NSAppearance.Name.aqua, "settings-en-light.png"),
                                              (.english, .darkAqua, "settings-en-dark.png"),
                                              (.chinese, .aqua, "settings-zh-light.png"),
                                              (.chinese, .darkAqua, "settings-zh-dark.png")]
            + [Language.traditionalChinese, .french, .spanish, .portuguese, .japanese, .korean, .german]
                .map({ ($0, NSAppearance.Name.aqua, "settings-\($0.localeIdentifier)-light.png") }) {
            var fixture = propertiesSettings
            fixture.language = language
            savePropertiesSnapshot(settings: fixture, name: name, appearance: appearance)
        }
        if let folder = AppCollections.folders(settings: propertiesSettings).first, let item = folder.items.first {
            HiddenStore.fixtureEntries = [AppListEntry.collectionFolder(folder).hiddenEntry, AppListEntry.collectionItem(item).hiddenEntry,
                                          AppListEntry.directory(URL(fileURLWithPath: "/Applications/Utilities")).hiddenEntry]
            savePropertiesSnapshot(settings: propertiesSettings, name: "settings-hidden-items.png", appearance: .aqua)
            HiddenStore.fixtureEntries = []
        }
        saveTrayCustomizeSnapshot(settings: propertiesSettings, name: "properties-tray-customize.png")
        SnapshotFixture.prepareUserThemes(includeBroken: true)
        var userFixture = s
        let hasTealExample = UserThemeCatalog.record(id: "win95-teal") != nil
        let hasOrbExample = UserThemeCatalog.record(id: "win7-image-orb") != nil
        if UserThemeCatalog.record(id: "win95-teal") != nil {
            userFixture.userThemeID = "win95-teal"; userFixture.theme = .win95
            _ = Theme.make(userFixture)
        }
        if UserThemeCatalog.record(id: "win7-image-orb") != nil {
            userFixture.userThemeID = "win7-image-orb"; userFixture.theme = .win7
            _ = Theme.make(userFixture)
        }
        // The dedicated user-theme snapshots are the only renders that require
        // fixture files. The example renders use the already-loaded theme cache.
        SnapshotFixture.clearUserThemeFixtures()
        if hasTealExample {
            userFixture.userThemeID = "win95-teal"; userFixture.theme = .win95
            savePNG(baselineTaskbar(settings: userFixture, pins: []), "taskbar-example-win95-teal.png")
            savePNG(exampleStartButton(settings: userFixture), "startbutton-example-win95-teal.png")
        }
        if hasOrbExample {
            userFixture.userThemeID = "win7-image-orb"; userFixture.theme = .win7
            savePNG(baselineTaskbar(settings: userFixture, pins: []), "taskbar-example-win7-image-orb.png")
            savePNG(exampleStartButton(settings: userFixture), "startbutton-example-win7-image-orb.png")
        }
        for kind in ThemeKind.allCases {
            var settings = SnapshotFixture.settings
            settings.theme = kind
            let id = SnapshotFixture.themeID(kind)
            for edge in TaskbarEdge.allCases {
                settings.edge = edge
                let name = "taskbar-\(id)-\(edge.rawValue).png"
                // Existing edge snapshots retain their original composition.
                let output = snapshotNames.contains(name) ? "taskbar-\(id)-\(edge.rawValue)-default.png" : name
                savePNG(baselineTaskbar(settings: settings, pins: []), output)
            }
            settings.edge = .bottom
            let name = "startmenu-\(id).png"
            savePNG(snapshotStartMenu(settings: settings),
                    snapshotNames.contains(name) ? "startmenu-\(id)-default.png" : name)
        }
        saveMixedStartMenuSnapshots(to: snapshotDir)
        do {
            try MenuMatrix.write(to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("menu-matrix.json"))
        } catch {
            fputs("Menu matrix failed: \(error)\n", stderr)
            exit(1)
        }
        do {
            try writeLayout(to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("layout.json"))
        } catch {
            fputs("Layout dump failed: \(error)\n", stderr)
            exit(1)
        }
        // Append state sheets after every existing image and the layout dump.
        for kind in ThemeKind.allCases {
            var settings = SnapshotFixture.settings
            settings.theme = kind
            settings.edge = .bottom
            let sheet = ButtonSnapshotView(bar: baselineTaskbar(settings: settings, pins: []))
            sheet.appearance = NSAppearance(named: kind == .win10 ? .darkAqua : .aqua)
            let id = SnapshotFixture.themeID(kind)
            savePNG(sheet, "buttons-\(id).png")
            if kind == .win10 || kind == .win11 {
                sheet.appearance = NSAppearance(named: kind == .win10 ? .aqua : .darkAqua)
                savePNG(sheet, "buttons-\(id)-\(kind == .win10 ? "light" : "dark").png")
            }
        }
        do {
            try TraySnapshotView.writeSnapshots(
                to: URL(fileURLWithPath: snapshotDir),
                saveView: { self.savePNG($0, $1) },
                saveImage: { self.savePNG($0, $1) })
        } catch {
            fputs("Tray layout dump failed: \(error)\n", stderr)
            exit(1)
        }
        // Run new coverage last so existing snapshots retain their rendering sequence.
        do {
            try LayoutSnapshotView.writeSnapshots(
                to: URL(fileURLWithPath: snapshotDir),
                saveView: { self.savePNG($0, $1) },
                saveImage: { self.savePNG($0, $1) })
        } catch {
            fputs("Layout variants dump failed: \(error)\n", stderr)
            exit(1)
        }
        saveXPStartMenuSnapshots()
        _ = FileManager.default.createFile(atPath: snapshotDir + "/DONE", contents: nil)
    }

    private func exampleStartButton(settings: TaskbarSettings) -> NSView {
        let button = RetroButton(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        button.kind = .start
        button.theme = Theme.make(settings)
        button.title = L.t(button.theme.startStyle.label.key, settings.resolvedLanguage)
        button.smoothing = button.theme.layoutStyle.forcedSmoothing || settings.fontSmoothing
        return button
    }

    private func savePropertiesSnapshot(settings: TaskbarSettings, name: String,
                                        appearance: NSAppearance.Name = .aqua) {
        let model = PropertiesModel()
        model.draft = settings
        model.refreshThemes()
        let dark = appearance == .darkAqua
        let host = NSHostingView(rootView: propertiesSnapshotRoot(model: model, dark: dark))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 620, height: 1100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 2200)
        host.layoutSubtreeIfNeeded()
        let height = max(1, ceil(host.fittingSize.height))
        window.setContentSize(NSSize(width: 620, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        host.layoutSubtreeIfNeeded()
        savePNG(host, name)
        window.close()
    }

    @ViewBuilder
    private func propertiesSnapshotRoot(model: PropertiesModel, dark: Bool) -> some View {
        if #available(macOS 12.0, *) {
            PropertiesView(model: model, snapshotFullContent: true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
                .tint(.accentColor)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            PropertiesView(model: model, snapshotFullContent: true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
                .background(Color.gray)
        }
    }

    private func saveTrayCustomizeSnapshot(settings: TaskbarSettings, name: String) {
        let model = PropertiesModel()
        model.draft = settings
        let host = NSHostingView(rootView: TrayAppsCustomizeView(model: model)
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 330),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        savePNG(host, name)
        window.close()
    }

    private func saveThemeMenuSnapshot(settings: TaskbarSettings, name: String) {
        let model = PropertiesModel()
        model.draft = settings
        model.refreshThemes()
        let menu = ThemePopupMenu.build(language: settings.resolvedLanguage,
                                        selection: settings.activeThemeID,
                                        userThemes: model.userThemes)
        let host = NSHostingView(rootView: ThemeMenuSnapshotView(menu: menu)
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        savePNG(host, name)
        window.close()
    }

    private func snapshotStartMenu(settings: TaskbarSettings, searchText: String = "") -> NSView {
        return StartMenuRendering.view(settings: settings, searchText: searchText)
    }

    private func aeroScrollHoverSnapshot(settings: TaskbarSettings) -> NSView {
        let applications = (0..<24).map { index in
            let name = "Scroll App \(index + 1)"
            let icon = NSImage(systemSymbolName: "app", accessibilityDescription: name)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            return Win10StartMenuView.Application(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                                  name: name, icon: icon)
        }
        let menu = AeroStartMenuView(settings: settings, allApps: true, applications: applications)
        menu.layoutSubtreeIfNeeded()
        let cursor = NSPoint(x: 90, y: 150)
        menu.debugHoverProgram(atViewportPoint: cursor)
        for _ in 0..<3 {
            menu.debugScrollProgramList(by: 120, keepingCursorAt: cursor)
        }
        return menu
    }

    private func aeroAllAppsNoLineSnapshot(settings: TaskbarSettings) -> NSView {
        let applications = (0..<32).map { index in
            let name = "All Programs App \(index + 1)"
            let icon = NSImage(systemSymbolName: "app", accessibilityDescription: name)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            return Win10StartMenuView.Application(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                                  name: name, icon: icon)
        }
        let menu = AeroStartMenuView(settings: settings, allApps: true, applications: applications,
                                     preserveAllAppsSnapshot: true)
        menu.layoutSubtreeIfNeeded()
        menu.debugScrollProgramList(by: 240, keepingCursorAt: NSPoint(x: 90, y: 150))
        return menu
    }

    private func saveXPStartMenuSnapshots() {
        var settings = SnapshotFixture.settings
        settings.theme = .winXP
        settings.startMenuStyleChoice = .xp
        let screen = SnapshotFixture.screenFrame
        let visible = SnapshotFixture.visibleFrame
        let bar = Self.frame(settings: settings, screenFrame: screen, visibleFrame: visible, hidden: false)
        let context = StartMenuContext(settings: settings, barFrame: bar, startButtonFrame: bar,
                                       screenFrame: screen, visibleFrame: visible)
        savePNG(XPStartMenuView(context: context), "startmenu-xp.png")
        let pins = ["Notes", "Photos", "Music"].map { XPProgram.at(URL(fileURLWithPath: "/Applications/\($0).app")) }
        savePNG(XPStartMenuView(context: context, fixturePins: pins), "startmenu-xp-pins.png")
        savePNG(XPCascadeSnapshotView(menu: XPStartMenuView(context: context), settings: settings), "startmenu-xp-allprograms.png")
        settings.language = .chinese
        let chinese = StartMenuContext(settings: settings, barFrame: bar, startButtonFrame: bar,
                                       screenFrame: screen, visibleFrame: visible)
        savePNG(XPStartMenuView(context: chinese), "startmenu-xp-zh-Hans.png")
        settings.language = .english
        for (theme, edge, name) in [(ThemeKind.win11, TaskbarEdge.bottom, "startmenu-mix-win11-xp.png"),
                                    (.winXP, .left, "startmenu-xp-left.png"), (.winXP, .top, "startmenu-xp-top.png")] {
            settings.theme = theme; settings.edge = edge
            do {
                let taskbar = baselineTaskbar(settings: settings, pins: [])
                let record = try MenuMatrix.sceneRecord(settings: settings, taskbar: taskbar)
                let menu = mixedStartMenuView(settings: settings, record: record)
                guard let barImage = snapshotImage(taskbar), let menuImage = snapshotImage(menu) else { continue }
                savePNG(MixedStartMenuSceneView(screenSize: screen.size, barFrame: record.bar,
                                                menuFrame: record.frame, barImage: barImage, menuImage: menuImage), name)
            } catch {
                fputs("XP snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func saveMixedStartMenuSnapshots(to snapshotDir: String) {
        let pairs: [(ThemeKind, StartMenuStyle, String, TaskbarAlignment)] = [
            (.win11, .win95, "startmenu-mix-win11-win95.png", .center),
            (.win95, .win11, "startmenu-mix-win95-win11.png", .left),
            (.vista, .win10, "startmenu-mix-vista-win10.png", .left),
            (.win10, .win8, "startmenu-mix-win10-win8.png", .left),
            (.win8, .win8, "startmenu-mix-win8-win8.png", .left),
            (.win7, .win7, "startmenu-mix-win7-win7.png", .left),
            (.win11, .win7, "startmenu-mix-win11-left-aligned-win7.png", .left),
            (.winXP, .vista, "startmenu-mix-xp-vista.png", .left)
        ]
        for (theme, style, name, alignment) in pairs {
            var settings = SnapshotFixture.settings
            settings.theme = theme
            settings.startMenuStyleChoice = style
            settings.alignment = alignment
            do {
                let record = try MenuMatrix.sceneRecord(settings: settings)
                let taskbar = baselineTaskbar(settings: settings, pins: [])
                let menu = mixedStartMenuView(settings: settings, record: record)
                guard let barImage = snapshotImage(taskbar), let menuImage = snapshotImage(menu) else { continue }
                savePNG(MixedStartMenuSceneView(screenSize: SnapshotFixture.screenFrame.size,
                                                barFrame: record.bar, menuFrame: record.frame,
                                                barImage: barImage, menuImage: menuImage), name)
            } catch {
                fputs("Mixed start menu snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func mixedStartMenuView(settings: TaskbarSettings, record: MenuMatrix.CaseRecord) -> NSView {
        let context = StartMenuContext(settings: settings, edge: settings.edge, barFrame: record.bar,
                                       startButtonFrame: record.button, screenFrame: SnapshotFixture.screenFrame,
                                       visibleFrame: SnapshotFixture.visibleFrame)
        let template = StartMenuTemplateRegistry.make(context: context)
        let placement = StartMenuTemplateRegistry.placement(for: settings.startMenuStyle)
        if placement.isFullScreen {
            let covers = placement.coversTaskbar(for: settings.theme)
            template.view.frame = NSRect(origin: .zero, size: record.frame.size)
            (template.view as? Win8StartScreenView)?.taskbarStartRect = covers
                ? NSRect(x: record.button.minX - record.frame.minX, y: record.frame.maxY - record.button.maxY,
                         width: record.button.width, height: record.button.height) : nil
        } else {
            template.view.frame = NSRect(origin: .zero, size: record.frame.size)
        }
        template.view.layoutSubtreeIfNeeded()
        return template.view
    }

    private func snapshotImage(_ view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = SnapshotFixture.bitmap(for: view) else { return nil }
        if view.appearance == nil { view.appearance = NSAppearance(named: .aqua) }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func baselineTaskbar(settings: TaskbarSettings, pins: [PinnedApp]) -> TaskbarView {
        let frame = Self.frame(settings: settings, screenFrame: SnapshotFixture.screenFrame,
                               visibleFrame: SnapshotFixture.visibleFrame, hidden: false)
        let bar = TaskbarView(frame: NSRect(origin: .zero, size: frame.size))
        bar.appearance = NSAppearance(named: .aqua)
        bar.isPreview = true
        bar.settings = settings
        bar.apps = SnapshotFixture.sampleApps
        bar.activePID = bar.apps.first?.pid
        bar.pinnedApps = pins
        bar.clockText = Clock.time(settings.resolvedLanguage)
        bar.dateText = Clock.date(settings.resolvedLanguage)
        bar.shortDateText = Clock.shortDate()
        bar.inputText = InputSource.abbreviation()
        bar.reload()
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// All frames are in their immediate parent's coordinates; barFrame is in screen coordinates.
    func writeLayout(to url: URL) throws {
        precondition(SnapshotFixture.isActive)
        let rect = LayoutSnapshotJSON.rect
        let descendants = LayoutSnapshotJSON.descendants
        var cases: [[String: Any]] = []
        for theme in ThemeKind.allCases {
            for edge in TaskbarEdge.allCases {
                for grouping in TaskbarGrouping.allCases {
                    for pinCount in [0, 3] {
                        var settings = SnapshotFixture.settings
                        settings.theme = theme
                        settings.edge = edge
                        settings.taskbarGrouping = grouping
                        let bar = baselineTaskbar(settings: settings,
                                                  pins: pinCount == 0 ? [] : SnapshotFixture.pins)
                        let frame = Self.frame(settings: settings, screenFrame: SnapshotFixture.screenFrame,
                                               visibleFrame: SnapshotFixture.visibleFrame, hidden: false)
                        cases.append([
                            "theme": SnapshotFixture.themeID(theme), "edge": edge.rawValue,
                            "grouping": grouping.rawValue, "pins": pinCount,
                            "barFrame": rect(frame), "subviews": descendants(bar),
                            "tray": ["frame": rect(bar.tray.frame),
                                     "items": bar.tray.debugItemRects.map {
                                         ["name": $0.name, "frame": rect($0.frame)] as [String: Any]
                                     }],
                            "startButton": rect(bar.startButton.frame)
                        ])
                    }
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": cases],
                                              options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

}
