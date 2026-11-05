import AppKit

/// `--app-catalog-selftest`: Start menus list apps from memory and never wait for the disk. The scan is
/// held back while every menu is built, and later the folders are deleted while menus are built again.
@MainActor
enum AppCatalogSelfTest {
    private typealias F = FixtureCollectionsProvider
    private final class Target: NSObject {
        @objc func open(_ sender: Any?) {}
    }

    /// The Programs menu as nested titles, one string per row.
    private static func titles(_ menu: NSMenu, indent: String = "") -> [String] {
        menu.items.flatMap { item -> [String] in
            [indent + item.title] + (item.submenu.map { titles($0, indent: indent + "  ") } ?? [])
        }
    }

    /// What `ProgramsMenu` listed when it read the disk itself, to hold the cached menu to the same result.
    private static func expectedTitles(roots: AppCatalogRoots) -> [String] {
        func add(_ directory: URL, depth: Int, indent: String) -> [String] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
            var folders: [String] = [], apps: [String] = []
            for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if url.pathExtension == "app" {
                    guard !HiddenStore().snapshot().isHidden(app: url) else { continue }
                    let name = FileManager.default.displayName(atPath: url.path)
                    apps.append(indent + (name.hasSuffix(".app") ? String(name.dropLast(4)) : name))
                } else if depth < 2, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let children = add(url, depth: depth + 1, indent: indent + "  ")
                    if !children.isEmpty { folders += [indent + url.lastPathComponent] + children }
                }
            }
            return folders + apps
        }
        let accessories = add(roots.system, depth: 0, indent: "  ")
        let main = add(roots.applications, depth: 0, indent: "") + add(roots.user, depth: 1, indent: "")
        let all = (accessories.isEmpty ? [] : [L.t("Accessories", .english)] + accessories) + main
        return all.isEmpty ? [L.t("(Empty)", .english)] : all
    }

    private static func fakeApp(_ path: String, in root: URL, bundleID: String? = nil) {
        let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID ?? "com.example.\(name)", "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }

    /// The time to draw every row's icon once, at the size the classic panel draws them.
    private static func drawAllIcons(of menu: NSMenu) -> Double {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                item.image?.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        walk(menu)
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @discardableResult
    private static func spin(timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func run() -> Int {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let fm = FileManager.default
        // The temporary folder is reached through a link, which also covers a root that is.
        let base = fm.temporaryDirectory.appendingPathComponent("Winstripe-AppCatalog-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let roots = AppCatalogRoots(applications: base.appendingPathComponent("Applications"),
                                    system: base.appendingPathComponent("System"),
                                    user: base.appendingPathComponent("User"))
        for path in ["Beta.app", "alpha.app", "Zed/Nested.app", "Zed/Deep/Deeper/Deepest.app", "Stuff.bundle/Inner.app", "Utilities/Tool.app"] {
            fakeApp(path, in: roots.applications)
        }
        try? fm.createDirectory(at: roots.applications.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try? Data("not an app".utf8).write(to: roots.applications.appendingPathComponent("Readme.txt"))
        for path in ["Calc.app", "Utilities/Term.app"] { fakeApp(path, in: roots.system) }
        for path in ["Mine.app", "Sub/SubApp.app", "Sub/Too/Deep.app"] { fakeApp(path, in: roots.user) }

        AppCollections.useFixtures()
        let web = F.item("Beta Web")
        let folder = F.folder("A Collection", id: "catalog-folder", items: [F.item("Inside", folderID: "catalog-folder")])
        F.shared.content = { _ in (rootItems: [web], folders: [folder]) }
        var settings = TaskbarSettings()
        settings.language = .english
        let target = Target()
        func programs(_ webFolders: [CollectionFolder] = [], _ webItems: [CollectionItem] = []) -> NSMenu {
            ProgramsMenu.build(target: target, action: #selector(Target.open(_:)), lang: .english, webFolders: webFolders, webItems: webItems)
        }
        let probe = AppCatalogProbe.shared
        let catalog = AppCatalog.shared
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: AppCatalog.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Cold: the first scan cannot finish, so anything waiting for it would hang here.
        let gate = DispatchSemaphore(value: 0)
        catalog.configureForTesting(roots: roots) { roots, extras, addresses in
            // Stays open once released, for the later scans.
            _ = gate.wait(timeout: .now() + 30)
            gate.signal()
            return AppCatalogScanner.scan(roots: roots, extraPaths: extras, addresses: addresses)
        }
        catalog.refresh()
        let cold = titles(programs([folder], [web]))
        check(cold == ["A Collection", "  Inside", "Beta Web", L.t("Loading…", .english)], "cold: shows collections and Loading (got \(cold))")
        func view(_ style: StartMenuStyle, allApps: Bool = true) -> NSView {
            var themed = settings
            themed.startMenuStyleChoice = style
            return StartMenuRendering.view(settings: themed, allApps: allApps)
        }
        let win10 = Win10StartMenuView(settings: settings)
        let win11 = Win11StartMenuView(settings: settings, allApps: true)
        let views = StartMenuStyle.allCases.map { view($0) }
        let xp = views.compactMap { $0 as? XPStartMenuView }.first
        let aero = views.compactMap { $0 as? AeroStartMenuView }.first
        check(xp != nil && aero != nil, "cold: every style builds a menu")
        check(!win10.debugListedAppNames().contains("Calc") && !win11.debugListRowNames().contains("Calc"), "cold: no app is listed before the scan")
        check(catalog.snapshot == nil, "cold: every menu was built while the scan was held back")
        check(XPProgram.contents(of: roots.applications, webFolders: [folder], webItems: [web]).map(\.name) == ["A Collection", "Beta Web"],
              "cold: the XP flyout shows what is available")
        check(!catalog.isReady, "cold: the catalog reports it is not ready")

        // The bug's own path: the Win95 Start menu, hovering Programs, as a real panel off in a corner.
        var win95 = settings
        win95.startMenuStyleChoice = .win95
        let owner = TaskbarController()
        let startMenu = StartMenuController(owner: owner)
        startMenu.show(buttonRect: NSRect(x: 0, y: 0, width: 60, height: 24), barFrame: NSRect(x: 0, y: 0, width: 800, height: 24),
                       edge: .bottom, settings: win95, screen: nil)
        startMenu.debugShowPrograms()
        check(startMenu.debugClassicPanelCount == 1, "win95: Programs opens while the scan is held back")
        check(startMenu.debugProgramsTitles.last == L.t("Loading…", .english), "win95: the panel says Loading (got \(startMenu.debugProgramsTitles))")

        // Ready: open menus update themselves, in the order the menus always used.
        gate.signal()
        check(spin { catalog.isReady }, "ready: the scan finished")
        check(changes == 1, "ready: one change is reported (got \(changes))")
        check(win10.debugListedAppNames().contains("Calc"), "ready: an open Win10 menu lists the apps (got \(win10.debugListedAppNames()))")
        check(win11.debugListRowNames().contains("Nested"), "ready: an open Win11 menu lists the apps (got \(win11.debugListRowNames()))")
        check(aero?.debugProgramNames().contains("Calc") == true, "ready: an open Aero menu lists the apps")
        check(xp?.debugFrequentNames().contains("Calc") == true, "ready: an open XP menu lists the apps")
        check(startMenu.debugClassicPanelCount == 1 && startMenu.debugProgramsTitles.contains("alpha"),
              "win95: the open panel updates (got \(startMenu.debugProgramsTitles))")
        check(!startMenu.debugProgramsTitles.contains(L.t("Loading…", .english)), "win95: Loading goes away")
        startMenu.close(notify: false)
        check(!startMenu.isOpen && startMenu.debugClassicPanelCount == 0, "win95: closing leaves no panel")

        let expected = expectedTitles(roots: roots)
        check(titles(programs()) == expected, "order: same rows as reading the disk\n got \(titles(programs()))\nwant \(expected)")
        check(expected.contains("Stuff.bundle") && !expected.contains("Empty") && !expected.contains("Readme"), "order: the fixture covers packages, empty folders and files")
        let merged = titles(programs([folder], [web]))
        check(merged.firstIndex(of: "Beta") == merged.firstIndex(of: "Beta Web").map { $0 - 1 }, "order: a collection item sorts in with the apps (got \(merged))")
        let flat = Win10StartMenuView.loadApplications().map(\.name)
        check(flat == ["alpha", "Beta", "Calc", "Mine", "Term", "Tool"], "flat list (got \(flat))")
        let deep = win11.debugListRowNames().filter { !["A Collection", "Beta Web"].contains($0) }
        check(deep == ["alpha", "Beta", "Calc", "Deep", "Deepest", "Mine", "Nested", "SubApp", "Term", "Tool"], "deep list leaves out package contents (got \(deep))")
        let xpRoot = XPProgram.contents(of: roots.applications).map(\.name)
        check(xpRoot == ["alpha", "Beta", "Empty", "Utilities", "Zed"], "XP root lists apps and plain folders (got \(xpRoot))")
        let zed = roots.applications.appendingPathComponent("Zed")
        check(XPProgram.contents(of: zed.appendingPathComponent("Deep/Deeper")).map(\.name) == ["Deepest"], "XP opens a folder at any depth")

        // Icons load off the main thread once, into the image every list already holds.
        let alpha = roots.applications.appendingPathComponent("alpha.app")
        let image = AppIconCache.shared.icon(for: alpha)
        check(image === AppIconCache.shared.icon(for: alpha), "icons: a path keeps one image")
        check(spin { AppIconCache.shared.isSettled }, "icons: all loaded")
        let loads = probe.current.iconLoads
        check(loads > 0, "icons: loaded in the background")
        _ = titles(programs())
        check(probe.current.iconLoads == loads, "icons: building a menu loads no icon that is cached")
        for size in [16, 48] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            if let rep, let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                check((rep.colorAt(x: size / 2, y: size / 2)?.alphaComponent ?? 0) > 0, "icons: \(size)px draws something")
            }
        }

        // Changes on disk: a watcher notices a new app, and an updated app gets its icon drawn again.
        catalog.watch(latency: 0.2)
        let beforeWatch = titles(programs())
        fakeApp("Fresh.app", in: roots.applications)
        check(spin { titles(programs()).contains("Fresh") }, "watch: a new app appears (was \(beforeWatch))")
        catalog.stopWatching()
        let loadsBefore = probe.current.iconLoads
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                              ofItemAtPath: alpha.appendingPathComponent("Contents/Info.plist").path)
        catalog.refresh()
        check(spin { probe.current.iconLoads > loadsBefore }, "reload: an updated app's icon is drawn again")
        check(image === AppIconCache.shared.icon(for: alpha), "reload: lists keep the same image")
        check(spin { !catalog.isScanning && AppIconCache.shared.isSettled }, "reload: finished")

        // Cache only: with the folders gone, nothing here may notice, unless it reads the disk.
        let cached = titles(programs())
        let scansBefore = probe.current.scans
        try? fm.removeItem(at: base)
        check(titles(programs()) == cached, "cache: the menu is rebuilt from memory (got \(titles(programs())))")
        check(XPProgram.contents(of: zed).map(\.name) == ["Deep", "Nested"], "cache: the XP flyout reads memory")
        check(Win10StartMenuView.loadApplications().map(\.name).contains("Calc"), "cache: the app lists read memory")
        _ = StartMenuStyle.allCases.map { view($0) }
        HiddenStore().hide(HiddenEntry(kind: .app, key: "com.example.Beta", name: "Beta", path: nil))
        let hiddenRows = titles(programs())
        check(!hiddenRows.contains("Beta") && hiddenRows.contains("alpha"), "cache: hiding matches by bundle ID (got \(hiddenRows))")
        check(!win10.debugListedAppNames().contains("Beta"), "cache: an open list drops a hidden app")
        HiddenStore().showAll()
        check(titles(programs()) == cached, "cache: showing it again restores the row")
        // Lists ask for a bundle ID per row. This one exists only in the index, so reading the bundle cannot find it.
        let ghost = base.appendingPathComponent("Ghost.app")
        AppBundleIDIndex.shared.replace([ghost.path: "com.example.ghost"])
        check(PinnedApp(url: ghost).bundleID == "com.example.ghost", "cache: a row's bundle ID comes from the scan")
        check(probe.current.scans == scansBefore, "cache: menus started no scan (\(probe.current.scans - scansBefore))")

        // A later scan of the empty folders does replace the list.
        catalog.refresh()
        check(spin { titles(programs()) == [L.t("(Empty)", .english)] }, "rescan: a removed app leaves the menu (got \(titles(programs())))")

        // The real folders of this Mac, compared with reading them directly.
        catalog.configureForTesting(roots: .standard)
        catalog.refresh()
        check(spin { catalog.isReady }, "real: the scan finished")
        let real = titles(programs()), realExpected = expectedTitles(roots: .standard)
        check(real == realExpected, "real: same rows as reading the disk\n got \(real)\nwant \(realExpected)")
        check(spin { AppIconCache.shared.isSettled }, "real: icons finished")
        let start = DispatchTime.now().uptimeNanoseconds
        let realMenu = programs()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let drawMilliseconds = drawAllIcons(of: realMenu)

        let counts = probe.current
        check(counts.scans > 0 && counts.scansOnMain == 0, "threads: \(counts.scansOnMain) of \(counts.scans) scans ran on the main thread")
        check(counts.iconLoads > 0 && counts.iconLoadsOnMain == 0, "threads: \(counts.iconLoadsOnMain) of \(counts.iconLoads) icon loads ran on the main thread")

        if failures.isEmpty {
            print("PASS app-catalog-selftest: \(counts.scans) scans and \(counts.iconLoads) icon loads off the main thread; Programs menu built from cache in \(String(format: "%.1f", milliseconds)) ms, icons drawn in \(String(format: "%.1f", drawMilliseconds)) ms")
            return 0
        }
        failures.forEach { print("FAIL app-catalog-selftest: \($0)") }
        return 1
    }
}
