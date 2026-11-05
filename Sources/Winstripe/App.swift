import AppKit
import Darwin
import LaunchAtLogin

private var offscreenThemeDirectory: URL?

@main
@MainActor
enum WinstripeMain {

    nonisolated private static func cleanupOffscreenThemeDirectory() {
        guard let directory = offscreenThemeDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
        offscreenThemeDirectory = nil
    }

    private static func prepareOffscreenThemeDirectory() {
        guard offscreenThemeDirectory == nil else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Winstripe-Offscreen-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            FileHandle.standardError.write(Data("error: unable to create offscreen theme directory: \(error)\n".utf8))
            exit(1)
        }
        offscreenThemeDirectory = directory
        ThemePaths.userDirectoryOverride = directory
        atexit {
            WinstripeMain.cleanupOffscreenThemeDirectory()
        }
    }

    static func main() {
        AppCollections.install()
        let args = CommandLine.arguments
        if args.contains("--l10n-selftest") {
            exit(Int32(L.runSelfTest()))
        }
        if let i = args.firstIndex(of: "--appearance-preview-dump"), i + 1 < args.count {
            exit(Int32(AppearancePreviewDump.run(directory: args[i + 1])))
        }
        if args.contains("--prefs-isolation-selftest") {
            _ = NSApplication.shared
            exit(Int32(PrefsIsolationSelfTest.run()))
        }
        if let i = args.firstIndex(of: "--theme-stack-probe"), i + 1 < args.count, let kb = Int(args[i + 1]) {
            exit(Int32(ThemeStackSelfTest.probe(kilobytes: kb)))
        }
        if args.contains("--all-displays-selftest") {
            _ = NSApplication.shared
            exit(Int32(AllDisplaysSelfTest.run()))
        }
        if args.contains("--active-display-selftest") {
            _ = NSApplication.shared
            exit(Int32(ActiveDisplaySelfTest.run()))
        }
        if args.contains("--resource-bundle-selftest") {
            exit(Int32(ResourceBundleSelfTest.run()))
        }
        if args.contains("--collections-selftest") || args.contains("--web-collections-selftest") {
            _ = NSApplication.shared
            exit(Int32(CollectionsSelfTest.run()))
        }
        if args.contains("--theme-stack-selftest") {
            exit(Int32(ThemeStackSelfTest.run()))
        }
        if args.contains("--symbol-tint-selftest") {
            _ = NSApplication.shared
            exit(Int32(SymbolTintSelfTest.run()))
        }
        if args.contains("--screen-change-selftest") {
            _ = NSApplication.shared
            exit(Int32(ScreenChangeSelfTest.run()))
        }
        if args.contains("--app-catalog-selftest") {
            _ = NSApplication.shared
            exit(Int32(AppCatalogSelfTest.run()))
        }
        if args.contains("--dock-autohide-selftest") {
            exit(Int32(DockAutoHide.runSelfTest()))
        }
        if args.contains("--duplicates-selftest") {
            exit(Int32(DuplicatesSelfTest.run()))
        }
        if args.contains("--theme-hot-reload-selftest") {
            exit(Int32(ThemeHotReloadSelfTest.run()))
        }
        if args.contains("--fullscreen-selftest") {
            exit(Int32(FullscreenSelfTest.run()))
        }
        if args.contains("--win10-search-selftest") {
            _ = NSApplication.shared
            exit(Int32(Win10SearchSelfTest.run()))
        }
        if args.contains("--collection-pins-selftest") {
            _ = NSApplication.shared
            exit(Int32(CollectionPinsSelfTest.run()))
        }
        if args.contains("--collection-folders-selftest") {
            _ = NSApplication.shared
            exit(Int32(CollectionFoldersSelfTest.run()))
        }
        if args.contains("--vista7-scroll-hover-selftest") {
            _ = NSApplication.shared
            exit(Int32(Vista7ScrollHoverSelfTest.run()))
        }
        if args.contains("--vista7-allapps-separator-selftest") {
            _ = NSApplication.shared
            exit(Int32(Vista7AllAppsSeparatorSelfTest.run()))
        }
        if args.contains("--preview-click-selftest") {
            _ = NSApplication.shared
            exit(Int32(WindowPreviewSelfTest.run()))
        }
        if args.contains("--properties-live-selftest") {
            _ = NSApplication.shared
            SnapshotFixture.activate()
            exit(Int32(PropertiesLiveSelfTest.run()))
        }
        if args.contains("--tray-apps-selftest") {
            _ = NSApplication.shared
            exit(Int32(TrayAppsSelfTest.run()))
        }
        if args.contains("--tray-overflow-selftest") {
            _ = NSApplication.shared
            exit(Int32(TrayAppsSelfTest.run()))
        }
        if args.contains("--ime-always-selftest") {
            _ = NSApplication.shared
            exit(Int32(IMEAlwaysSelfTest.run()))
        }
        if args.contains("--launch-theme-selftest") {
            _ = NSApplication.shared
            exit(Int32(LaunchThemeSelfTest.run()))
        }
        if args.contains("--bench-theme-switch") {
            _ = NSApplication.shared
            exit(Int32(ThemeSwitchBench.run()))
        }
        if let i = args.firstIndex(of: "--win8-edit-snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            exit(Int32(Win8AnimationDebug.renderEditSnapshots(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))))
        }
        if let i = args.firstIndex(of: "--win8-anim-frames"), i + 1 < args.count {
            _ = NSApplication.shared
            exit(Int32(Win8AnimationDebug.renderFrames(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))))
        }
        if args.contains("--win8-anim-selftest") {
            _ = NSApplication.shared
            exit(Int32(Win8AnimationDebug.runSelfTest()))
        }
        let offscreenFlags = ["--snapshot-dir", "--win8-edit-snapshot", "--win8-anim-frames", "--win8-anim-selftest", "--win10-search-selftest", "--collection-folders-selftest", "--vista7-scroll-hover-selftest", "--vista7-allapps-separator-selftest", "--preview-click-selftest", "--properties-live-selftest", "--tray-apps-selftest", "--tray-overflow-selftest", "--ime-always-selftest", "--bench-theme-load", "--bench-theme-switch", "--launch-theme-selftest", "--dump-layout", "--print-menu-geometry", "--print-menu-matrix", "--dump-menus", "--validate-theme", "--dump-theme", "--import-theme", "--export-theme", "--hot-reload-test"]
        if args.contains(where: { offscreenFlags.contains($0) }),
           let index = args.firstIndex(of: "--theme-dir") {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("error: --theme-dir requires a directory\n".utf8))
                exit(1)
            }
            #if DEBUG
            ThemeLoader.debugThemeDirectory = URL(fileURLWithPath: args[index + 1])
            #endif
        }
        if let index = args.firstIndex(of: "--user-themes-dir") {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("error: --user-themes-dir requires a directory\n".utf8))
                exit(1)
            }
            ThemePaths.userDirectoryOverride = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        if args.contains(where: { offscreenFlags.contains($0) }) && ThemePaths.userDirectoryOverride == nil {
            prepareOffscreenThemeDirectory()
        }
        #if DEBUG
        if args.contains("--check-theme-parity") { exit(Theme.checkParity() ? 0 : 1) }
        #else
        if args.contains("--check-theme-parity") {
            FileHandle.standardError.write(Data("error: --check-theme-parity requires a debug build\n".utf8))
            exit(1)
        }
        #endif
        if let status = ThemeCLI.run(arguments: args) { exit(status) }
        if let i = args.firstIndex(of: "--snapshot-dir"), i + 1 < args.count {
            activateSnapshotFixture(arguments: args)
            // Render without registering a live app or connecting to the desktop.
            _ = NSApplication.shared
            TaskbarController().writeSnapshots(args[i + 1] as NSString)
            return
        }
        if let i = args.firstIndex(of: "--dump-layout"), i + 1 < args.count {
            activateSnapshotFixture(arguments: args)
            _ = NSApplication.shared
            do {
                try TaskbarController().writeLayout(to: URL(fileURLWithPath: args[i + 1]))
            } catch {
                fputs("Layout dump failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        if args.contains("--print-menu-geometry") {
            activateSnapshotFixture(arguments: args)
            _ = NSApplication.shared
            printMenuGeometry()
            exit(0)
        }
        if let i = args.firstIndex(of: "--print-menu-matrix"), i + 1 < args.count {
            activateSnapshotFixture(arguments: args)
            _ = NSApplication.shared
            do {
                try MenuMatrix.write(to: URL(fileURLWithPath: args[i + 1]))
            } catch {
                fputs("Menu matrix failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        if args.contains("--dump-menus") {
            _ = NSApplication.shared
            TaskbarController().dumpMenus()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }

    private static func activateSnapshotFixture(arguments: [String]) {
        if let i = arguments.firstIndex(of: "--start-menu-style"), i + 1 < arguments.count {
            SnapshotFixture.startMenuStyleOverride = StartMenuStyle(rawValue: arguments[i + 1])
        }
        SnapshotFixture.activate()
        // Fixtures show no collections unless asked for.
        if arguments.contains("--collections-fixture") { FixtureCollectionsProvider.shared.showExamples() }
    }

    private static func printMenuGeometry() {
        // Keep the offscreen geometry dump independent of the host display size.
        // These are the reference display dimensions used by the snapshot fixtures.
        let realFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let realVisible = NSRect(x: 0, y: 0, width: 1866, height: 1050)
        let smallFrame = NSRect(x: 0, y: 0, width: 1024, height: 600)
        let smallVisible = NSRect(x: 0, y: 0, width: 1024, height: 575)
        for (label, frame, visible) in [("real", realFrame, realVisible), ("small", smallFrame, smallVisible)] {
            for kind in ThemeKind.allCases {
                for edge in TaskbarEdge.allCases {
                    var settings = SnapshotFixture.settings
                    settings.theme = kind
                    settings.edge = edge
                    let bar = TaskbarController.frame(settings: settings, screenFrame: frame, visibleFrame: visible, hidden: false)
                    let taskbar = TaskbarView(frame: NSRect(origin: .zero, size: bar.size))
                    taskbar.settings = settings
                    taskbar.reload()
                    let sb = taskbar.startButton.frame; let button = NSRect(x: bar.minX + sb.minX, y: taskbar.isFlipped ? bar.maxY - sb.maxY : bar.minY + sb.minY, width: sb.width, height: sb.height)
                    let menuView = StartMenuRendering.view(settings: settings)
                    let menu = StartMenuGeometry.frame(style: settings.startMenuStyle, menuSize: menuView.frame.size, buttonRect: button,
                                                        barFrame: bar, edge: edge, alignment: settings.alignment,
                                                        screenFrame: frame, visibleFrame: visible)
                    let gap: CGFloat
                    switch edge {
                    case .bottom: gap = menu.minY - bar.maxY
                    case .top: gap = bar.minY - menu.maxY
                    case .left: gap = menu.minX - bar.maxX
                    case .right: gap = bar.minX - menu.maxX
                    }
                    let onScreen = menu.minX >= frame.minX && menu.maxX <= frame.maxX &&
                        menu.minY >= frame.minY && menu.maxY <= visible.maxY
                    print("theme=\(themeLabel(kind)) edge=\(edge.rawValue) screen=\(rectString(frame)) visible=\(rectString(visible)) bar=\(rectString(bar)) button=\(rectString(button)) menu=\(rectString(menu)) gap=\(String(format: "%.1f", gap)) onScreen=\(onScreen) scenario=\(label)")
                }
            }
        }
    }

    private static func rectString(_ rect: NSRect) -> String {
        String(format: "(%.1f,%.1f,%.1f,%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func themeLabel(_ kind: ThemeKind) -> String {
        SnapshotFixture.themeID(kind)
    }
}

@MainActor
private final class Win10SearchSelfTestDelegate: TaskbarViewDelegate {
    var opened = false
    var text = ""

    func taskbarStartPressed() {}
    func taskbarSearchChanged(_ text: String) { opened = true; self.text = text }
    func taskbarSearchSubmitted(_ text: String) {}
    func taskbarAppClicked(_ pid: pid_t) {}
    func taskbarWindowClicked(_ pid: pid_t, windowID: CGWindowID) {}
    func taskbarQuickLaunch(_ url: URL) {}
    func taskbarShowDesktop() {}
    func taskbarToggleTray() {}
    func taskbarMoved(to edge: TaskbarEdge) {}
    func taskbarShowProperties() {}
    func taskbarToggleLock() {}
    func taskbarMenu(for event: NSEvent) -> NSMenu? { nil }
    func taskbarTaskMenu(pid: pid_t, windowID: CGWindowID?, event: NSEvent) -> NSMenu? { nil }
    func taskbarStartMenu(for event: NSEvent) -> NSMenu? { nil }
}

@MainActor
private enum Win10SearchSelfTest {
    static func run() -> Int {
        var settings = TaskbarSettings()
        settings.theme = .win10
        if let result = try? ThemeResolutionCache.shared.loadSync(settings.activeThemeID) {
            Theme.preload(settings.activeThemeID, result: result)
        }
        let bar = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        let delegate = Win10SearchSelfTestDelegate()
        bar.delegate = delegate
        bar.settings = settings
        bar.searchText = "Calculator"
        bar.reload()
        bar.simulateWin10SearchClickForTesting()
        let search = Win10SearchBox(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let searchCell = search.cell as? NSSearchFieldCell
        guard bar.isWin10SearchVisibleForTesting, bar.win10SearchHitFrameForTesting.width > 0,
              searchCell?.isEditable == true, searchCell?.isSelectable == true,
              (searchCell?.placeholderString ?? "") == "",
              (searchCell?.placeholderAttributedString?.string ?? "") == "",
              (searchCell?.searchButtonCell?.title ?? "") == "",
              delegate.opened, delegate.text == "Calculator" else {
            fputs("win10 search selftest failed: search hit frame or Start/query wiring was not invoked\n", stderr)
            return 1
        }
        print("win10 search selftest passed: opened=true query=\(delegate.text)")
        return 0
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updater = AppUpdater.shared
    private var controller: TaskbarController? { bars.primary }
    private lazy var bars = DisplayBarManager { displayID, primary in
        let c = TaskbarController(displayID: displayID)
        c.followsPrimaryScreen = primary
        c.start()
        return c
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLogin.migrateIfNeeded()
        DockAutoHide.applyAtLaunch()
        updater.start()
        bars.reconcile(allDisplays: SettingsStore.shared.current.allDisplays)
        DisplayReconfigurationMonitor.start()
        AppCollections.start()
        AppCatalog.shared.start()
        for name in [NSApplication.didChangeScreenParametersNotification, .winstripeDisplaysReconfigured, SettingsStore.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: name, object: nil)
        }
        guard let c = controller else { return }
        let args = CommandLine.arguments
        ActivationLog.noAXPrompt = args.contains("--no-ax-prompt")
        if args.contains("--pin") || args.contains("--unpin") || args.contains("--list-buttons") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { c.debugPins(arguments: args) }
        }
        // Handy switches for testing / screenshots:
        //   open Winstripe.app --args --show-properties
        //   open Winstripe.app --args --open-start-menu
        if args.contains("--show-properties") { c.showProperties() }
        if args.contains("--open-start-menu") {
            c.perform(#selector(TaskbarController.openStartMenu), with: nil, afterDelay: 0.5)
        }
        if let i = args.firstIndex(of: "--activate-bundle"), i + 1 < args.count {
            let bundleID = args[i + 1]
            ActivationLog.fileEnabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    ActivationLog.write("activate-bundle: \(bundleID) pid=\(app.processIdentifier)")
                    c.taskbarAppClicked(app.processIdentifier)
                } else {
                    ActivationLog.write("activate-bundle: \(bundleID) not running")
                }
            }
        }
        if args.contains("--list-windows") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                c.writeWindowDebugLog()
            }
        }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count,
           let pid = pid_t(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                c.previewDebug(pid: pid)
            }
        }
        if let i = args.firstIndex(of: "--activate-window"), i + 2 < args.count,
           let pid = pid_t(args[i + 1]) {
            ActivationLog.fileEnabled = true
            let title = args[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                c.activateWindowDebug(pid: pid, titleSubstring: title)
            }
        }
    }

    private var displayReconcileGeneration = 0

    @objc private func displaysChanged() {
        displayReconcileGeneration += 1
        let generation = displayReconcileGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.displayReconcileGeneration else { return }
                self.reconcileDisplays()
            }
        }
    }

    /// Settings or displays changed: add or remove per-display bars to match.
    private func reconcileDisplays() {
        bars.reconcile(allDisplays: SettingsStore.shared.current.allDisplays)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showProperties()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.hideOrbForTermination()
    }
}


/// Cold launch: Theme.make for a saved theme must resolve the real theme
/// (not cache the Win95 fallback) without any prior preload.
@MainActor
enum LaunchThemeSelfTest {
    static func run() -> Int {
        var failed = false
        for kind in [ThemeKind.winXP, .win7, .win11, .win10, .vista] {
            ThemeResolutionCache.shared.clearForBenchmark()
            Theme.clearCachesForBenchmark()
            _ = Theme.make(kind)
            let ok = ThemeResolutionCache.shared.cached(kind.id) != nil
            print("launch-theme \(kind.id) resolved=\(ok)")
            if !ok { failed = true }
        }
        print(failed ? "FAIL launch-theme-selftest" : "PASS launch-theme-selftest")
        return failed ? 1 : 0
    }
}
