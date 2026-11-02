import AppKit

/// XP alone uses visible-frame clamping, preserving the other templates' geometry.
enum XPMenuLayout {
    static func available(bar: NSRect, edge: TaskbarEdge, visible: NSRect) -> NSRect {
        switch edge {
        case .bottom: return NSRect(x: visible.minX, y: max(visible.minY, bar.maxY), width: visible.width,
                                    height: max(0, visible.maxY - max(visible.minY, bar.maxY)))
        case .top: return NSRect(x: visible.minX, y: visible.minY, width: visible.width,
                                 height: max(0, min(visible.maxY, bar.minY) - visible.minY))
        case .left: return NSRect(x: max(visible.minX, bar.maxX), y: visible.minY,
                                  width: max(0, visible.maxX - max(visible.minX, bar.maxX)), height: visible.height)
        case .right: return NSRect(x: visible.minX, y: visible.minY,
                                   width: max(0, min(visible.maxX, bar.minX) - visible.minX), height: visible.height)
        }
    }

    static func preferredSize(available: NSSize) -> NSSize {
        // Remove MFU row slots first, then shrink the remaining chrome/content.
        let removed = min(6, max(0, ceil((480 - available.height) / 36)))
        return NSSize(width: min(380, available.width), height: min(480 - removed * 36, available.height))
    }

    static func frame(menuSize: NSSize, button: NSRect, bar: NSRect, edge: TaskbarEdge, visible: NSRect) -> NSRect {
        let area = available(bar: bar, edge: edge, visible: visible)
        let size = NSSize(width: min(menuSize.width, area.width), height: min(menuSize.height, area.height))
        let x = edge == .left ? area.minX : edge == .right ? area.maxX - size.width
            : min(max(button.minX, area.minX), area.maxX - size.width)
        let y = edge == .bottom ? area.minY : edge == .top ? area.maxY - size.height
            : min(max(button.maxY - size.height, area.minY), area.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

@MainActor
private final class XPMenuRow: NSView {
    var title = ""
    var subtitle = ""
    var icon: NSImage?
    var iconSize: CGFloat = 32
    var bold = false
    var whiteText = false
    var blueText = false
    var arrow = false
    var greenArrow = false
    var centerGreenArrow = false
    var smoothing = true
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    var selected = false { didSet { needsDisplay = true } }
    private var hoverWork: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        selected = true
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onHover?() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
    override func mouseExited(with event: NSEvent) { hoverWork?.cancel(); selected = false }
    func setHovered(_ hovered: Bool) {
        if !hovered { hoverWork?.cancel() }
        selected = hovered
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = onMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected { NSColor(hex: 0x316AC5).setFill(); bounds.fill() }
        let color: NSColor = selected || whiteText ? .white : blueText ? NSColor(hex: 0x0A246A) : .black
        var x: CGFloat = 7
        if greenArrow && centerGreenArrow {
            let font = Retro.font(bold: bold)
            let textWidth = Retro.textSize(title, font: font).width
            let total = textWidth + 8 + 18
            x = floor((bounds.width - total) / 2)
        }
        if let icon {
            Retro.drawImage(icon, in: NSRect(x: x, y: floor(bounds.midY - iconSize / 2), width: iconSize, height: iconSize))
            x += iconSize + 7
        }
        let text = NSRect(x: x, y: 0, width: max(0, bounds.width - x - (arrow || greenArrow ? 25 : 5)), height: bounds.height)
        if subtitle.isEmpty {
            Retro.drawText(title, in: text, font: Retro.font(bold: bold), color: color, smoothing: smoothing)
        } else {
            Retro.drawText(title, in: NSRect(x: text.minX, y: bounds.midY - 16, width: text.width, height: 16),
                           font: Retro.font(bold: true), color: color, smoothing: smoothing)
            Retro.drawText(subtitle, in: NSRect(x: text.minX, y: bounds.midY, width: text.width, height: 16),
                           font: Retro.font(), color: selected ? .white : NSColor(hex: 0x777777), smoothing: smoothing)
        }
        if greenArrow {
            let r = NSRect(x: x + Retro.textSize(title, font: Retro.font(bold: bold)).width + 8,
                           y: bounds.midY - 9, width: 18, height: 18)
            NSColor(hex: 0x185F1B).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -0.5, dy: -0.5)).fill()
            NSGradient(starting: NSColor(hex: 0x82D665), ending: NSColor(hex: 0x248B24))?.draw(in: NSBezierPath(ovalIn: r), angle: 90)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + 4, y: r.midY - 2)); p.line(to: NSPoint(x: r.midX + 1, y: r.midY - 2))
            p.line(to: NSPoint(x: r.midX + 1, y: r.midY - 5)); p.line(to: NSPoint(x: r.maxX - 3, y: r.midY))
            p.line(to: NSPoint(x: r.midX + 1, y: r.midY + 5)); p.line(to: NSPoint(x: r.midX + 1, y: r.midY + 2))
            p.line(to: NSPoint(x: r.minX + 4, y: r.midY + 2)); p.close()
            NSColor.white.setFill(); p.fill()
        } else if arrow {
            Retro.drawTriangleRight(center: NSPoint(x: bounds.maxX - 10, y: bounds.midY), size: 4, color: color)
        }
    }
}

