import AppKit

@MainActor
enum Win10Drawing {
    static let accent = NSColor(hex: 0x0078D7)

    static func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func logo(in rect: NSRect, color: NSColor = .white) {
        color.setFill()
        let scale = min(rect.width, rect.height) / 88
        let panes: [[(CGFloat, CGFloat)]] = [
            [(0, 12.402), (35.687, 7.542), (35.703, 41.965), (0.033, 42.168)],
            [(35.67, 45.931), (35.698, 80.384), (0.028, 75.48), (0.026, 45.7)],
            [(39.996, 6.906), (87.314, 0), (87.314, 41.527), (39.996, 41.903)],
            [(87.325, 45.252), (87.314, 86.592), (39.996, 79.914), (39.93, 45.175)]
        ]
        for pane in panes {
            let p = NSBezierPath()
            for (index, point) in pane.enumerated() {
                let mapped = NSPoint(x: rect.midX + (point.0 - 44) * scale,
                                     y: rect.midY + (44 - point.1) * scale)
                if index == 0 { p.move(to: mapped) } else { p.line(to: mapped) }
            }
            p.close()
            p.fill()
        }
    }

    static func hamburger(in rect: NSRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        for y in stride(from: rect.minY + 2, through: rect.maxY - 2, by: 5) {
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
        }
        path.stroke()
    }

    static func menuBackground(_ view: NSView) -> NSColor {
        isDark(view) ? NSColor(hex: 0x1B1B1B, alpha: 0.98) : NSColor(hex: 0xEEEEEE, alpha: 0.98)
    }

    static func menuText(_ view: NSView) -> NSColor {
        isDark(view) ? .white : NSColor(hex: 0x202020)
    }
}

@MainActor
private final class Win10SearchFieldCell: NSSearchFieldCell {
    var win10Placeholder = ""

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        let size: CGFloat = min(16, max(12, rect.height - 8))
        return NSRect(x: rect.minX + 7, y: rect.midY - size / 2, width: size, height: size)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let button = searchButtonRect(forBounds: rect)
        let rightInset: CGFloat = 8
        return NSRect(x: button.maxX + 7, y: rect.minY + 1,
                      width: max(0, rect.maxX - button.maxX - 7 - rightInset),
                      height: max(0, rect.height - 2))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        searchTextRect(forBounds: rect)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

    private func editingTextRect(forBounds rect: NSRect) -> NSRect {
        var result = searchTextRect(forBounds: rect)
        // NSTextView's field editor positions its baseline near the top of
        // the supplied frame. Lower the editor while keeping its bottom edge
        // inside the taskbar control so typed text shares the icon's center.
        result.origin.y += 5
        result.size.height = max(1, result.height - 5)
        return result
    }

