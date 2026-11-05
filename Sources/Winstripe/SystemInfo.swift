import AppKit
import Carbon
import ApplicationServices

@MainActor
enum Clock {
    static let english: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()
    static let chinese: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "H:mm"
        return f
    }()
    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    static func time(_ lang: Language) -> String {
        if SnapshotFixture.isActive { return SnapshotFixture.time(lang) }
        return (lang.resolvedLanguage == .english ? english : chinese).string(from: Date())
    }

    static func date(_ language: Language = .english) -> String {
        if SnapshotFixture.isActive { return SnapshotFixture.longDate(language) }
        return longDate.string(from: Date())
    }
    static func shortDate() -> String {
        if SnapshotFixture.isActive { return "10/9/2026" }
        return DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    }
}

@MainActor
enum InputSource {
    /// Two-letter abbreviation of the current keyboard input source's primary language (e.g. "EN", "ZH").
    static func abbreviation() -> String {
        if SnapshotFixture.isActive { return "EN" }
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "EN" }
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
            let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
            if let first = langs.firstObject as? String, !first.isEmpty {
                return String(first.prefix(2)).uppercased()
            }
        }
        return "EN"
    }
}

@MainActor
enum QuickLaunch {
    static func items(at path: String) -> [URL] {
        if SnapshotFixture.isActive { return [] }
        guard !path.isEmpty,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return Array(sorted.prefix(16))
    }
}

enum WindowInfo {
    /// On-screen, normal-layer window counts per process (no Screen Recording permission needed).
    static func counts() -> [pid_t: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [pid_t: Int] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int else { continue }
            result[pid_t(pid), default: 0] += 1
        }
        return result
    }
}

/// Winstripe sits on top of a Dock at the bottom of the screen, so launching makes that Dock hide itself.
enum DockAutoHide {
    /// The Dock leaves `orientation` unset until it is moved, so no value means the bottom.
    static func needsAutoHide(orientation: String?, autoHide: Bool) -> Bool {
        !autoHide && (orientation ?? "bottom") == "bottom"
    }

    /// Runs only in the live app: verification modes must leave the user's Dock alone.
    static func applyAtLaunch() {
        guard !Prefs.isIsolated else { return }
        let domain = "com.apple.dock" as CFString
        let key = "autohide" as CFString
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let autoHide = CFPreferencesGetAppBooleanValue(key, domain, nil)
        guard needsAutoHide(orientation: orientation, autoHide: autoHide) else { return }
        CFPreferencesSetValue(key, kCFBooleanTrue, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return }
        // The Dock reads the setting when it starts, and launchd restarts it.
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"])
    }

    /// `--dock-autohide-selftest`: only the decision, so it never changes the real Dock.
    static func runSelfTest() -> Int {
        let checks: [(String, Bool)] = [
            ("unset-orientation", needsAutoHide(orientation: nil, autoHide: false)),
            ("bottom", needsAutoHide(orientation: "bottom", autoHide: false)),
            ("already-hidden", !needsAutoHide(orientation: "bottom", autoHide: true)),
            ("left", !needsAutoHide(orientation: "left", autoHide: false)),
            ("right", !needsAutoHide(orientation: "right", autoHide: false))
        ]
        let failed = checks.filter { !$0.1 }
        if failed.isEmpty {
            print("PASS dock-autohide-selftest")
            return 0
        }
        print("FAIL dock-autohide-selftest: \(failed.map(\.0).joined(separator: ", "))")
        return 1
    }
}

enum DockBadges {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Reads badge labels (e.g. unread counts) from the Dock's accessibility tree.
    /// Returns [app name: badge]. Empty unless Winstripe has Accessibility permission.
    static func fetch() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let axDock = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        for list in children(of: axDock) {
            for item in children(of: list) {
                guard let title = attribute(item, "AXTitle") as? String,
                      let badge = attribute(item, "AXStatusLabel") as? String,
                      !badge.isEmpty else { continue }
                result[title] = badge
            }
        }
        return result
    }

    @MainActor static func badge(for app: TrayAppInfo, in badges: [String: String]) -> String? {
        let candidates = [
            app.name,
            Bundle(url: URL(fileURLWithPath: app.path))?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            Bundle(url: URL(fileURLWithPath: app.path))?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            app.bundleID.flatMap { bundleID in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            }
        ].compactMap { $0 }.filter { !$0.isEmpty }
        for candidate in candidates {
            if let value = badges[candidate] { return value }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
    }
}