@MainActor
private final class XPFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class XPSeparatorView: NSView {
    let color: NSColor
    init(frame: NSRect, color: NSColor) { self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])?.draw(in: NSBezierPath(rect: bounds), angle: 0)
    }
}

@MainActor
struct XPProgram {
    let url: URL
    let name: String
    let icon: NSImage
    let folder: Bool
    var detail: String? = nil
    var collectionItem: CollectionItem? = nil
    var collectionFolder: CollectionFolder? = nil

    var listEntry: AppListEntry {
        if let collectionItem { return .collectionItem(collectionItem) }
        if let collectionFolder { return .collectionFolder(collectionFolder) }
        return folder ? .directory(url) : .app(url)
    }

    static func application(_ app: Win10StartMenuView.Application) -> XPProgram {
        XPProgram(url: app.url, name: app.name, icon: app.icon, folder: false)
    }
    static func at(_ url: URL, folder: Bool = false) -> XPProgram {
        XPProgram(url: url, name: SnapshotFixture.isActive ? SnapshotFixture.name(for: url)
                    : FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                  icon: SnapshotFixture.isActive ? SnapshotFixture.icon(for: url) : NSWorkspace.shared.icon(forFile: url.path), folder: folder)
    }
    static func contents(of directory: URL, webFolders: [CollectionFolder] = [], webItems: [CollectionItem] = []) -> [XPProgram] {
        func program(_ item: CollectionItem) -> XPProgram {
            XPProgram(url: item.url, name: item.name, icon: item.icon, folder: false, detail: item.detail, collectionItem: item)
        }
        func byName(_ programs: [XPProgram]) -> [XPProgram] {
            programs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let id = CollectionFolder.id(fromFolderURL: directory) {
            return webFolders.first { $0.id == id }?.items.map(program) ?? []
        }
        // Collections lead the root list, like Start Menu folders before loose shortcuts.
        let collections = directory.path == "/Applications"
            ? webFolders.map { XPProgram(url: $0.folderURL, name: $0.name, icon: $0.icon, folder: true, collectionFolder: $0) } : []
        // First-level items sort in with the apps.
        let rootPrograms = directory.path == "/Applications" ? webItems.map(program) : []
        let hidden = HiddenStore().snapshot()
        func isVisible(_ program: XPProgram) -> Bool {
            program.folder ? !hidden.isHidden(directory: program.url) : !hidden.isHidden(app: program.url)
        }
        if SnapshotFixture.isActive {
            if directory.path == "/Applications" {
                return collections + byName(SnapshotFixture.catalog.map { XPProgram(url: $0.url, name: $0.name, icon: $0.icon, folder: false) }.filter(isVisible) + rootPrograms)
                    + [XPProgram(url: directory.appendingPathComponent("Utilities"), name: "Utilities",
                                 icon: XPStartMenuView.symbol("folder.fill", color: NSColor(hex: 0xE8B640)), folder: true)].filter(isVisible)
            }
            return SnapshotFixture.catalog.prefix(2).map { XPProgram(url: $0.url, name: $0.name, icon: $0.icon, folder: false) }
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return collections + byName(urls.compactMap { url -> XPProgram? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let app = url.pathExtension.lowercased() == "app"
            guard app || (values?.isDirectory == true && values?.isPackage != true) else { return nil }
            return at(url, folder: !app)
        }.filter(isVisible) + rootPrograms)
    }
}

/// Custom-drawn flyout; the same view is used in live panels and offscreen fixtures.
@MainActor
final class XPFlyoutView: NSView {
    private let scroll = NSScrollView()
    private let list = XPFlippedView()
    private var boundsObserver: NSObjectProtocol?
    var onChoose: ((XPProgram, NSView) -> Void)?
    var onHover: ((XPProgram, NSView) -> Void)?
    init(programs: [XPProgram], settings: TaskbarSettings, maxHeight: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 210, height: min(maxHeight, CGFloat(max(1, programs.count)) * 24 + 6)))
        scroll.frame = bounds.insetBy(dx: 3, dy: 3)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        list.frame = NSRect(x: 0, y: 0, width: 204, height: CGFloat(max(1, programs.count)) * 24)
        scroll.documentView = list
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recomputeHoverFromCurrentMouse() }
        }
        addSubview(scroll)
        for (index, app) in programs.enumerated() {
            let row = XPMenuRow(frame: NSRect(x: 0, y: CGFloat(index) * 24, width: 204, height: 24))
            row.title = app.name; row.icon = app.icon; row.iconSize = 16; row.arrow = app.folder
            row.smoothing = settings.fontSmoothing
            row.toolTip = app.detail
            row.onClick = { [weak self, weak row] in if let row { self?.onChoose?(app, row) } }
            row.onHover = { [weak self, weak row] in if let row { self?.onHover?(app, row) } }
            row.onMenu = { AppPinMenu.shared.menu(entry: app.listEntry, settings: settings) }
            list.addSubview(row)
        }
        if programs.isEmpty {
            let row = XPMenuRow(frame: list.bounds)
            row.title = L.t("(Empty)", settings.resolvedLanguage); list.addSubview(row)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
    private var rows: [XPMenuRow] { list.subviews.compactMap { $0 as? XPMenuRow } }
    private func setHover(atListPoint point: NSPoint?) {
        let next = point.flatMap { p in rows.first { $0.frame.contains(p) } }
        rows.forEach { $0.setHovered($0 === next) }
    }
    private func recomputeHoverFromCurrentMouse() {
        guard let window else {
            setHover(atListPoint: nil)
            return
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let clipPoint = scroll.contentView.convert(windowPoint, from: nil)
        guard scroll.contentView.bounds.contains(clipPoint) else {
            setHover(atListPoint: nil)
            return
        }
        let listPoint = list.convert(windowPoint, from: nil)
        setHover(atListPoint: list.bounds.contains(listPoint) ? listPoint : nil)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor(hex: 0x1C4BB0).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

@MainActor
final class XPStartMenuView: NSView {
    private let settings: TaskbarSettings
    private let xpTheme: Theme
    private let preferred: [(String, XPProgram)]
    private let frequent: [XPProgram]
    private var pins: [XPProgram]
    private let pinFixtures: [XPProgram]?
    private let leftScroll = NSScrollView()
    private let leftList = XPFlippedView()
    private let allPrograms = XPMenuRow()
    private var separators: [NSRect] = []
    private var flyouts: [(directory: URL, panel: NSPanel)] = []
    private var webFolders: [CollectionFolder]
    private var webItems: [CollectionItem]
    var onLaunch: ((AppListEntry) -> Void)?
    var onCommand: ((StartItem) -> Void)?
    private(set) var visibleMFUCount = 0
    var allProgramsFrame: NSRect { allPrograms.frame }
    func highlightProgramsForSnapshot() {
        if SnapshotFixture.isActive { allPrograms.selected = true }
    }

    init(context: StartMenuContext, fixturePins: [XPProgram]? = nil) {
        settings = context.settings
        webFolders = AppCollections.folders(settings: context.settings)
        webItems = AppCollections.rootItems(settings: context.settings)
        xpTheme = Theme.make(.winXP)
        pinFixtures = fixturePins
        pins = fixturePins ?? (SnapshotFixture.isActive ? [] : PinStore().startApps.map { XPProgram.at($0.url) })
        let catalog = Win10StartMenuView.loadApplications().map(XPProgram.application)
        if SnapshotFixture.isActive {
            preferred = [("XP Internet", XPProgram.at(URL(fileURLWithPath: "/Applications/Safari.app"))),
                         ("E-mail", XPProgram.at(URL(fileURLWithPath: "/Applications/Mail.app")))]
            frequent = catalog
        } else {
            var preferredPrograms: [(String, XPProgram)] = []
            var preferredURLs = Set<URL>()
            for (address, title) in [("https://example.com", "XP Internet"), ("mailto:", "E-mail")] {
                let target = URL(string: address).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
                let app = target.map { XPProgram.at($0) }
                    ?? catalog.first { !preferredURLs.contains($0.url.resolvingSymlinksInPath()) }
                if let app, preferredURLs.insert(app.url.resolvingSymlinksInPath()).inserted {
                    preferredPrograms.append((title, app))
                }
            }
            preferred = preferredPrograms
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL }.map { XPProgram.at($0) }
            var seen = Set<URL>()
            frequent = (running + catalog).filter { seen.insert($0.url.resolvingSymlinksInPath()).inserted }
        }
        let area = XPMenuLayout.available(bar: context.barFrame, edge: context.edge, visible: context.visibleFrame)
        super.init(frame: NSRect(origin: .zero, size: XPMenuLayout.preferredSize(available: area.size)))
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: HiddenStore.didChange, object: nil)
        leftScroll.drawsBackground = false; leftScroll.hasVerticalScroller = true; leftScroll.autohidesScrollers = true
        leftScroll.documentView = leftList; addSubview(leftScroll)
        allPrograms.title = L.t("All Programs", settings.resolvedLanguage); allPrograms.bold = true; allPrograms.greenArrow = true; allPrograms.centerGreenArrow = true
        allPrograms.smoothing = settings.fontSmoothing
        allPrograms.onClick = { [weak self] in self?.openPrograms() }
        allPrograms.onHover = { [weak self] in self?.openPrograms() }
        addSubview(allPrograms)
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: PinStore.didChange, object: nil)
        arrange()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); arrange() }
    @objc private func pinsChanged() {
        guard !SnapshotFixture.isActive, pinFixtures == nil else { return }
        pins = PinStore().startApps.map { XPProgram.at($0.url) }; arrange()
    }
    static func symbol(_ name: String, color: NSColor) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .symbolTinted([color]) ?? NSImage(size: NSSize(width: 32, height: 32))
    }
    private func row(title: String, icon: NSImage?, bold: Bool = false) -> XPMenuRow {
        let row = XPMenuRow(); row.title = L.t(title, settings.resolvedLanguage); row.icon = icon; row.bold = bold
        row.smoothing = settings.fontSmoothing
        row.onHover = { [weak self] in self?.closeFlyouts() }
        return row
    }
    private func arrange() {
        subviews.filter { $0 !== leftScroll && $0 !== allPrograms }.forEach { $0.removeFromSuperview() }
        leftList.subviews.forEach { $0.removeFromSuperview() }
        separators = []
        let left = floor(bounds.width / 2)
        let footerY = max(66, bounds.height - 36)
        allPrograms.frame = NSRect(x: 4, y: max(66, footerY - 34), width: max(0, left - 8), height: 30)
        leftScroll.frame = NSRect(x: 3, y: 69, width: max(0, left - 6), height: max(0, allPrograms.frame.minY - 73))
        var y: CGFloat = 0
        func addApp(_ app: XPProgram, title: String? = nil) {
            let item = row(title: title ?? app.name, icon: app.icon, bold: title != nil)
            if title != nil { item.subtitle = app.name } else { item.title = app.name }
            item.frame = NSRect(x: 0, y: y, width: max(0, leftScroll.contentSize.width), height: title == nil ? 36 : 44)
            item.onClick = { [weak self] in self?.onLaunch?(app.listEntry) }
            item.onMenu = { [weak self] in self.map { AppPinMenu.shared.menu(url: app.url, settings: $0.settings) } }
            leftList.addSubview(item); y += item.frame.height
        }
        for (title, app) in preferred { addApp(app, title: title) }
        pins.forEach { addApp($0) }
        let separator = XPSeparatorView(frame: NSRect(x: 8, y: y + 4, width: max(0, left - 22), height: 1), color: NSColor(hex: 0xD5D2CA))
        leftList.addSubview(separator); y += 10
        let excluded = Set((preferred.map { $0.1 } + pins).map { $0.url.resolvingSymlinksInPath() })
        let remaining = frequent.filter { !excluded.contains($0.url.resolvingSymlinksInPath()) }
        visibleMFUCount = min(6, remaining.count, max(0, Int((leftScroll.bounds.height - y) / 36)))
        remaining.prefix(visibleMFUCount).forEach { addApp($0) }
        leftList.frame = NSRect(x: 0, y: 0, width: leftScroll.contentSize.width, height: max(y, leftScroll.bounds.height))
        separators.append(NSRect(x: 9, y: allPrograms.frame.minY - 3, width: max(0, left - 18), height: 1))
        let links = [("My Documents", "folder.fill"), ("My Pictures", "photo.fill"), ("My Music", "music.note"),
                     ("My Computer", "desktopcomputer"), ("Control Panel", "gearshape.fill"),
                     ("Help and Support", "questionmark.circle.fill"), ("Search", "magnifyingglass"), ("Run...", "terminal.fill")]
        let rowHeight = min(36, max(0, (footerY - 78 - 20) / 8))
        var linkY: CGFloat = 78
        for (index, link) in links.enumerated() {
            if index == 4 || index == 5 {
                separators.append(NSRect(x: left + 9, y: linkY + 4, width: max(0, bounds.width - left - 18), height: 1)); linkY += 10
            }
            let item = row(title: link.0, icon: Self.symbol(link.1, color: NSColor(hex: index < 3 ? 0xD5A32A : 0x3675BF)), bold: index < 4)
            if link.0 == "Help and Support" {
                item.icon = NSImage(systemSymbolName: link.1, accessibilityDescription: nil)?
                    .symbolTinted([.white, NSColor(hex: 0x3675BF)])
            }
            item.blueText = true; item.iconSize = index < 4 ? 24 : 20
            item.frame = NSRect(x: left + 4, y: linkY, width: max(0, bounds.width - left - 8), height: rowHeight)
            item.onClick = { [weak self] in self?.openLink(link.0) }; addSubview(item); linkY += rowHeight
        }
        let shutdown = row(title: "Turn Off Computer", icon: Self.symbol("power", color: .white))
        let logoff = row(title: "Log Off", icon: Self.symbol("key.fill", color: NSColor(hex: 0xFFF3AE)))
        let shutdownWidth = Retro.textSize(shutdown.title, font: Retro.font()).width + 44
        let logoffWidth = Retro.textSize(logoff.title, font: Retro.font()).width + 44
        shutdown.frame = NSRect(x: bounds.width - shutdownWidth - 8, y: footerY + 4, width: shutdownWidth, height: 28)
        logoff.frame = NSRect(x: shutdown.frame.minX - logoffWidth - 5, y: footerY + 4, width: logoffWidth, height: 28)
        for item in [logoff, shutdown] { item.whiteText = true; item.iconSize = 20; addSubview(item) }
        shutdown.onClick = { [weak self] in self?.onCommand?(.shutDown) }
        logoff.onClick = { [weak self] in self?.onCommand?(.settings) }
        needsDisplay = true
    }
    private func openLink(_ key: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch key {
        case "My Documents": onLaunch?(.app(home.appendingPathComponent("Documents")))
        case "My Pictures": onLaunch?(.app(home.appendingPathComponent("Pictures")))
        case "My Music": onLaunch?(.app(home.appendingPathComponent("Music")))
        case "My Computer": onLaunch?(.app(URL(fileURLWithPath: "/")))
        case "Control Panel": if let url = URL(string: "x-apple.systempreferences:") { onLaunch?(.app(url)) }
        case "Help and Support": onLaunch?(.app(URL(fileURLWithPath: "/System/Applications/Tips.app")))
        case "Search": onLaunch?(.app(URL(fileURLWithPath: "/System/Library/CoreServices/Spotlight.app")))
        case "Run...": onCommand?(.run)
        default: break
        }
    }
    /// Rebuilds the open flyouts without an entry just hidden or with one just shown again.
    @objc private func hiddenEntriesChanged() {
        webFolders = AppCollections.folders(settings: settings)
        webItems = AppCollections.rootItems(settings: settings)
        let wasOpen = !flyouts.isEmpty
        closeFlyouts()
        if wasOpen { openPrograms() }
    }
    private func openPrograms() { showFlyout(directory: URL(fileURLWithPath: "/Applications"), row: allPrograms, depth: 0) }
    func closeFlyouts(from depth: Int = 0) {
        guard depth < flyouts.count else { return }
        for entry in flyouts[depth...] { entry.panel.parent?.removeChildWindow(entry.panel); entry.panel.orderOut(nil) }
        flyouts.removeSubrange(depth...)
    }
    func ownsFlyout(_ window: NSWindow?) -> Bool { flyouts.contains { $0.panel === window } }
    private func showFlyout(directory: URL, row: NSView, depth: Int) {
        guard !SnapshotFixture.isActive, let parent = row.window else { return }
        if depth < flyouts.count, flyouts[depth].directory == directory { return }
        closeFlyouts(from: depth)
        let visible = parent.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let view = XPFlyoutView(programs: XPProgram.contents(of: directory, webFolders: webFolders, webItems: webItems), settings: settings, maxHeight: visible.height)
        let anchor = parent.convertToScreen(row.convert(row.bounds, to: nil))
        let width = min(view.frame.width, visible.width)
        let x = anchor.maxX + width <= visible.maxX ? anchor.maxX : max(visible.minX, anchor.minX - width)
        let y = min(max(anchor.maxY - view.frame.height, visible.minY), visible.maxY - view.frame.height)
        let panel = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: view.frame.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true; panel.contentView = view
        view.onChoose = { [weak self] app, item in
            if app.folder { self?.showFlyout(directory: app.url, row: item, depth: depth + 1) }
            else { self?.onLaunch?(app.listEntry) }
        }
        view.onHover = { [weak self] app, item in
            if app.folder { self?.showFlyout(directory: app.url, row: item, depth: depth + 1) }
            else { self?.closeFlyouts(from: depth + 1) }
        }
        flyouts.append((directory, panel)); parent.addChildWindow(panel, ordered: .above); panel.orderFrontRegardless()
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: r.minX, y: r.maxY)); shape.line(to: NSPoint(x: r.minX, y: r.minY + 6))
        shape.curve(to: NSPoint(x: r.minX + 6, y: r.minY), controlPoint1: NSPoint(x: r.minX, y: r.minY), controlPoint2: NSPoint(x: r.minX, y: r.minY))
        shape.line(to: NSPoint(x: r.maxX - 6, y: r.minY))
        shape.curve(to: NSPoint(x: r.maxX, y: r.minY + 6), controlPoint1: NSPoint(x: r.maxX, y: r.minY), controlPoint2: NSPoint(x: r.maxX, y: r.minY))
        shape.line(to: NSPoint(x: r.maxX, y: r.maxY)); shape.close()
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        xpTheme.menuFace.setFill(); bounds.fill()
        let blue = xpTheme.bannerFill
        Retro.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 64), blue)
        xpTheme.barEdge.setFill(); NSRect(x: 1, y: 0, width: bounds.width - 2, height: 1).fill()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.12), NSColor.white.withAlphaComponent(0)])?.draw(in: NSBezierPath(rect: NSRect(x: 1, y: 1, width: bounds.width - 2, height: 12)), angle: 90)
        NSGradient(colors: [NSColor(hex: 0xE5A73A).withAlphaComponent(0), NSColor(hex: 0xE5A73A), NSColor(hex: 0xE5A73A).withAlphaComponent(0)])?.draw(in: NSBezierPath(rect: NSRect(x: 1, y: 64, width: bounds.width - 2, height: 2)), angle: 0)
        let left = floor(bounds.width / 2), footerY = max(66, bounds.height - 36)
        Retro.fill(NSRect(x: left, y: 66, width: bounds.width - left, height: max(0, footerY - 66)),
                   [NSColor(hex: 0xD3E5FA), NSColor(hex: 0xC5DCF8)])
        NSColor(hex: 0x95BDEE).setFill(); NSRect(x: left, y: 66, width: 1, height: max(0, footerY - 66)).fill()
        for separator in separators {
            let color = separator.minX < left ? NSColor(hex: 0xD5D2CA) : NSColor(hex: 0x9BBCF0)
            NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])?.draw(in: NSBezierPath(rect: separator), angle: 0)
        }
        Retro.fill(NSRect(x: 0, y: footerY, width: bounds.width, height: 36),
                   [NSColor(hex: 0x4282D6), NSColor(hex: 0x1A5FC3), NSColor(hex: 0x0A49B4)])
        NSColor(hex: 0x5C9AE8).setFill(); NSRect(x: 0, y: footerY, width: bounds.width, height: 1).fill()
        let picture = NSRect(x: 10, y: 8, width: 48, height: 48)
        let pictureFrame = NSBezierPath(roundedRect: picture.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        let pictureShadow = NSBezierPath(roundedRect: picture.insetBy(dx: 1, dy: 1).offsetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.22).setFill(); pictureShadow.fill()
        AeroDrawing.userPicture(in: picture.insetBy(dx: 3, dy: 3))
        NSColor.white.setStroke(); pictureFrame.lineWidth = 2; pictureFrame.stroke()
        let user = SnapshotFixture.userName
        let name = NSRect(x: 69, y: 10, width: max(0, bounds.width - 80), height: 44)
        Retro.drawText(user, in: name.offsetBy(dx: 1, dy: 1), font: Retro.font(bold: true, size: 14), color: NSColor(hex: 0x0A246A), smoothing: settings.fontSmoothing)
        Retro.drawText(user, in: name, font: Retro.font(bold: true, size: 14), color: xpTheme.bannerText, smoothing: settings.fontSmoothing)
        // XP's colored square command icons are painted behind their white glyphs.
        for item in subviews.compactMap({ $0 as? XPMenuRow }) where item.whiteText {
            let power = item.title == L.t("Turn Off Computer", settings.resolvedLanguage)
            Retro.fill(NSRect(x: item.frame.minX + 5, y: item.frame.midY - 11, width: 24, height: 22),
                       power ? [NSColor(hex: 0xF37B65), NSColor(hex: 0xC92C16)] : [NSColor(hex: 0xF2C35F), NSColor(hex: 0xC68D27)], radius: 3)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(hex: 0x1C4BB0).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

/// Composes the open cascade without creating or ordering any windows.
@MainActor
final class XPCascadeSnapshotView: NSView {
    override var isFlipped: Bool { true }
    init(menu: XPStartMenuView, settings: TaskbarSettings) {
        let flyout = XPFlyoutView(programs: XPProgram.contents(of: URL(fileURLWithPath: "/Applications"),
                                                             webFolders: AppCollections.folders(settings: settings),
                                                             webItems: AppCollections.rootItems(settings: settings)),
                                  settings: settings, maxHeight: 400)
        let anchor = menu.allProgramsFrame
        super.init(frame: NSRect(x: 0, y: 0, width: max(menu.frame.width, anchor.maxX + flyout.frame.width), height: menu.frame.height))
        menu.highlightProgramsForSnapshot()
        addSubview(menu)
        flyout.frame.origin = NSPoint(x: anchor.maxX, y: min(anchor.minY, bounds.height - flyout.frame.height))
        addSubview(flyout)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