    // NSSearchFieldCell uses a separate field editor while the user types.
    // Its default frame ignores titleRect/searchTextRect, so explicitly use
    // the same inset as the drawn value for both editing and selection.
    override func edit(withFrame frameRect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: editingTextRect(forBounds: frameRect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame frameRect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?, start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: editingTextRect(forBounds: frameRect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let button = searchButtonCell {
            button.title = ""
            button.draw(withFrame: searchButtonRect(forBounds: cellFrame), in: controlView)
        }

        let searchField = controlView as? NSSearchField
        let value = searchField?.stringValue ?? stringValue
        // While editing, AppKit's field editor draws the live value. Drawing
        // it here as well produces two copies of the query in the taskbar.
        // Keep drawing our placeholder while an empty editor is focused because
        // the native placeholder is intentionally cleared for this custom cell.
        if searchField?.currentEditor() != nil && !value.isEmpty { return }
        let text = value.isEmpty ? win10Placeholder : value
        guard !text.isEmpty else { return }
        let color = value.isEmpty
            ? NSColor.placeholderTextColor
            : (searchField?.textColor ?? NSColor.textColor)
        let font = searchField?.font ?? NSFont.systemFont(ofSize: 12)
        Retro.drawText(text, in: searchTextRect(forBounds: cellFrame), font: font,
                       color: color, smoothing: true)
    }
}

@MainActor
final class Win10SearchBox: NSSearchField {
    var onOpen: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    private var win10Placeholder = ""

    override var placeholderString: String? {
        get { win10Placeholder }
        set {
            win10Placeholder = newValue ?? ""
            if let textCell = cell as? NSTextFieldCell {
                textCell.placeholderString = ""
                textCell.placeholderAttributedString = NSAttributedString(string: "")
            }
            if let searchCell = cell as? Win10SearchFieldCell {
                searchCell.win10Placeholder = win10Placeholder
            }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = Win10SearchFieldCell(textCell: "")
        if let textCell = cell as? NSTextFieldCell {
            // Replacing NSSearchField's cell resets these flags to the
            // NSTextFieldCell defaults, which makes the field look correct
            // but silently reject all keyboard input.
            textCell.isEditable = true
            textCell.isSelectable = true
            textCell.isEnabled = true
            textCell.placeholderString = ""
            textCell.placeholderAttributedString = NSAttributedString(string: "")
        }
        if let searchCell = cell as? Win10SearchFieldCell {
            searchCell.searchButtonCell?.title = ""
        }
        font = .systemFont(ofSize: 12)
        bezelStyle = .squareBezel
        focusRingType = .none
        placeholderString = "Type here to search"
        target = self
        action = #selector(submit)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        // Let AppKit finish the click before opening Start. Start's outside-click
        // monitor otherwise sees this same mouse-down after the callback and
        // immediately closes the menu, leaving the search field without focus.
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        onOpen?(stringValue)
        window?.makeKey()
        window?.makeFirstResponder(self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func simulateMouseDownForTesting() {
        onOpen?(stringValue)
        window?.makeKey()
        window?.makeFirstResponder(self)
    }
    @objc private func submit() {
        onOpen?(stringValue)
        onSubmit?(stringValue)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { submit() } else { super.keyDown(with: event) }
    }
}

extension Win10SearchBox: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { onChange?(stringValue) }
}

@MainActor
final class Win10StartMenuView: NSView {
    struct Application {
        let url: URL
        let name: String
        let icon: NSImage
        /// Web App Collection description, shown as a tooltip.
        var detail: String? = nil
        /// Set for a row that comes from a collection.
        var collectionItem: CollectionItem? = nil

        var listEntry: AppListEntry { collectionItem.map(AppListEntry.collectionItem) ?? .app(url) }

        init(url: URL, name: String, icon: NSImage, detail: String? = nil) {
            self.url = url
            self.name = name
            self.icon = icon
            self.detail = detail
        }

        init(collectionItem item: CollectionItem) {
            self.init(url: item.url, name: item.name, icon: item.icon, detail: item.detail)
            collectionItem = item
        }
    }
    private let settings: TaskbarSettings
    private let query: String
    private var apps: [Application]
    private var webFolders: [CollectionFolder]
    private var webItems: [CollectionItem]
    private var expandedFolders = Set<String>()
    private var webToolTips: [NSView.ToolTipTag] = []
    private var webToolTipKeys: [String] = []
    /// A row of the All apps list: an app, or a collection folder that expands in place.
    private enum AppRow {
        case app(Application)
        case folder(CollectionFolder)

        var name: String {
            switch self {
            case .app(let app): return app.name
            case .folder(let folder): return folder.name
            }
        }
    }
    /// Geometry from relayoutItems(): visible letter headings and rows, every pinned tile, and the visible tile hit areas.
    private var letterRects: [(String, NSRect)] = []
    private var appRects: [(Application, NSRect)] = []
    private var folderRects: [(CollectionFolder, NSRect)] = []
    private var tiles: [(Application, NSRect)] = []
    private var tileRects: [(Application, NSRect)] = []
    private enum RailButton { case user, documents, pictures, settings, power }
    private var railRects: [(RailButton, NSRect)] = []
    private var userRect = NSRect.zero
    private var picturesRect = NSRect.zero
    private var hoverRail: Int?
    var debugHoverRail: Int?
    private var pinnedScroll: CGFloat = 0
    private var pinnedContentHeight: CGFloat = 0
    private var appsScroll: CGFloat = 0
    private var appsContentHeight: CGFloat = 0
    var onLaunch: ((AppListEntry) -> Void)?
    var onCommand: ((StartItem) -> Void)?
    var onUser: (() -> Void)?

    static func firstApplication(matching query: String) -> Application? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let settings = SnapshotFixture.isActive ? SnapshotFixture.settings : SettingsStore.shared.current
        let web = AppCollections.items(settings: settings).map(Application.init(collectionItem:))
        return (loadApplications() + web)
            .filter { $0.name.localizedStandardContains(trimmed) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .first
    }

    init(settings: TaskbarSettings, searchText: String = "") {
        self.settings = settings
        self.query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apps = Self.loadApplications()
        self.webFolders = AppCollections.folders(settings: settings)
        self.webItems = AppCollections.rootItems(settings: settings)
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: PinStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: HiddenStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: AppCatalog.didChange, object: nil)
        wantsLayer = true
        layer?.masksToBounds = true
        updateRailLayout()
        toolTip = SnapshotFixture.userName
        relayoutItems()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        updateRailLayout()
        relayoutItems()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutItems()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func focusSearch() {}
    @objc private func pinsChanged() { pinnedScroll = 0; relayoutItems() }
    @objc private func hiddenEntriesChanged() {
        apps = Self.loadApplications()
        webFolders = AppCollections.folders(settings: settings)
        webItems = AppCollections.rootItems(settings: settings)
        relayoutItems()
    }

    func debugCollectionFolderRects() -> [NSRect] { folderRects.map(\.1) }

    func debugListedAppNames() -> [String] { appRects.map(\.0.name) }

    func debugAppRect(named name: String) -> NSRect? { appRects.first { $0.0.name == name }?.1 }

    func expandCollectionFoldersForTesting() {
        expandedFolders = Set(webFolders.map(\.id))
        relayoutItems()
    }

    func scrollAllAppsForTesting(by delta: CGFloat) {
        let areaHeight = max(0, bounds.height - 44)
        appsScroll = min(max(0, appsContentHeight - areaHeight), max(0, appsScroll - delta))
        relayoutItems()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let delta = event.scrollingDeltaY
        if point.x >= 438 {
            pinnedScroll = min(max(0, pinnedContentHeight - max(0, bounds.height - 68)),
                               max(0, pinnedScroll - delta))
            relayoutItems()
        } else if point.x > 48 {
            scrollAllAppsForTesting(by: delta)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let folder = folderRects.first(where: { $0.1.contains(point) })?.0 {
            return AppPinMenu.shared.menu(entry: .collectionFolder(folder), settings: settings)
        }
        if let app = appRects.first(where: { $0.1.contains(point) })?.0 {
            return AppPinMenu.shared.menu(entry: app.listEntry, settings: settings)
        }
        guard let tile = tileRects.first(where: { $0.1.contains(point) })?.0 else { return nil }
        return AppPinMenu.shared.menu(entry: tile.listEntry, settings: settings, includeHide: false)
    }

    private func updateRailLayout() {
        let height = bounds.height
        func anchored(_ y: CGFloat, height itemHeight: CGFloat) -> CGFloat {
            max(0, min(y, max(0, height - itemHeight)))
        }
        userRect = NSRect(x: 0, y: anchored(height - 204, height: 32), width: 48, height: 32)
        picturesRect = NSRect(x: 0, y: anchored(height - 124, height: 32), width: 48, height: 32)
        railRects = [
            (.user, userRect),
            (.documents, NSRect(x: 0, y: anchored(height - 164, height: 32), width: 48, height: 32)),
            (.pictures, picturesRect),
            (.settings, NSRect(x: 0, y: anchored(height - 84, height: 32), width: 48, height: 32)),
            (.power, NSRect(x: 0, y: anchored(height - 44, height: 32), width: 48, height: 32))
        ]
    }

    private var filtered: [Application] {
        guard !query.isEmpty else { return apps }
        let web = (webItems + webFolders.flatMap(\.items)).map(Application.init(collectionItem:))
        return (apps + web).filter { $0.name.localizedStandardContains(query) }
    }

    /// Letter sections. First-level collection items and folders sort in with the apps; searching lists
    /// every matching item, without folders.
    private func sections() -> [(String, [AppRow])] {
        var rows = filtered.map(AppRow.app)
        if query.isEmpty {
            rows += webItems.map { .app(Application(collectionItem: $0)) }
            rows += webFolders.map(AppRow.folder)
        }
        return Dictionary(grouping: rows) { String($0.name.prefix(1)).uppercased() }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    private var appsArea: NSRect {
        NSRect(x: 48, y: 44, width: max(0, min(390, bounds.width - 48)), height: max(0, bounds.height - 44))
    }

    private var tileArea: NSRect {
        NSRect(x: 438, y: 58, width: max(0, bounds.width - 448), height: max(0, bounds.height - 68))
    }

    /// Lays out rows and tiles for the current size, scroll offsets and pins. Runs when those change
    /// (not on every hover redraw), so draw() only paints and tooltips are not rebuilt while the mouse moves.
    private func relayoutItems() {
        let appsArea = self.appsArea
        letterRects.removeAll()
        appRects.removeAll()
        folderRects.removeAll()
        var y: CGFloat = 52
        for (letter, group) in sections() {
            let letterRect = NSRect(x: 68, y: y - appsScroll, width: 250, height: 18)
            if letterRect.intersects(appsArea) { letterRects.append((letter, letterRect)) }
            y += 20
            for row in group {
                let rect = NSRect(x: 68, y: y - appsScroll, width: 330, height: 30)
                y += 31
                switch row {
                case .app(let app):
                    if rect.intersects(appsArea) { appRects.append((app, rect)) }
                case .folder(let folder):
                    if rect.intersects(appsArea) { folderRects.append((folder, rect)) }
                    guard expandedFolders.contains(folder.id) else { continue }
                    for item in folder.items {
                        let itemRect = NSRect(x: 92, y: y - appsScroll, width: 306, height: 30)
                        if itemRect.intersects(appsArea) { appRects.append((Application(collectionItem: item), itemRect)) }
                        y += 31
                    }
                }
            }
            y += 5
        }
        appsContentHeight = max(0, y - 52)
        let maxAppsScroll = max(0, appsContentHeight - appsArea.height)
        if appsScroll > maxAppsScroll {
            appsScroll = maxAppsScroll
            relayoutItems()
            return
        }

        let pins = PinStore().startApps
        let tileApps = pins.isEmpty ? Array(filtered.prefix(6)) : pins.map { pin in
            apps.first { PinnedApp(url: $0.url).matches(pin) } ??
                Application(url: pin.url, name: pin.url.deletingPathExtension().lastPathComponent,
                            icon: AppIconCache.shared.icon(for: pin.url))
        }.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        let tileSizes: [(CGFloat, CGFloat)] = [(82, 82), (82, 82), (170, 82), (82, 82), (170, 82), (82, 82)]
        let tileArea = self.tileArea
        var tx: CGFloat = 438, ty: CGFloat = 58
        tiles.removeAll()
        tileRects.removeAll()
        for (index, app) in tileApps.enumerated() {
            let size = tileSizes[index % tileSizes.count]
            if tx + size.0 > bounds.width - 10 {
                tx = 438; ty += 90
            }
            let rect = NSRect(x: tx, y: ty - pinnedScroll, width: size.0, height: size.1)
            tiles.append((app, rect))
            if rect.intersects(tileArea) { tileRects.append((app, rect.intersection(tileArea))) }
            tx += size.0 + 8
        }
        pinnedContentHeight = tileApps.isEmpty ? 0 : ty + 82 - 58
        updateWebToolTips()
        needsDisplay = true
    }

    private func updateWebToolTips() {
        let tips = (appRects + tileRects).compactMap { app, rect in app.detail.map { (rect, $0) } }
        let keys = tips.map { "\(NSStringFromRect($0.0))|\($0.1)" }
        guard keys != webToolTipKeys else { return }
        webToolTipKeys = keys
        webToolTips.forEach(removeToolTip)
        webToolTips = tips.map { addToolTip($0.0, owner: $0.1 as NSString, userData: nil) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverRail = railRects.firstIndex { $0.1.contains(p) }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoverRail = nil
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let button = railRects.first(where: { $0.1.contains(p) })?.0 {
            switch button {
            case .user:
                onUser?()
                return
            case .pictures:
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
                return
            case .documents:
                onCommand?(.documents)
                return
            case .settings:
                onCommand?(.settings)
                return
            case .power:
                let menu = NSMenu()
                let run = NSMenuItem(title: L.t("Run…", settings.resolvedLanguage), action: #selector(runFromMenu), keyEquivalent: "")
                run.target = self
                let shut = NSMenuItem(title: L.t("Shut Down…", settings.resolvedLanguage), action: #selector(shutDownFromMenu), keyEquivalent: "")
                shut.target = self
                menu.addItem(run)
                menu.addItem(shut)
                menu.popUp(positioning: nil, at: NSPoint(x: 48, y: bounds.height - 44), in: self)
                return
            }
        }
        if let folder = folderRects.first(where: { $0.1.contains(p) })?.0 {
            if expandedFolders.remove(folder.id) == nil { expandedFolders.insert(folder.id) }
            relayoutItems()
            return
        }
        if let app = appRects.first(where: { $0.1.contains(p) })?.0 ?? tileRects.first(where: { $0.1.contains(p) })?.0 {
            onLaunch?(app.listEntry)
        }
    }

    @objc private func runFromMenu() { onCommand?(.run) }
    @objc private func shutDownFromMenu() { onCommand?(.shutDown) }

    override func draw(_ dirtyRect: NSRect) {
        let text = Win10Drawing.menuText(self)
        Win10Drawing.menuBackground(self).setFill()
        bounds.fill()
        let rail = NSRect(x: 0, y: 0, width: 48, height: bounds.height)
        (Win10Drawing.isDark(self) ? NSColor(hex: 0x252525) : NSColor(hex: 0xE2E2E2)).setFill()
        rail.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 48, y: 0, width: 0.5, height: bounds.height).fill()

        Win10Drawing.hamburger(in: NSRect(x: 15, y: 20, width: 18, height: 16), color: text)
        let activeHoverRail = debugHoverRail ?? hoverRail
        if let activeHoverRail, activeHoverRail < railRects.count {
            NSColor(hex: 0xFFFFFF, alpha: Win10Drawing.isDark(self) ? 0.10 : 0.22).setFill()
            railRects[activeHoverRail].1.fill()
        }
        let userIcon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: SnapshotFixture.userName)?
            .symbolTinted([text])
        if let userIcon {
            Retro.drawImage(userIcon, in: NSRect(x: 14, y: userRect.midY - 10, width: 20, height: 20))
        }
        drawRailIcon("doc.text.fill", at: railRects[1].1, color: text, tooltip: "Documents")
        drawRailIcon("photo.fill", at: railRects[2].1, color: text, tooltip: "Pictures")
        drawRailIcon("gearshape.fill", at: railRects[3].1, color: text, tooltip: "Settings")
        drawRailIcon("power", at: railRects[4].1, color: text, tooltip: "Power")

        let filteredMode = !query.isEmpty
        Retro.drawText(filteredMode ? "Best match" : "All apps",
                       in: NSRect(x: 68, y: 18, width: 300, height: 24),
                       font: .systemFont(ofSize: 14, weight: .semibold), color: text, smoothing: true)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: appsArea).addClip()
        for (letter, letterRect) in letterRects {
            Retro.drawText(letter, in: letterRect,
                           font: .systemFont(ofSize: 11, weight: .semibold), color: Win10Drawing.accent, smoothing: true)
        }
        for (app, rect) in appRects {
            Retro.drawImage(app.icon, in: NSRect(x: rect.minX, y: rect.midY - 10, width: 20, height: 20))
            Retro.drawText(app.name, in: NSRect(x: rect.minX + 30, y: rect.minY, width: 290, height: rect.height),
                           font: .systemFont(ofSize: 12), color: text, smoothing: true)
        }
        for (folder, rect) in folderRects {
            Retro.drawImage(folder.icon, in: NSRect(x: rect.minX, y: rect.midY - 10, width: 20, height: 20))
            Retro.drawText(folder.name, in: NSRect(x: rect.minX + 30, y: rect.minY, width: 270, height: rect.height),
                           font: .systemFont(ofSize: 12), color: text, smoothing: true)
            let chevron = expandedFolders.contains(folder.id) ? "chevron.up" : "chevron.down"
            if let image = NSImage(systemSymbolName: chevron, accessibilityDescription: nil)?.symbolTinted([text]) {
                Retro.drawImage(image, in: NSRect(x: rect.maxX - 22, y: rect.midY - 6, width: 12, height: 12))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if letterRects.isEmpty && appRects.isEmpty && folderRects.isEmpty {
        Retro.drawText(L.t(AppCatalog.shared.isReady ? "No apps found" : "Loading…", settings.resolvedLanguage), in: NSRect(x: 68, y: 82, width: 300, height: 24),
                           font: .systemFont(ofSize: 13), color: text, smoothing: true)
        }

        Retro.drawText(L.t("Pinned", settings.resolvedLanguage), in: NSRect(x: 438, y: 18, width: 250, height: 24),
                       font: .systemFont(ofSize: 14, weight: .semibold), color: text, smoothing: true)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: tileArea).addClip()
        for (index, (app, rect)) in tiles.enumerated() {
            let colors = [NSColor(hex: 0x0078D7), NSColor(hex: 0x107C10), NSColor(hex: 0xD83B01), NSColor(hex: 0x5C2D91)]
            colors[index % colors.count].setFill(); rect.fill()
            Retro.drawImage(app.icon, in: NSRect(x: rect.minX + 12, y: rect.minY + 12, width: 28, height: 28))
            Retro.drawText(app.name, in: NSRect(x: rect.minX + 8, y: rect.maxY - 25, width: rect.width - 16, height: 18),
                           font: .systemFont(ofSize: 10), color: .white, smoothing: true)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawRailIcon(_ symbol: String, at rect: NSRect, color: NSColor, tooltip: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .symbolTinted([color])
        if let image { Retro.drawImage(image, in: NSRect(x: 14, y: rect.midY - 9, width: 18, height: 18)) }
    }

    /// Reads the catalog; the lists never touch the disk themselves.
    static func loadApplications() -> [Application] {
        if SnapshotFixture.isActive, let catalog = ApplicationCatalog.override {
            let hidden = HiddenStore().snapshot()
            return catalog.map { Application(url: $0.url, name: $0.name, icon: $0.icon) }.filter { !hidden.isHidden(app: $0.url) }
        }
        let hidden = HiddenStore().snapshot()
        return AppCatalog.shared.flatApps().filter { !hidden.isHidden(app: $0.url) }.map {
            Application(url: $0.url, name: $0.nameWithoutExtension, icon: AppIconCache.shared.icon(for: $0.url))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
