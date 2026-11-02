import AppKit

/// Native acrylic on screen, with a solid appearance-aware fallback for bitmap renders.
@MainActor
final class AcrylicView: NSVisualEffectView {
    static let snapshotSurface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(hex: 0x202020) : NSColor(hex: 0xF3F3F3)
    }
    var snapshotFill = AcrylicView.snapshotSurface
    var separatorColor = NSColor.separatorColor
    var separatorWidth: CGFloat = 0.5
    var radius: CGFloat = 0
    var separatorEdge: TaskbarEdge?
    var rendersOffscreen = ProcessInfo.processInfo.arguments.contains("--snapshot-dir") {
        didSet {
            surface.drawsSurface = rendersOffscreen
            surface.needsDisplay = true
        }
    }
    private let surface = AcrylicSurfaceView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        autoresizingMask = [.width, .height]
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        surface.drawsSurface = rendersOffscreen
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.snapshotFill = snapshotFill
        surface.separatorColor = separatorColor
        surface.separatorWidth = separatorWidth
        surface.radius = radius
        surface.separatorEdge = separatorEdge
    }

}

@MainActor
private final class AcrylicSurfaceView: NSView {
    var snapshotFill = AcrylicView.snapshotSurface
    var separatorColor = NSColor.separatorColor
    var separatorWidth: CGFloat = 0.5
    var radius: CGFloat = 0
    var separatorEdge: TaskbarEdge?
    var drawsSurface = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if drawsSurface {
            snapshotFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        separatorColor.setFill()
        switch separatorEdge {
        case .bottom: NSRect(x: 0, y: 0, width: bounds.width, height: separatorWidth).fill()
        case .top: NSRect(x: 0, y: bounds.height - separatorWidth, width: bounds.width, height: separatorWidth).fill()
        case .left: NSRect(x: bounds.width - separatorWidth, y: 0, width: separatorWidth, height: bounds.height).fill()
        case .right: NSRect(x: 0, y: 0, width: separatorWidth, height: bounds.height).fill()
        case nil: break
        }
    }
}

@MainActor
final class Win11StartPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Win11StartMenuView: NSView, NSSearchFieldDelegate {
    struct Application {
        let url: URL
        let name: String
        let icon: NSImage
        var detail: String? = nil
        /// Set for a row that comes from a collection.
        var collectionItem: CollectionItem? = nil

        var listEntry: AppListEntry { collectionItem.map(AppListEntry.collectionItem) ?? .app(url) }
    }

    private let settings: TaskbarSettings
    private var applications: [Application]
    private var webFolders: [CollectionFolder]
    private var webItems: [CollectionItem]
    private var expandedFolders = Set<String>()
    private let search = NSSearchField()
    private let heading = NSTextField(labelWithString: "")
    private let modeButton = NSButton()
    private let scroll = Win11ScrollView()
    private let document = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var allApps = false
    private let power = NSButton()
    var onLaunch: ((AppListEntry) -> Void)?
    var onCommand: ((StartItem) -> Void)?

    init(settings: TaskbarSettings, allApps: Bool = false, searchText: String = "") {
        self.settings = settings
        applications = Self.loadApplications()
        webFolders = AppCollections.folders(settings: settings)
        webItems = AppCollections.rootItems(settings: settings)
        self.allApps = allApps
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: PinStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: HiddenStore.didChange, object: nil)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        let backdrop = AcrylicView(frame: bounds)
        backdrop.radius = 12
        addSubview(backdrop)

        search.frame = NSRect(x: 28, y: 28, width: 504, height: 34)
        search.placeholderString = L.t("Search apps", settings.resolvedLanguage)
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.stringValue = searchText
        addSubview(search)

        heading.frame = NSRect(x: 36, y: 88, width: 300, height: 22)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(heading)
        modeButton.frame = NSRect(x: 430, y: 84, width: 100, height: 28)
        modeButton.bezelStyle = .rounded
        modeButton.font = .systemFont(ofSize: 12)
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        addSubview(modeButton)

