import AppKit

enum Win8TileSize: String, Codable, CaseIterable {
    case small
    case medium
    case wide
    case large

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .small: return (1, 1)
        case .medium: return (2, 2)
        case .wide: return (4, 2)
        case .large: return (4, 4)
        }
    }

    var menuTag: Int {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .wide: return 3
        case .large: return 4
        }
    }

    init?(menuTag: Int) {
        switch menuTag {
        case 1: self = .small
        case 2: self = .medium
        case 3: self = .wide
        case 4: self = .large
        default: return nil
        }
    }
}

struct Win8LayoutEntry: Codable, Equatable {
    let key: String
    let size: String?

    private enum CodingKeys: String, CodingKey { case key, size }

    init(key: String, size: String?) {
        self.key = key
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        size = try container.decodeIfPresent(String.self, forKey: .size)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(size, forKey: .size)
    }
}

struct PinnedApp: Equatable {
    /// A pinned collection item or folder. The name is a fallback for when the collection is gone.
    struct CollectionPin: Equatable {
        let id: String
        let name: String
        let isFolder: Bool
    }

    let bundleID: String?
    /// A file path; for a collection pin, the URL it holds (its https address or folder URL).
    let path: String
    let collection: CollectionPin?

    init(bundleID: String?, path: String) {
        self.bundleID = bundleID
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        collection = nil
    }

    init(url: URL) { self.init(bundleID: Bundle(url: url)?.bundleIdentifier, path: url.path) }

    private init(collectionURL: String, pin: CollectionPin) {
        bundleID = nil
        path = collectionURL
        collection = pin
    }

    init(collectionItem item: CollectionItem) {
        self.init(collectionURL: item.webURL.absoluteString, pin: CollectionPin(id: item.id, name: item.name, isFolder: false))
    }

    init(collectionFolder folder: CollectionFolder) {
        self.init(collectionURL: folder.folderURL.absoluteString, pin: CollectionPin(id: folder.id, name: folder.name, isFolder: true))
    }

    /// Reads a stored pin. A collection pin must still hold an https address or a folder URL.
    init?(dictionary: [String: String]) {
        guard let path = dictionary["path"] else { return nil }
        guard let id = dictionary["collectionID"] else {
            self.init(bundleID: dictionary["bundleID"], path: path)
            return
        }
        let isFolder = dictionary["collectionKind"] == "folder"
        guard isFolder ? URL(string: path).flatMap(CollectionFolder.id(fromFolderURL:)) != nil
                       : CollectionsValidation.httpsURL(path) != nil else { return nil }
        self.init(collectionURL: path, pin: CollectionPin(id: id, name: dictionary["collectionName"] ?? "", isFolder: isFolder))
    }

    var dictionary: [String: String] {
        var value = ["path": path]
        value["bundleID"] = bundleID
        if let collection {
            value["collectionID"] = collection.id
            value["collectionName"] = collection.name
            value["collectionKind"] = collection.isFolder ? "folder" : "item"
        }
        return value
    }

    var url: URL { collection == nil ? URL(fileURLWithPath: path) : URL(string: path) ?? URL(fileURLWithPath: "/") }
    var identityKey: String { collection?.id ?? bundleID ?? path }
    func matches(_ other: PinnedApp) -> Bool {
        if collection != nil || other.collection != nil {
            return collection?.id == other.collection?.id && collection?.isFolder == other.collection?.isFolder
        }
        return path == other.path || (bundleID != nil && bundleID == other.bundleID)
    }
}

