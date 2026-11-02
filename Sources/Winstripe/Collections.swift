import AppKit

/// App Collections: web apps and Mac apps, on the first level or in folders, that every Start menu lists.
/// This repository has no source of entries: `DisabledCollectionsProvider` shows nothing, so the Start menus
/// behave as if collections did not exist. See docs/web-app-collections.md.

/// A resolved, displayable item.
struct CollectionItem {
    /// The `id` of the folder holding the item; nil for an item on the first level.
    let folderID: String?
    /// The item's UUID, in canonical (uppercase) form.
    let id: String
    let name: String
    let detail: String?
    /// What the item stands for: the installed Mac app's file URL when `bundleId` resolves, else `webURL`.
    /// A file URL makes the app treat the item as that app, as when pinning it. Opening goes through
    /// the provider.
    let url: URL
    let icon: NSImage
    /// Set for Mac-app items.
    let bundleId: String?
    /// The item's https URL: the web app itself, or the fallback for a Mac app.
    let webURL: URL
    /// The provider asks for this item to be on the taskbar of a new install.
    let pinnedByDefault: Bool

    /// True when `url` launches an installed Mac app rather than opening a web page.
    var opensApplication: Bool { url.isFileURL }

    init(folderID: String?, id: String, name: String, detail: String?, url: URL, icon: NSImage,
                bundleId: String? = nil, webURL: URL, pinnedByDefault: Bool = false) {
        self.folderID = folderID
        self.id = id
        self.name = name
        self.detail = detail
        self.url = url
        self.icon = icon
        self.bundleId = bundleId
        self.webURL = webURL
        self.pinnedByDefault = pinnedByDefault
    }
}

/// A resolved folder in the Start menus.
struct CollectionFolder {
    static let urlScheme = "winstripe-collection"

    let id: String
    /// Every folder id shown as this folder: `id`, then those of any folders a provider merged into it.
    let sourceIDs: [String]
    let name: String
    let icon: NSImage
    let items: [CollectionItem]
    /// The provider asks for this folder to be on the taskbar of a new install.
    let pinnedByDefault: Bool

    init(id: String, sourceIDs: [String]? = nil, name: String, icon: NSImage, items: [CollectionItem], pinnedByDefault: Bool = false) {
        self.id = id
        self.sourceIDs = sourceIDs ?? [id]
        self.name = name
        self.icon = icon
        self.items = items
        self.pinnedByDefault = pinnedByDefault
    }

    /// Unreserved URL characters; everything else in an id is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Stands in for a directory URL in menus that navigate folders by URL (XP's All Programs).
    var folderURL: URL { Self.folderURL(id: id) }

    static func folderURL(id: String) -> URL {
        // Percent-encoding every byte outside the unreserved set always yields a valid opaque URL.
        let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "\(urlScheme):\(encoded)")!
    }

    static func id(fromFolderURL url: URL) -> String? {
        guard url.scheme == urlScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    }
}

@MainActor
protocol CollectionsProviding: AnyObject {
    /// False for the disabled provider.
    var isAvailable: Bool { get }
    /// Live app only: load what the provider needs. `log` receives diagnostics.
    func start(log: @escaping @MainActor (String) -> Void)
    /// The folders a Start menu shows, with text resolved for `localeIdentifier` (`en`, `zh-Hans`, …).
    func folders(localeIdentifier: String) -> [CollectionFolder]
    /// The first-level items a Start menu lists with its apps, resolved the same way.
    func rootItems(localeIdentifier: String) -> [CollectionItem]
    /// The user chose `item` in a Start menu, on the taskbar or in search.
    func open(_ item: CollectionItem)
}

extension CollectionsProviding {
    /// Every item, for search.
    func items(localeIdentifier: String) -> [CollectionItem] {
        rootItems(localeIdentifier: localeIdentifier) + folders(localeIdentifier: localeIdentifier).flatMap(\.items)
    }
}

enum CollectionsValidation {
    /// Only absolute `https` URLs with a host are accepted.
    static func httpsURL(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    /// An item `id` in canonical form, or nil when it is not a UUID.
    static func itemID(_ string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return UUID(uuidString: string)?.uuidString
    }
}

/// The provider of a build without collections: no folders, nothing read.
@MainActor
final class DisabledCollectionsProvider: CollectionsProviding {
    init() {}
    var isAvailable: Bool { false }
    func start(log: @escaping @MainActor (String) -> Void) {}
    func folders(localeIdentifier: String) -> [CollectionFolder] { [] }
    func rootItems(localeIdentifier: String) -> [CollectionItem] { [] }
    func open(_ item: CollectionItem) {}
}

@MainActor
enum Collections {
    /// Posted on the main thread when folders, items or their icons change.
    static let didChange = Notification.Name("WinstripeCollectionsDidChange")

    /// The provider the app uses; `DisabledCollectionsProvider` until one is installed.
    private(set) static var provider: any CollectionsProviding = DisabledCollectionsProvider()

    /// Install at launch, before anything reads `provider`. Offscreen fixtures install their own.
    static func install(_ provider: any CollectionsProviding) {
        self.provider = provider
    }
}