        scroll.frame = NSRect(x: 24, y: 126, width: 512, height: 316)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.onScroll = { [weak self] in self?.refreshTileHover() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.stringValue = L.t("No apps found", settings.resolvedLanguage)

        let footer = FlippedView(frame: NSRect(x: 0, y: 458, width: 560, height: 62))
        footer.isFooter = true
        addSubview(footer)
        let userIcon = NSImageView(frame: NSRect(x: 36, y: 18, width: 26, height: 26))
        userIcon.image = NSImage(systemSymbolName: "person.circle.fill", accessibilityDescription: nil)
        footer.addSubview(userIcon)
        let user = NSTextField(labelWithString: SnapshotFixture.userName)
        user.font = .systemFont(ofSize: 13)
        user.lineBreakMode = .byTruncatingTail
        user.frame = NSRect(x: 74, y: 22, width: 360, height: 20)
        footer.addSubview(user)
        power.frame = NSRect(x: 480, y: 14, width: 40, height: 34)
        power.bezelStyle = .regularSquare
        power.isBordered = false
        power.image = NSImage(systemSymbolName: "power", accessibilityDescription: L.t("Shut Down…", settings.resolvedLanguage))
        power.toolTip = L.t("Shut Down…", settings.resolvedLanguage)
        power.target = self
        power.action = #selector(showPowerMenu)
        footer.addSubview(power)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    func focusSearch() { window?.makeFirstResponder(search) }

    private var listRows: [Win11AppTile] {
        document.subviews.compactMap { $0 as? Win11AppTile }.sorted { $0.frame.minY < $1.frame.minY }
    }

    func debugListRowNames() -> [String] { listRows.compactMap { $0.accessibilityLabel() } }

    func debugPressListRow(named name: String) {
        _ = listRows.first { $0.accessibilityLabel() == name }?.accessibilityPerformPress()
    }

    func expandCollectionFoldersForTesting() {
        expandedFolders = Set(webFolders.map(\.id))
        rebuild()
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }
    @objc private func pinsChanged() { rebuild() }
    @objc private func hiddenEntriesChanged() {
        applications = Self.loadApplications()
        webFolders = AppCollections.folders(settings: settings)
        webItems = AppCollections.rootItems(settings: settings)
        rebuild(keepingScroll: true)
    }

    @objc private func scrollBoundsChanged() { refreshTileHover() }

    /// Tracking areas do not always emit mouseExited when their views move under a
    /// stationary pointer during scrolling. Reconcile the hover state from the
    /// pointer position so only the tile currently under the pointer is highlighted.
    private func refreshTileHover() {
        guard let window else {
            document.subviews.compactMap { $0 as? Win11AppTile }.forEach { $0.setHovered(false) }
            return
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let clipPoint = scroll.contentView.convert(windowPoint, from: nil)
        let documentPoint = document.convert(windowPoint, from: nil)
        let inside = scroll.contentView.bounds.contains(clipPoint)
        document.subviews.compactMap { $0 as? Win11AppTile }.forEach { tile in
            tile.setHovered(inside && tile.frame.contains(documentPoint))
        }
    }

    @objc private func toggleMode() {
        allApps.toggle()
        rebuild()
    }

    @objc private func showPowerMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in [StartItem.run, .settings, .shutDown] {
            let title = command == .settings ? "Winstripe Settings…" : command.titleKey
            let item = NSMenuItem(title: L.t(title, settings.resolvedLanguage), action: #selector(commandSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: power.bounds.maxY), in: power)
    }

    @objc private func commandSelected(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StartItem else { return }
        onCommand?(item)
    }

    private static func application(_ item: CollectionItem) -> Application {
        Application(url: item.url, name: item.name, icon: item.icon, detail: item.detail, collectionItem: item)
    }

    /// A row of the All apps list: an app, or a collection folder that expands in place.
    private enum ListRow {
        case app(Application)
        case folder(CollectionFolder)

        var name: String {
            switch self {
            case .app(let app): return app.name
            case .folder(let folder): return folder.name
            }
        }
    }

    private func rebuild(keepingScroll: Bool = false) {
        let scrollOrigin = scroll.contentView.bounds.origin
        document.subviews.forEach { $0.removeFromSuperview() }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pins = PinStore().startApps
        let source = allApps || !query.isEmpty || pins.isEmpty ? applications : pins.map { pin in
            applications.first { PinnedApp(url: $0.url).matches(pin) } ??
                Application(url: pin.url, name: pin.url.deletingPathExtension().lastPathComponent, icon: Self.icon(for: pin.url))
        }
        let filtered: [Application]
        if !query.isEmpty {
            filtered = (source + (webItems + webFolders.flatMap(\.items)).map(Self.application))
                .filter { $0.name.localizedStandardContains(query) }
        } else if allApps && !webItems.isEmpty {
            // First-level collection items sort in with the apps.
            filtered = (source + webItems.map(Self.application))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else {
            filtered = source
        }
        let listFolders = allApps && query.isEmpty ? webFolders : []
        heading.stringValue = L.t(allApps ? "All apps" : "Pinned", settings.resolvedLanguage)
        modeButton.title = L.t(allApps ? "Back" : "All apps", settings.resolvedLanguage)
        let width: CGFloat = 496
        let height: CGFloat = allApps ? 44 : 90
        let columns = allApps ? 1 : 6
        let rows = (filtered.count + columns - 1) / columns
        func addTile(_ app: Application, frame: NSRect, indent: CGFloat = 0) {
            let button = Win11AppTile(application: app, list: allApps)
            button.frame = frame
            button.indent = indent
            button.onClick = { [weak self] in self?.onLaunch?(app.listEntry) }
            button.onMenu = { [weak self] in
                guard let self else { return nil }
                return AppPinMenu.shared.menu(entry: app.listEntry, settings: self.settings, includeHide: self.allApps || !query.isEmpty)
            }
            document.addSubview(button)
        }
        var contentHeight = CGFloat(rows) * height
        if listFolders.isEmpty {
            for (index, app) in filtered.enumerated() {
                let tileWidth = width / CGFloat(columns)
                addTile(app, frame: NSRect(x: CGFloat(index % columns) * tileWidth,
                                           y: CGFloat(index / columns) * height, width: tileWidth, height: height))
            }
        } else {
            let ordered = (filtered.map(ListRow.app) + listFolders.map(ListRow.folder))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var y: CGFloat = 0
            for row in ordered {
                let frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height
                switch row {
                case .app(let app):
                    addTile(app, frame: frame)
                case .folder(let folder):
                    let expanded = expandedFolders.contains(folder.id)
                    let button = Win11AppTile(application: Application(url: folder.folderURL, name: folder.name, icon: folder.icon), list: true)
                    button.frame = frame
                    button.expanded = expanded
                    button.onClick = { [weak self] in
                        guard let self else { return }
                        if expanded { self.expandedFolders.remove(folder.id) } else { self.expandedFolders.insert(folder.id) }
                        self.rebuild(keepingScroll: true)
                    }
                    button.onMenu = { [weak self] in
                        self.map { AppPinMenu.shared.menu(entry: .collectionFolder(folder), settings: $0.settings) }
                    }
                    document.addSubview(button)
                    guard expanded else { continue }
                    for item in folder.items {
                        addTile(Self.application(item), frame: NSRect(x: 0, y: y, width: width, height: height), indent: 24)
                        y += height
                    }
                }
            }
            contentHeight = y
        }
        let documentHeight = max(316, contentHeight)
        document.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        if filtered.isEmpty && listFolders.isEmpty {
            emptyLabel.frame = NSRect(x: 0, y: 80, width: width, height: 24)
            document.addSubview(emptyLabel)
        }
        let maxOffset = max(0, documentHeight - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: keepingScroll ? NSPoint(x: 0, y: min(scrollOrigin.y, maxOffset)) : .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if keepingScroll { refreshTileHover() }
    }

    private static func loadApplications() -> [Application] {
        if SnapshotFixture.isActive, let catalog = ApplicationCatalog.override {
            let hidden = HiddenStore().snapshot()
            return catalog.map { Application(url: $0.url, name: $0.name, icon: $0.icon) }.filter { !hidden.isHidden(app: $0.url) }
        }
        let hidden = HiddenStore().snapshot()
        var urls: [URL] = []
        let fm = FileManager.default
        // Include system and user apps alongside /Applications; never descend into app bundles.
        for path in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let root = URL(fileURLWithPath: path)
            // Enumerators may skip symbolic-link apps such as Safari on recent macOS releases.
            urls += (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles]))?.filter { $0.pathExtension.lowercased() == "app" } ?? []
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                urls.append(url)
            }
        }
        return Array(Set(urls)).filter { !hidden.isHidden(app: $0) }.map {
            let name = fm.displayName(atPath: $0.path)
            return Application(url: $0, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                               icon: Self.icon(for: $0))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func icon(for url: URL) -> NSImage {
        // Read bundle icons directly so offscreen rendering also works without Launch Services.
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleIconFile", "CFBundleIconName"] {
                guard let name = bundle.object(forInfoDictionaryKey: key) as? String else { continue }
                let filename = (name as NSString).deletingPathExtension
                if let file = bundle.url(forResource: filename, withExtension: "icns"),
                   let image = NSImage(contentsOf: file) { return image }
            }
            if let file = bundle.urls(forResourcesWithExtension: "icns", subdirectory: nil)?.first,
               let image = NSImage(contentsOf: file) { return image }
        }
        if ProcessInfo.processInfo.arguments.contains("--snapshot-dir"),
           let image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

@MainActor
private final class Win11ScrollView: NSScrollView {
    var onScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?()
        super.scrollWheel(with: event)
        // NSScrollView updates its clip view after handling the event. Reconcile
        // once more on the next run-loop turn for precise/trackpad scrolling.
        DispatchQueue.main.async { [weak self] in self?.onScroll?() }
    }
}

@MainActor
private final class FlippedView: NSView {
    var isFooter = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if isFooter {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            bounds.fill()
        }
    }
}

@MainActor
private final class Win11AppTile: NSControl {
    private let application: Win11StartMenuView.Application
    private let list: Bool
    private var hovered = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    /// List rows only: moves a row inside an expanded folder to the right.
    var indent: CGFloat = 0
    /// List rows only: set on a folder row, whose chevron shows this state.
    var expanded: Bool?

    init(application: Win11StartMenuView.Application, list: Bool) {
        self.application = application
        self.list = list
        super.init(frame: .zero)
        toolTip = application.detail.map { "\(application.name)\n\($0)" } ?? application.name
        setAccessibilityLabel(application.name)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    func setHovered(_ value: Bool) {
        if hovered != value { hovered = value }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onClick?() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
        }
        let icon = list ? NSRect(x: 12 + indent, y: 8, width: 28, height: 28)
            : NSRect(x: bounds.midX - 16, y: 10, width: 32, height: 32)
        Retro.drawImage(application.icon, in: icon)
        let text = list ? NSRect(x: 52 + indent, y: 0, width: bounds.width - 64 - indent - (expanded == nil ? 0 : 28), height: bounds.height)
            : NSRect(x: 4, y: 47, width: bounds.width - 8, height: 32)
        Retro.drawText(application.name, in: text, font: .systemFont(ofSize: 11), color: .labelColor,
                       smoothing: true, alignment: list ? .left : .center)
        if let expanded, let chevron = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .symbolTinted([.labelColor]) {
            Retro.drawImage(chevron, in: NSRect(x: bounds.maxX - 30, y: bounds.midY - 6, width: 12, height: 12))
        }
    }
}