@MainActor
final class Win8LayoutStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = Prefs.defaults) {
        self.defaults = defaults
    }

    var entries: [Win8LayoutEntry] {
        get {
            if SnapshotFixture.isActive { return SnapshotFixture.win8LayoutEntries }
            guard let data = defaults.data(forKey: "win8Layout") else { return [] }
            return (try? JSONDecoder().decode([Win8LayoutEntry].self, from: data)) ?? []
        }
        set {
            if SnapshotFixture.isActive {
                SnapshotFixture.win8LayoutEntries = newValue
                return
            }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "win8Layout")
        }
    }

    func size(for app: PinnedApp) -> Win8TileSize? {
        guard let raw = entries.first(where: { $0.key == app.identityKey })?.size else { return nil }
        return Win8TileSize(rawValue: raw)
    }

    func setSize(_ size: Win8TileSize?, for app: PinnedApp) {
        var updated = entries
        if let index = updated.firstIndex(where: { $0.key == app.identityKey }) {
            updated[index] = Win8LayoutEntry(key: app.identityKey, size: size?.rawValue ?? updated[index].size)
        } else {
            updated.append(Win8LayoutEntry(key: app.identityKey, size: size?.rawValue))
        }
        entries = updated
    }

    func setOrder(_ apps: [PinnedApp]) {
        var updated: [Win8LayoutEntry] = []
        for app in apps {
            let entry = entries.first(where: { $0.key == app.identityKey }) ??
                Win8LayoutEntry(key: app.identityKey, size: nil)
            updated.append(entry)
        }
        let keys = Set(updated.map(\.key))
        entries = updated + entries.filter { !keys.contains($0.key) }
    }

    func remove(_ app: PinnedApp) {
        entries = entries.filter { $0.key != app.identityKey }
    }

    static func encode(_ entries: [Win8LayoutEntry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    static func decode(_ data: Data) -> [Win8LayoutEntry]? {
        try? JSONDecoder().decode([Win8LayoutEntry].self, from: data)
    }
}

@MainActor
final class PinStore {
    static let didChange = Notification.Name("WinstripePinsDidChange")
    private let defaults = Prefs.defaults

    private func read(_ key: String) -> [PinnedApp] {
        if SnapshotFixture.isActive { return [] }
        return (defaults.array(forKey: key) as? [[String: String]] ?? []).compactMap(PinnedApp.init(dictionary:))
    }

    var apps: [PinnedApp] { read("pinnedApps") }
    var startApps: [PinnedApp] { read("startPins") }
    var taskOrder: [String] { SnapshotFixture.isActive ? [] : (defaults.stringArray(forKey: "taskOrder") ?? []) }

    private func write(_ apps: [PinnedApp], key: String) {
        guard !SnapshotFixture.isActive else { return }
        defaults.set(apps.map(\.dictionary), forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func contains(bundleID: String) -> Bool { apps.contains { $0.bundleID == bundleID } }
    func contains(_ app: PinnedApp, start: Bool = false) -> Bool {
        (start ? startApps : apps).contains { $0.matches(app) }
    }

    func toggle(bundleID: String, path: String) {
        toggle(PinnedApp(bundleID: bundleID, path: path))
    }

    func toggle(_ app: PinnedApp, start: Bool = false) {
        var current = start ? startApps : apps
        if let index = current.firstIndex(where: { $0.matches(app) }) {
            current.remove(at: index)
            if start { Win8LayoutStore().remove(app) }
        } else {
            current.append(app)
        }
        write(current, key: start ? "startPins" : "pinnedApps")
    }

    func insert(_ app: PinnedApp, at index: Int) {
        var current = apps
        current.removeAll { $0.matches(app) }
        current.insert(app, at: min(max(0, index), current.count))
        write(current, key: "pinnedApps")
    }

    func setTaskOrder(_ ids: [String]) {
        guard !SnapshotFixture.isActive else { return }
        defaults.set(ids, forKey: "taskOrder")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// An app or folder hidden from the Start menu lists. `key` is the identity the lists filter on; `name`
/// and `path` only let Properties show the entry.
struct HiddenEntry: Codable, Equatable {
    enum Kind: String, Codable { case app, folder, collectionItem, collectionFolder }
    let kind: Kind
    let key: String
    let name: String
    let path: String?

    var isFolder: Bool { kind == .folder || kind == .collectionFolder }
}

/// One read of the hidden entries, for filtering a whole list. Winstripe itself always counts as hidden.
struct HiddenSet {
    private let keys: [HiddenEntry.Kind: Set<String>]

    init(_ entries: [HiddenEntry]) {
        keys = Dictionary(grouping: entries, by: \.kind).mapValues { Set($0.map(\.key)) }
    }

    private func contains(_ kind: HiddenEntry.Kind, _ key: String) -> Bool { keys[kind]?.contains(key) == true }

    func isHidden(app url: URL) -> Bool {
        let app = PinnedApp(url: url)
        return app.bundleID == Prefs.realDomain || contains(.app, app.identityKey)
    }

    func isHidden(directory url: URL) -> Bool { contains(.folder, url.standardizedFileURL.path) }
    func isHidden(collectionItem id: String) -> Bool { contains(.collectionItem, id) }
    func isHidden(collectionFolder folder: CollectionFolder) -> Bool {
        folder.sourceIDs.contains { contains(.collectionFolder, $0) }
    }
}

@MainActor
final class HiddenStore {
    static let didChange = Notification.Name("WinstripeHiddenEntriesDidChange")
    private static let key = "hiddenListEntries"
    /// Offscreen fixtures never read or write the real preferences.
    static var fixtureEntries: [HiddenEntry] = []
    private let defaults = Prefs.defaults

    var entries: [HiddenEntry] {
        if SnapshotFixture.isActive { return Self.fixtureEntries }
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([HiddenEntry].self, from: data)) ?? []
    }

    func snapshot() -> HiddenSet { HiddenSet(entries) }

    private func write(_ entries: [HiddenEntry]) {
        if SnapshotFixture.isActive {
            Self.fixtureEntries = entries
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func hide(_ entry: HiddenEntry) {
        write(entries.filter { $0.kind != entry.kind || $0.key != entry.key } + [entry])
    }

    func show(_ entry: HiddenEntry) {
        write(entries.filter { $0.kind != entry.kind || $0.key != entry.key })
    }

    func showAll() { write([]) }
}

/// What a right-click in a Start menu list acts on.
enum AppListEntry {
    case app(URL)
    case directory(URL)
    case collectionItem(CollectionItem)
    case collectionFolder(CollectionFolder)

    @MainActor
    var hiddenEntry: HiddenEntry {
        switch self {
        case .app(let url):
            let name = SnapshotFixture.isActive ? SnapshotFixture.name(for: url)
                : FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return HiddenEntry(kind: .app, key: PinnedApp(url: url).identityKey, name: name, path: url.path)
        case .directory(let url):
            let path = url.standardizedFileURL.path
            return HiddenEntry(kind: .folder, key: path, name: url.lastPathComponent, path: path)
        case .collectionItem(let item):
            return HiddenEntry(kind: .collectionItem, key: item.id, name: item.name, path: nil)
        case .collectionFolder(let folder):
            return HiddenEntry(kind: .collectionFolder, key: folder.id, name: folder.name, path: nil)
        }
    }
}

/// Shared context-menu actions also work for apps that have no running process.
@MainActor
final class AppPinMenu: NSObject {
    static let shared = AppPinMenu()

    private func taskItem(_ pin: PinnedApp, store: PinStore, settings: TaskbarSettings) -> NSMenuItem {
        let task = NSMenuItem(title: L.t(store.contains(pin) ? "Unpin from taskbar" : "Pin to taskbar", settings.resolvedLanguage),
                              action: #selector(toggleTask(_:)), keyEquivalent: "")
        task.target = self
        task.representedObject = pin
        return task
    }

    private func addFinderItem(_ url: URL, to menu: NSMenu, settings: TaskbarSettings) {
        menu.addItem(.separator())
        let finder = NSMenuItem(title: L.t("Show in Finder", settings.resolvedLanguage), action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = url
        menu.addItem(finder)
    }

    private func taskMenu(_ pin: PinnedApp, settings: TaskbarSettings) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(taskItem(pin, store: PinStore(), settings: settings))
        return menu
    }

    /// The menu of a list row. `includeHide` is false for rows that are not in the app list, such as
    /// pinned tiles, which hiding would not remove.
    func menu(entry: AppListEntry, settings: TaskbarSettings, includeHide: Bool = true) -> NSMenu {
        let menu: NSMenu
        switch entry {
        case .app(let url):
            menu = self.menu(url: url, settings: settings)
        case .directory(let url):
            menu = taskMenu(PinnedApp(bundleID: nil, path: url.path), settings: settings)
            addFinderItem(url, to: menu, settings: settings)
        case .collectionItem(let item):
            // An installed Mac app pins as that app, so its button also tracks the running app.
            menu = item.opensApplication ? self.menu(url: item.url, settings: settings)
                : taskMenu(PinnedApp(collectionItem: item), settings: settings)
        case .collectionFolder(let folder):
            menu = taskMenu(PinnedApp(collectionFolder: folder), settings: settings)
        }
        if includeHide {
            if !menu.items.contains(where: \.isSeparatorItem) { menu.addItem(.separator()) }
            let hide = NSMenuItem(title: L.t("Hide", settings.resolvedLanguage), action: #selector(hide(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = entry.hiddenEntry
            menu.addItem(hide)
        }
        return menu
    }

    /// The menu of a pin on the taskbar.
    func menu(pin: PinnedApp, settings: TaskbarSettings) -> NSMenu {
        pin.collection == nil ? menu(url: pin.url, settings: settings, includeStart: false) : taskMenu(pin, settings: settings)
    }

    func menu(url: URL, settings: TaskbarSettings, includeStart: Bool = true) -> NSMenu {
        let app = PinnedApp(url: url)
        let store = PinStore()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(taskItem(app, store: store, settings: settings))
        if includeStart && settings.startMenuStyle.supportsStartPins {
            let screen = settings.startMenuStyle.isFullScreen
            let key = store.contains(app, start: true)
                ? (screen ? "Unpin from Start screen" : "Unpin from Start menu")
                : (screen ? "Pin to Start screen" : "Pin to Start menu")
            let item = NSMenuItem(title: L.t(key, settings.resolvedLanguage), action: #selector(toggleStart(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            menu.addItem(item)
        }
        addFinderItem(url, to: menu, settings: settings)
        return menu
    }

    @objc private func toggleTask(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? PinnedApp else { return }
        PinStore().toggle(app)
    }
    @objc private func toggleStart(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? PinnedApp else { return }
        PinStore().toggle(app, start: true)
    }
    @objc private func hide(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HiddenEntry else { return }
        HiddenStore().hide(entry)
    }
    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