/// A row of the Programs menu; the entry is what a right-click on it acts on.
final class ProgramsMenuItem: NSMenuItem {
    var entry: AppListEntry?
}

@MainActor
enum ProgramsMenu {
    static func build(target: AnyObject, action: Selector, lang: Language, webFolders: [CollectionFolder] = [],
                      webItems: [CollectionItem] = []) -> NSMenu {
        let menu = NSMenu()
        populate(menu, target: target, action: action, lang: lang, webFolders: webFolders, webItems: webItems)
        return menu
    }

    /// Fills the menu from the app catalog, without touching the disk. Until the first scan ends it
    /// lists the collections and a "Loading…" row.
    static func populate(_ menu: NSMenu, target: AnyObject, action: Selector, lang: Language, webFolders: [CollectionFolder] = [],
                         webItems: [CollectionItem] = []) {
        menu.removeAllItems()
        menu.delegate = ProgramsPinMenuDelegate.shared
        menu.autoenablesItems = false
        let catalog = AppCatalog.shared
        let hidden = HiddenStore().snapshot()

        let accessories = NSMenu()
        accessories.delegate = ProgramsPinMenuDelegate.shared
        accessories.autoenablesItems = false
        let accessoriesURL = catalog.roots.system
        add(directory: accessoriesURL, to: accessories, target: target, action: action, depth: 0, hidden: hidden)
        if !accessories.items.isEmpty, !hidden.isHidden(directory: accessoriesURL) {
            let item = ProgramsMenuItem(title: L.t("Accessories", lang), action: nil, keyEquivalent: "")
            item.entry = .directory(accessoriesURL)
            item.submenu = accessories
            item.image = folderIcon()
            menu.addItem(item)
        }
        for folder in webFolders {
            menu.addItem(webFolderItem(folder, target: target, action: action))
        }
        // First-level collection items sort in with the apps.
        add(directory: catalog.roots.applications, to: menu, target: target, action: action, depth: 0, hidden: hidden,
            extraApps: webItems.map { webItem($0, target: target, action: action) })
        add(directory: catalog.roots.user, to: menu, target: target, action: action, depth: 1, hidden: hidden)
        if !catalog.isReady || menu.items.isEmpty {
            let empty = NSMenuItem(title: L.t(catalog.isReady ? "(Empty)" : "Loading…", lang), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    /// A collection item; it carries its URL like app items carry file URLs.
    static func webItem(_ app: CollectionItem, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = ProgramsMenuItem(title: app.name, action: action, keyEquivalent: "")
        item.entry = .collectionItem(app)
        item.target = target
        item.representedObject = app.url
        item.toolTip = app.detail
        item.image = sized(app.icon)
        return item
    }

    /// A collection folder as a submenu.
    static func webFolderItem(_ folder: CollectionFolder, target: AnyObject, action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.delegate = ProgramsPinMenuDelegate.shared
        submenu.autoenablesItems = false
        for app in folder.items {
            submenu.addItem(webItem(app, target: target, action: action))
        }
        let item = ProgramsMenuItem(title: folder.name, action: nil, keyEquivalent: "")
        item.entry = .collectionFolder(folder)
        item.submenu = submenu
        item.image = sized(folder.icon)
        return item
    }

    private static func sized(_ image: NSImage) -> NSImage? {
        let copy = image.copy() as? NSImage
        copy?.size = NSSize(width: 16, height: 16)
        copy?.cacheMode = image.cacheMode
        return copy
    }

    private static func folderIcon() -> NSImage? {
        let img = NSImage(named: NSImage.folderName)?.copy() as? NSImage
        img?.size = NSSize(width: 16, height: 16)
        return img
    }

    private static func add(directory: URL, to menu: NSMenu, target: AnyObject, action: Selector, depth: Int,
                            hidden: HiddenSet, extraApps: [NSMenuItem] = []) {
        var folders: [NSMenuItem] = []
        var apps: [NSMenuItem] = []
        for entry in AppCatalog.shared.entries(in: directory) {
            let url = entry.url
            if entry.isApp {
                guard !hidden.isHidden(app: url) else { continue }
                let item = ProgramsMenuItem(title: entry.nameWithoutSuffix, action: action, keyEquivalent: "")
                item.entry = .app(url)
                item.target = target
                item.representedObject = url
                item.image = sized(AppIconCache.shared.icon(for: url))
                apps.append(item)
            } else if depth < 2, entry.isDirectory, !hidden.isHidden(directory: url) {
                let sub = NSMenu()
                sub.delegate = ProgramsPinMenuDelegate.shared
                sub.autoenablesItems = false
                add(directory: url, to: sub, target: target, action: action, depth: depth + 1, hidden: hidden)
                if !sub.items.isEmpty {
                    let item = ProgramsMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
                    item.entry = .directory(url)
                    item.submenu = sub
                    item.image = folderIcon()
                    folders.append(item)
                }
            }
        }
        if !extraApps.isEmpty {
            apps = (apps + extraApps).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        for item in folders + apps { menu.addItem(item) }
    }
}

@MainActor
private final class ClassicProgramsMenuItemView: NSView {
    private weak var item: NSMenuItem?
    private let theme: Theme
    private var highlightedOverride: Bool?

    init(item: NSMenuItem, theme: Theme) {
        self.item = item
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 248, height: 28))
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setHighlighted(_ highlighted: Bool) {
        highlightedOverride = highlighted
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let highlighted = highlightedOverride ?? item.isHighlighted
        (highlighted ? theme.menuHighlight : theme.face).setFill()
        bounds.fill()

        let titleColor = highlighted ? NSColor.white : theme.menuText
        if let image = item.image {
            let imageRect = NSRect(x: 8, y: floor((bounds.height - 18) / 2), width: 18, height: 18)
            Retro.drawImage(image, in: imageRect)
        }
        Retro.drawText(item.title,
                       in: NSRect(x: 34, y: 0, width: bounds.width - 58, height: bounds.height),
                       font: Retro.font(size: 13), color: titleColor, smoothing: true)
        if item.submenu != nil {
            Retro.drawTriangleRight(center: NSPoint(x: bounds.maxX - 12, y: bounds.midY),
                                    size: 4, color: titleColor)
        }
    }
}

@MainActor
final class ClassicSubmenuView: NSView {
    private let items: [NSMenuItem]
    private let theme: Theme
    private let rows: [NSRect]
    private let rowViews: [ClassicProgramsMenuItemView]
    private var hover: Int?

    var onHover: ((NSMenuItem, NSRect) -> Void)?
    var onActivate: ((NSMenuItem) -> Void)?
    var onContext: ((NSMenuItem, NSEvent) -> Void)?

    init(menu: NSMenu, theme: Theme) {
        self.items = menu.items.filter { !$0.isSeparatorItem }
        self.theme = theme
        self.rows = items.enumerated().map { index, _ in
            NSRect(x: 2, y: CGFloat(index) * 28 + 2, width: 244, height: 28)
        }
        self.rowViews = items.map { ClassicProgramsMenuItemView(item: $0, theme: theme) }
        super.init(frame: NSRect(x: 0, y: 0, width: 248, height: CGFloat(items.count) * 28 + 4))
        wantsLayer = false
        for (index, rowView) in rowViews.enumerated() {
            rowView.frame = rows[index]
            rowView.toolTip = items[index].toolTip
            addSubview(rowView)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private func index(at point: NSPoint) -> Int? {
        rows.firstIndex { $0.contains(point) }
    }

    private func updateHover(_ next: Int?) {
        guard next != hover else { return }
        if let hover { rowViews[hover].setHighlighted(false) }
        hover = next
        if let next {
            rowViews[next].setHighlighted(true)
            onHover?(items[next], rows[next])
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        updateHover(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let item = items[index]
        if item.submenu == nil, item.isEnabled { onActivate?(item) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onContext?(items[index], event)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.face.setFill()
        bounds.fill()
        if let config = theme.classicConfig { config.bevel("windowFrame", in: bounds) }
        else { Retro.windowFrame(bounds, theme) }
    }
}

/// Keeps native Programs-menu rows and keyboard navigation while adding app context menus.
@MainActor
private final class ProgramsPinMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ProgramsPinMenuDelegate()
    private var tracking: [NSMenu] = []
    private var monitor: Any?

    func menuWillOpen(_ menu: NSMenu) {
        tracking.append(menu)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let self,
                  let item = self.tracking.reversed().compactMap(\.highlightedItem).first,
                  let entry = (item as? ProgramsMenuItem)?.entry,
                  let view = event.window?.contentView else { return event }
            let context = AppPinMenu.shared.menu(entry: entry, settings: SettingsStore.shared.current)
            NSMenu.popUpContextMenu(context, with: event, for: view)
            return nil
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        tracking.removeAll { $0 === menu }
        if tracking.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
