import AppKit

/// The app's link to App Collections. Everything goes through `Collections.provider`. The disabled provider
/// stays installed unless something replaces it here, and then every Start menu simply shows no collection folders.
@MainActor
enum AppCollections {
    static var provider: any CollectionsProviding { Collections.provider }

    /// Whether this Mac had Winstripe preferences when the process started.
    private static var hadPreferences = false
    private static let defaultPinsHandledKey = "collectionDefaultPinsHandled"

    /// Called first thing in `main`, before anything can write a preference, so `hadPreferences` tells a
    /// new install from an existing one. A provider must be installed here too, before menus read it.
    static func install() {
        hadPreferences = CFPreferencesCopyKeyList(kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
    }

    /// Live app only: collections are always on and have no settings.
    static func start() {
        guard !SnapshotFixture.isActive else { return }
        provider.start(log: { debugLog($0) })
        addDefaultPins(isNewInstall: !hadPreferences)
    }

    /// The pins the provider asks for: first-level items, then each folder followed by its items.
    /// An installed Mac app pins as that app, as it does from a list row. Hiding an entry does not
    /// exclude it, since a pin stays on the taskbar when its entry is hidden.
    static func defaultPins(settings: TaskbarSettings) -> [PinnedApp] {
        func pin(_ item: CollectionItem) -> PinnedApp {
            item.opensApplication ? PinnedApp(url: item.url) : PinnedApp(collectionItem: item)
        }
        let rootPins = allRootItems(settings: settings).filter(\.pinnedByDefault).map(pin)
        return rootPins + allFolders(settings: settings).flatMap { folder in
            (folder.pinnedByDefault ? [PinnedApp(collectionFolder: folder)] : []) + folder.items.filter(\.pinnedByDefault).map(pin)
        }
    }

    /// Runs once ever: a new install gets the default pins, and an existing user is only marked as handled,
    /// so no launch adds them later and a pin the user removes stays removed until Reset to defaults.
    static func addDefaultPins(isNewInstall: Bool) {
        let defaults = Prefs.defaults
        guard provider.isAvailable, !defaults.bool(forKey: defaultPinsHandledKey) else { return }
        defaults.set(true, forKey: defaultPinsHandledKey)
        if isNewInstall { restoreDefaultPins() }
    }

    /// Adds the default pins that are missing, after the user's own, which stay. Also used by Reset to defaults.
    static func restoreDefaultPins() {
        let store = PinStore()
        for pin in defaultPins(settings: SettingsStore.shared.current) where !store.contains(pin) {
            store.insert(pin, at: store.apps.count)
        }
    }

    private static func allFolders(settings: TaskbarSettings) -> [CollectionFolder] {
        provider.folders(localeIdentifier: settings.resolvedLanguage.localeIdentifier)
    }

    private static func allRootItems(settings: TaskbarSettings) -> [CollectionItem] {
        provider.rootItems(localeIdentifier: settings.resolvedLanguage.localeIdentifier)
    }

    /// `folder` without its hidden items, or nil when none are left.
    private static func visible(_ folder: CollectionFolder, hidden: HiddenSet) -> CollectionFolder? {
        let items = folder.items.filter { !hidden.isHidden(collectionItem: $0.id) }
        guard !items.isEmpty else { return nil }
        return CollectionFolder(id: folder.id, sourceIDs: folder.sourceIDs, name: folder.name, icon: folder.icon, items: items,
                                pinnedByDefault: folder.pinnedByDefault)
    }

    /// The folders the lists show, without hidden folders and items.
    static func folders(settings: TaskbarSettings) -> [CollectionFolder] {
        let hidden = HiddenStore().snapshot()
        return allFolders(settings: settings)
            .filter { !hidden.isHidden(collectionFolder: $0) }
            .compactMap { visible($0, hidden: hidden) }
    }

    /// The first-level items, listed with the apps, without hidden items.
    static func rootItems(settings: TaskbarSettings) -> [CollectionItem] {
        let hidden = HiddenStore().snapshot()
        return allRootItems(settings: settings).filter { !hidden.isHidden(collectionItem: $0.id) }
    }

    // MARK: Pins

    /// A pin stays on the taskbar when its entry is hidden, so these look at every entry.
    private static func item(for pin: PinnedApp, settings: TaskbarSettings) -> CollectionItem? {
        guard let id = pin.collection?.id, pin.collection?.isFolder == false else { return nil }
        return (allRootItems(settings: settings) + allFolders(settings: settings).flatMap(\.items)).first { $0.id == id }
    }

    private static func folder(for pin: PinnedApp, settings: TaskbarSettings) -> CollectionFolder? {
        guard let id = pin.collection?.id, pin.collection?.isFolder == true else { return nil }
        return allFolders(settings: settings).first { $0.sourceIDs.contains(id) }
    }

    /// The current name and icon of a collection pin, or what was saved with it when its entry is gone.
    static func display(of pin: PinnedApp, settings: TaskbarSettings) -> (name: String, icon: NSImage) {
        let isFolder = pin.collection?.isFolder == true
        if isFolder, let folder = folder(for: pin, settings: settings) { return (folder.name, folder.icon) }
        if !isFolder, let item = item(for: pin, settings: settings) { return (item.name, item.icon) }
        let symbol = isFolder ? "folder.fill" : "globe"
        return (pin.collection?.name ?? "", NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32)))
    }

    /// Opens a pinned item. A pinned folder lists its visible items in a menu at the pointer.
    /// A pin whose entry is gone opens what was saved with it, since the provider no longer knows it.
    static func open(_ pin: PinnedApp, settings: TaskbarSettings) {
        guard pin.collection?.isFolder == true else {
            if let item = item(for: pin, settings: settings) {
                provider.open(item)
            } else {
                NSWorkspace.shared.open(pin.url)
            }
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hidden = HiddenStore().snapshot()
        for item in folder(for: pin, settings: settings).flatMap({ visible($0, hidden: hidden) })?.items ?? [] {
            let row = NSMenuItem(title: item.name, action: #selector(CollectionPinOpener.openItem(_:)), keyEquivalent: "")
            row.target = CollectionPinOpener.shared
            row.representedObject = item
            row.toolTip = item.detail
            let icon = item.icon.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            row.image = icon
            menu.addItem(row)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: L.t("(Empty)", settings.resolvedLanguage), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Every item, for search.
    static func items(settings: TaskbarSettings) -> [CollectionItem] {
        rootItems(settings: settings) + folders(settings: settings).flatMap(\.items)
    }

    // MARK: Opening

    /// Opens a list row: the provider decides what a collection item does, and anything else opens as a URL.
    static func open(_ entry: AppListEntry) {
        switch entry {
        case .collectionItem(let item): provider.open(item)
        case .app(let url), .directory(let url): NSWorkspace.shared.open(url)
        case .collectionFolder: break
        }
    }

    /// Opens a row of a classic menu, which carries its URL whatever it stands for.
    static func open(row: NSMenuItem, url: URL) {
        if case .collectionItem(let item)? = (row as? ProgramsMenuItem)?.entry {
            provider.open(item)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Offscreen output and self-tests never see the real provider or look up installed apps.
    static func useFixtures() {
        Collections.install(FixtureCollectionsProvider.shared)
    }
}

/// The entries of offscreen snapshots and self-tests, written in Swift. It shows nothing until given
/// content, and records what it is asked to open instead of opening it.
@MainActor
final class FixtureCollectionsProvider: CollectionsProviding {
    static let shared = FixtureCollectionsProvider()
    /// Locale identifier -> what to show.
    var content: (String) -> (rootItems: [CollectionItem], folders: [CollectionFolder]) = { _ in ([], []) }
    private(set) var opened: [CollectionItem] = []

    var isAvailable: Bool { true }
    func start(log: @escaping @MainActor (String) -> Void) {}
    func folders(localeIdentifier: String) -> [CollectionFolder] { content(localeIdentifier).folders }
    func rootItems(localeIdentifier: String) -> [CollectionItem] { content(localeIdentifier).rootItems }
    func open(_ item: CollectionItem) { opened.append(item) }

    static func item(_ name: String, id: String = UUID().uuidString, detail: String? = nil, symbol: String = "globe", url: String = "https://example.com",
                     bundleId: String? = nil, folderID: String? = nil, pinned: Bool = false) -> CollectionItem {
        let size = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let color = NSColor(srgbRed: 0x2F / 255.0, green: 0x7F / 255.0, blue: 0xD8 / 255.0, alpha: 1)
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.symbolTinted([color], configuration: size)
        return CollectionItem(folderID: folderID, id: id, name: name, detail: detail, url: URL(string: url)!,
                              icon: icon ?? NSImage(size: NSSize(width: 32, height: 32)), bundleId: bundleId, webURL: URL(string: url)!, pinnedByDefault: pinned)
    }

    static func folder(_ name: String, id: String, sourceIDs: [String]? = nil, pinned: Bool = false, items: [CollectionItem]) -> CollectionFolder {
        let color = NSColor(srgbRed: 0xE8 / 255.0, green: 0xB6 / 255.0, blue: 0x40 / 255.0, alpha: 1)
        let icon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.symbolTinted([color])
        return CollectionFolder(id: id, sourceIDs: sourceIDs, name: name, icon: icon ?? NSImage(size: NSSize(width: 32, height: 32)), items: items, pinnedByDefault: pinned)
    }

    /// `--collections-fixture`: a first-level item, and folders of web and Mac-app items.
    func showExamples() {
        typealias F = FixtureCollectionsProvider
        content = { locale in
            let zh = locale.lowercased().hasPrefix("zh")
            return (rootItems: [F.item("MDN Web Docs", id: "2C5355A4-4B5D-4E28-AB9C-724A4FFCFB55", detail: "Documentation for web developers",
                                       symbol: "chevron.left.forwardslash.chevron.right", url: "https://developer.mozilla.org")],
                    folders: [
                        F.folder(zh ? "参考资料" : "Reference", id: "reference", items: [
                            F.item(zh ? "维基百科" : "Wikipedia", id: "F9599C2B-10CC-4201-972F-620EE9695235", detail: zh ? "自由的百科全书" : "The free encyclopedia",
                                   symbol: "book.closed", url: "https://www.wikipedia.org", folderID: "reference")]),
                        F.folder(zh ? "Mac 应用" : "Mac Apps", id: "mac-apps", items: [
                            F.item("Safari", id: "21BFF88E-2F3B-4620-9E08-93BD2876D8E8", detail: zh ? "启动 Safari；未安装时打开其网页" : "Launches Safari, or opens its web page if it is not installed",
                                   url: "https://www.apple.com/safari/", bundleId: "com.apple.Safari", folderID: "mac-apps"),
                            F.item(zh ? "计算器" : "Calculator", id: "03D9F9F3-82D0-455B-BBC5-DF785362D85B",
                                   url: "https://support.apple.com/guide/calculator/welcome/mac", bundleId: "com.apple.calculator", folderID: "mac-apps")]),
                        F.folder(zh ? "地图与出行" : "Maps & Travel", id: "maps", items: [
                            F.item("OpenStreetMap", id: "9F17A1F5-0F5E-4C92-8F2C-A1540B3431F6", detail: zh ? "可自由编辑的世界地图" : "Free, editable map of the world",
                                   symbol: "map", url: "https://www.openstreetmap.org", folderID: "maps")])])
        }
    }
}

/// `--collections-selftest`: the app's types, and that the installed provider keeps to what the app relies on.
@MainActor
enum CollectionsSelfTest {
    static func run() -> Int {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ label: String) {
            checks += 1
            if !ok { failures.append(label) }
        }

        check(CollectionsValidation.httpsURL("https://example.com/a?b=1") != nil, "url: https accepted")
        for bad in ["http://example.com", "ftp://example.com", "javascript:alert(1)", "file:///etc/passwd",
                    "https://", "example.com", "", "mailto:a@example.com"] {
            check(CollectionsValidation.httpsURL(bad) == nil, "url: rejected \(bad)")
        }
        check(CollectionsValidation.itemID("6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f") == "6F1C2D3E-4B5A-4C6D-8E7F-9A0B1C2D3E4F", "uuid: lowercase accepted, canonical uppercase")
        for bad in ["wikipedia", "", "6F1C2D3E-4B5A-4C6D-8E7F", "6F1C2D3E4B5A4C6D8E7F9A0B1C2D3E4F"] {
            check(CollectionsValidation.itemID(bad) == nil, "uuid: rejected \(bad)")
        }
        for id in ["tools", "a b/c?d#e%f", "工具", "-._~"] {
            let url = CollectionFolder.folderURL(id: id)
            check(url.scheme == CollectionFolder.urlScheme && CollectionFolder.id(fromFolderURL: url) == id, "folder URL round-trips \(id) (got \(url.absoluteString))")
        }
        let disabled = DisabledCollectionsProvider()
        check(!disabled.isAvailable && disabled.folders(localeIdentifier: "en").isEmpty && disabled.items(localeIdentifier: "en").isEmpty, "disabled provider shows nothing")

        let provider = AppCollections.provider
        guard provider.isAvailable else {
            print("SKIP collections selftest (collections are not included in this build)")
            return failures.isEmpty ? 0 : 1
        }
        provider.start(log: { _ in })
        var entries = 0
        for locale in ["en", "zh-Hans"] {
            func checkItems(_ items: [CollectionItem], folderID: String?) {
                let owner = folderID ?? "first level"
                check(Set(items.map(\.id)).count == items.count, "\(locale) \(owner): item ids are unique")
                for item in items {
                    check(CollectionsValidation.itemID(item.id) == item.id, "\(locale) \(owner): id \(item.id) is a canonical UUID")
                    check(!item.name.isEmpty, "\(locale) \(owner): \(item.id) has a name")
                    check(item.folderID == folderID, "\(locale) \(owner): \(item.name) knows its folder")
                    check(item.webURL.scheme == "https" && item.webURL.host != nil, "\(locale) \(owner): \(item.name) has an https webURL")
                    check(item.url == item.webURL || item.url.isFileURL, "\(locale) \(owner): \(item.name) stands for its webURL or an installed app")
                }
            }
            let rootItems = provider.rootItems(localeIdentifier: locale)
            let folders = provider.folders(localeIdentifier: locale)
            checkItems(rootItems, folderID: nil)
            check(Set(folders.map(\.id)).count == folders.count, "\(locale): folder ids are unique")
            for folder in folders {
                check(!folder.id.isEmpty && !folder.name.isEmpty, "\(locale): folder \(folder.id) has an id and a name")
                check(folder.sourceIDs.first == folder.id, "\(locale): folder \(folder.id) lists itself first in sourceIDs")
                checkItems(folder.items, folderID: folder.id)
            }
            check(provider.items(localeIdentifier: locale).count == rootItems.count + folders.reduce(0) { $0 + $1.items.count }, "\(locale): items are the first-level items and every folder's")
            entries = rootItems.count + folders.count + folders.reduce(0) { $0 + $1.items.count }
        }

        if failures.isEmpty {
            print("PASS collections selftest (\(checks) checks, provider \(type(of: provider)), \(entries) entries)")
            return 0
        }
        for failure in failures { fputs("FAIL collections selftest: \(failure)\n", stderr) }
        return 1
    }
}

@MainActor
final class CollectionPinOpener: NSObject {
    static let shared = CollectionPinOpener()

    @objc func openItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? CollectionItem else { return }
        AppCollections.provider.open(item)
    }
}

/// `--collection-folders-selftest`: first-level items and same-name folders in the Windows 10 and 11
/// All apps lists, expanding and collapsing a folder through a real click and press, and the right-click
/// Hide and Pin to taskbar actions on apps and folders.
@MainActor
enum CollectionFoldersSelfTest {
    static func run() -> Int {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            if !ok { failures.append(label) }
        }
        SnapshotFixture.activate()
        typealias F = FixtureCollectionsProvider
        let fixtureRoot = [F.item("Root Item")]
        let fixtureFolders = [F.folder("Merged", id: "a", sourceIDs: ["a", "b"], items: [F.item("Inside A", folderID: "a"), F.item("Inside B", folderID: "a")])]
        F.shared.content = { _ in (rootItems: fixtureRoot, folders: fixtureFolders) }
        let settings = SnapshotFixture.settings

        let win10 = Win10StartMenuView(settings: settings)
        let window = NSWindow(contentRect: win10.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = win10
        func clickFolder(rect: NSRect? = nil) {
            guard let rect = rect ?? win10.debugCollectionFolderRects().first else { return }
            let point = win10.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 0) else { return }
            win10.mouseUp(with: event)
        }
        check(win10.debugCollectionFolderRects().count == 1, "win10: a folder shows as one row")
        check(win10.debugListedAppNames().contains("Root Item"), "win10: first-level item is listed with the apps")
        check(!win10.debugListedAppNames().contains("Inside A"), "win10: a folder starts collapsed")
        clickFolder()
        let opened = win10.debugListedAppNames()
        check(opened.contains("Inside A") && opened.contains("Inside B"), "win10: a click expands the merged folder (got \(opened))")
        clickFolder()
        check(!win10.debugListedAppNames().contains("Inside A"), "win10: a second click collapses the folder")

        let win11 = Win11StartMenuView(settings: settings, allApps: true)
        let rows = win11.debugListRowNames()
        check(rows.contains("Root Item"), "win11: first-level item is listed with the apps")
        check(rows.filter { $0.lowercased() == "merged" } == ["Merged"], "win11: a folder shows as one row (got \(rows))")
        check(rows == rows.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "win11: rows sort by name (got \(rows))")
        win11.debugPressListRow(named: "Merged")
        let expanded = win11.debugListRowNames()
        if let folder = expanded.firstIndex(of: "Merged"), folder + 2 < expanded.count {
            check(Array(expanded[(folder + 1)...(folder + 2)]) == ["Inside A", "Inside B"], "win11: items follow their folder (got \(expanded))")
        } else {
            check(false, "win11: a press expands the merged folder (got \(expanded))")
        }
        win11.debugPressListRow(named: "Merged")
        check(win11.debugListRowNames() == rows, "win11: a second press collapses the folder")

        // Opening: every way to an item ends at the provider, which gets the item itself.
        func opensRootItem(_ label: String, _ action: () -> Void) {
            let before = F.shared.opened.count
            action()
            check(F.shared.opened.count == before + 1 && F.shared.opened.last?.name == "Root Item", "open: \(label) goes to the provider (got \(F.shared.opened.dropFirst(before).map(\.name)))")
        }
        win11.onLaunch = { AppCollections.open($0) }
        opensRootItem("a win11 row") { win11.debugPressListRow(named: "Root Item") }
        win10.onLaunch = { AppCollections.open($0) }
        opensRootItem("a win10 row") { clickFolder(rect: win10.debugAppRect(named: "Root Item")) }
        if let rootItem = AppCollections.rootItems(settings: settings).first {
            opensRootItem("a list entry") { AppCollections.open(AppListEntry.collectionItem(rootItem)) }
            let classic = ProgramsMenu.webItem(rootItem, target: CollectionPinOpener.shared, action: #selector(CollectionPinOpener.openItem(_:)))
            opensRootItem("a classic menu row") { AppCollections.open(row: classic, url: rootItem.url) }
            opensRootItem("a taskbar pin") { AppCollections.open(PinnedApp(collectionItem: rootItem), settings: settings) }
            let pinnedRow = NSMenuItem()
            pinnedRow.representedObject = rootItem
            opensRootItem("a pinned folder's menu") { CollectionPinOpener.shared.openItem(pinnedRow) }
            if let found = Win10StartMenuView.firstApplication(matching: "Root Item") {
                opensRootItem("taskbar search") { AppCollections.open(found.listEntry) }
            } else {
                check(false, "open: taskbar search finds the item")
            }
        }

        // Right-click menus: every kind of row offers Pin to taskbar and Hide; tiles do not offer Hide.
        func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }
        func perform(_ title: String, in menu: NSMenu) {
            if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
        }
        let calculator = URL(fileURLWithPath: "/Applications/Calculator.app")
        let utilities = URL(fileURLWithPath: "/Applications/Utilities")
        guard let root = AppCollections.rootItems(settings: settings).first, let merged = AppCollections.folders(settings: settings).first,
              let inside = merged.items.first else {
            fputs("FAIL collection folders selftest: fixture entries are missing\n", stderr)
            return 1
        }
        check(merged.sourceIDs == ["a", "b"], "merged folder lists its source ids (got \(merged.sourceIDs))")
        for (label, entry) in [("app", AppListEntry.app(calculator)), ("directory", .directory(utilities)),
                               ("web item", .collectionItem(root)), ("folder", .collectionFolder(merged))] {
            let menu = titles(AppPinMenu.shared.menu(entry: entry, settings: settings))
            check(menu.first == "Pin to taskbar" && menu.last == "Hide", "menu: \(label) offers pin and hide (got \(menu))")
            let isFile = label == "app" || label == "directory"
            check(menu.contains("Show in Finder") == isFile, "menu: \(label) offers Show in Finder only for a file (got \(menu))")
            check(!titles(AppPinMenu.shared.menu(entry: entry, settings: settings, includeHide: false)).contains("Hide"), "menu: \(label) can leave out hide")
        }
        check(titles(AppPinMenu.shared.menu(pin: PinnedApp(collectionFolder: merged), settings: settings)) == ["Pin to taskbar"],
              "menu: a collection pin on the taskbar has only its pin action")

        // Hiding updates open lists and survives only in the hidden store.
        let hider = AppPinMenu.shared
        perform("Hide", in: hider.menu(entry: .collectionItem(root), settings: settings))
        check(HiddenStore.fixtureEntries.map(\.kind) == [.collectionItem], "hide: stored for the item")
        check(!win10.debugListedAppNames().contains("Root Item"), "hide: win10 drops a first-level item at once")
        check(!win11.debugListRowNames().contains("Root Item"), "hide: win11 drops a first-level item at once")
        check(AppCollections.items(settings: settings).allSatisfy { $0.id != root.id }, "hide: search no longer finds the item")
        perform("Hide", in: hider.menu(entry: .collectionFolder(merged), settings: settings))
        check(AppCollections.folders(settings: settings).isEmpty, "hide: a merged folder hides whole, not just its first source")
        check(win10.debugCollectionFolderRects().isEmpty && !win11.debugListRowNames().contains("Merged"), "hide: open lists drop the folder")
        HiddenStore().show(AppListEntry.collectionFolder(merged).hiddenEntry)
        check(win11.debugListRowNames().contains("Merged") && win10.debugCollectionFolderRects().count == 1, "show: the folder returns to open lists")
        for item in merged.items { HiddenStore().hide(AppListEntry.collectionItem(item).hiddenEntry) }
        check(AppCollections.folders(settings: settings).isEmpty, "hide: a folder with every item hidden is not listed")
        HiddenStore().show(AppListEntry.collectionItem(inside).hiddenEntry)
        check(AppCollections.folders(settings: settings).first?.items.map(\.id) == [inside.id], "show: one item brings its folder back")
        let appName = SnapshotFixture.name(for: calculator)
        check(Win10StartMenuView.loadApplications().contains { $0.name == appName }, "hide: fixture lists the app first")
        perform("Hide", in: hider.menu(entry: .app(calculator), settings: settings))
        check(!Win10StartMenuView.loadApplications().contains { $0.name == appName }, "hide: an app leaves the catalog")
        check(!win10.debugListedAppNames().contains(appName), "hide: an app leaves open lists")
        check(!XPProgram.contents(of: URL(fileURLWithPath: "/Applications")).contains { $0.name == appName }, "hide: an app leaves the XP flyout")
        perform("Hide", in: hider.menu(entry: .directory(utilities), settings: settings))
        check(!XPProgram.contents(of: URL(fileURLWithPath: "/Applications")).contains { $0.name == "Utilities" }, "hide: a directory leaves the XP flyout")
        HiddenStore().showAll()
        check(HiddenStore().entries.isEmpty && Win10StartMenuView.loadApplications().contains { $0.name == appName }, "show all: everything returns")

        // Winstripe never lists itself, under any file name; other apps are unaffected.
        let bundles = FileManager.default.temporaryDirectory.appendingPathComponent("Winstripe-SelfFilter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundles) }
        func fakeApp(_ name: String, bundleID: String) -> URL {
            let app = bundles.appendingPathComponent("\(name).app")
            let contents = app.appendingPathComponent("Contents")
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"]
            (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            return app
        }
        check(HiddenStore().snapshot().isHidden(app: fakeApp("Renamed", bundleID: Prefs.realDomain)), "self: Winstripe stays out of the lists")
        check(!HiddenStore().snapshot().isHidden(app: fakeApp("Other", bundleID: "com.example.other")), "self: other apps stay listed")

        // Pins: web items and folders survive storage, and only match themselves.
        let webPin = PinnedApp(collectionItem: root), folderPin = PinnedApp(collectionFolder: merged)
        let stored = [webPin, folderPin].compactMap { PinnedApp(dictionary: $0.dictionary) }
        check(stored == [webPin, folderPin], "pin: collection pins round-trip (got \(stored))")
        check(webPin.url.scheme == "https" && folderPin.url.scheme == CollectionFolder.urlScheme, "pin: url of a collection pin")
        check(PinnedApp(dictionary: PinnedApp(bundleID: "com.example", path: "/Applications/E.app").dictionary)?.bundleID == "com.example", "pin: app pins still round-trip")
        check(PinnedApp(dictionary: ["path": "http://x.example", "collectionID": "i", "collectionKind": "item"]) == nil, "pin: a stored non-https item is rejected")
        check(PinnedApp(dictionary: ["path": "file:///etc/passwd", "collectionID": "i", "collectionKind": "item"]) == nil, "pin: a stored file item is rejected")
        check(PinnedApp(dictionary: ["path": "https://x.example", "collectionID": "i", "collectionKind": "folder"]) == nil, "pin: a stored folder needs a folder URL")
        check(!webPin.matches(folderPin) && webPin.matches(PinnedApp(collectionItem: root)) && !webPin.matches(PinnedApp(url: calculator)), "pin: matches only itself")
        check(AppCollections.display(of: webPin, settings: settings).name == "Root Item", "pin: shows the live name")
        check(AppCollections.display(of: folderPin, settings: settings).name == "Merged", "pin: shows the live folder name")
        let gone = PinnedApp(dictionary: ["path": "https://gone.example", "collectionID": "gone", "collectionName": "Saved name", "collectionKind": "item"])
        check(gone.map { AppCollections.display(of: $0, settings: settings).name } == "Saved name", "pin: falls back to the saved name")

        if failures.isEmpty {
            print("PASS collection folders selftest")
            return 0
        }
        for failure in failures { fputs("FAIL collection folders selftest: \(failure)\n", stderr) }
        return 1
    }
}

/// `--collection-pins-selftest`: default taskbar pins go to new installs only, and only once.
/// Runs on the isolated preferences of a self-test, with fixture entries.
@MainActor
enum CollectionPinsSelfTest {
    static func run() -> Int {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            if !ok { failures.append(label) }
        }
        let rootID = UUID().uuidString, nestedID = UUID().uuidString
        typealias F = FixtureCollectionsProvider
        AppCollections.useFixtures()
        let fixtureRoot = [F.item("Plain"), F.item("Root", id: rootID, pinned: true)]
        let fixtureFolders = [F.folder("Pinned folder", id: "pinned-folder", pinned: true, items: [F.item("Inner", folderID: "pinned-folder")]),
                              F.folder("Plain folder", id: "plain-folder", items: [F.item("Nested", id: nestedID, folderID: "plain-folder", pinned: true)])]
        F.shared.content = { _ in (rootItems: fixtureRoot, folders: fixtureFolders) }
        let store = PinStore()
        func reset() {
            Prefs.defaults.removeObject(forKey: "pinnedApps")
            Prefs.defaults.removeObject(forKey: "collectionDefaultPinsHandled")
        }
        func pinnedIDs() -> [String] { store.apps.compactMap { $0.collection?.id } }
        let expected = [rootID, "pinned-folder", nestedID]

        reset()
        AppCollections.addDefaultPins(isNewInstall: true)
        check(pinnedIDs() == expected, "new install: gets only the flagged items and folders, in order (got \(pinnedIDs()))")
        check(store.apps.first?.collection?.isFolder == false && store.apps[1].collection?.isFolder == true, "new install: items pin as items, folders as folders")
        AppCollections.addDefaultPins(isNewInstall: true)
        check(pinnedIDs() == expected, "later launch: adds nothing twice")
        if let first = store.apps.first { store.toggle(first) }
        AppCollections.addDefaultPins(isNewInstall: true)
        check(pinnedIDs() == Array(expected.dropFirst()), "later launch: a removed pin does not come back")

        reset()
        AppCollections.addDefaultPins(isNewInstall: false)
        check(store.apps.isEmpty, "existing user: gets no pins")
        AppCollections.addDefaultPins(isNewInstall: true)
        check(store.apps.isEmpty, "existing user: is never asked again")

        reset()
        let app = PinnedApp(bundleID: "com.example.Existing", path: "/Applications/Existing.app")
        store.insert(app, at: 0)
        if let root = AppCollections.defaultPins(settings: SettingsStore.shared.current).first { store.insert(root, at: 1) }
        AppCollections.addDefaultPins(isNewInstall: true)
        check(store.apps.first == app && pinnedIDs() == expected, "new install: keeps existing pins and adds no duplicates (got \(pinnedIDs()))")

        // Reset to defaults brings the default pins back, through the same call as the button.
        let model = PropertiesModel()
        store.apps.filter { $0.collection != nil }.forEach { store.toggle($0) }
        check(pinnedIDs().isEmpty, "reset: starts with the default pins removed")
        model.resetToDefaults()
        check(pinnedIDs() == expected, "reset: removed default pins come back (got \(pinnedIDs()))")
        check(store.apps.first == app, "reset: the user's own pins stay")
        model.resetToDefaults()
        check(pinnedIDs() == expected, "reset: a second reset adds no duplicates")
        AppCollections.addDefaultPins(isNewInstall: true)
        check(pinnedIDs() == expected, "reset: later launches change nothing")

        reset()
        AppCollections.addDefaultPins(isNewInstall: false)
        model.resetToDefaults()
        check(pinnedIDs() == expected, "reset: an existing user gets the default pins too")

        reset()
        if let hiddenPin = AppCollections.rootItems(settings: SettingsStore.shared.current).first(where: \.pinnedByDefault) {
            HiddenStore().hide(AppListEntry.collectionItem(hiddenPin).hiddenEntry)
        }
        model.resetToDefaults()
        check(pinnedIDs() == expected, "reset: a hidden default entry is still pinned (got \(pinnedIDs()))")
        HiddenStore().showAll()

        reset()
        if failures.isEmpty {
            print("PASS collection pins selftest")
            return 0
        }
        for failure in failures { fputs("FAIL collection pins selftest: \(failure)\n", stderr) }
        return 1
    }
}
