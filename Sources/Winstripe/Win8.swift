import AppKit
import CoreImage
import ImageIO

struct Win8TileAnimation {
    static let entranceDuration: CFTimeInterval = 0.25
    static let entranceStagger: CFTimeInterval = 0.035
    static let entranceOffset: CGFloat = 24
    static let entranceScale: CGFloat = 0.94
    static let pressDuration: CFTimeInterval = 0.08
    static let pressScale: CGFloat = 0.965
    static let hoverDuration: CFTimeInterval = 0.12
    static let transitionDuration: CFTimeInterval = 0.28
    static let flipDuration: CFTimeInterval = 0.64
    static let flipMinimumDelay: TimeInterval = 6
    static let flipMaximumDelay: TimeInterval = 12
    static let firstFlipMinimumDelay: TimeInterval = 2
    static let firstFlipMaximumDelay: TimeInterval = 4
    static let backDwellMinimum: TimeInterval = 4
    static let backDwellMaximum: TimeInterval = 8
    static let perspective: CGFloat = -1.0 / 600.0

    static var snapshotMode: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--snapshot-dir") || args.contains("--win8-edit-snapshot")
    }

    static var debugColumnMajorPacker: Bool {
        ProcessInfo.processInfo.arguments.contains("--win8-debug-column-major")
    }

    static var reduceMotion: Bool {
        if ProcessInfo.processInfo.arguments.contains("--win8-anim-selftest") ||
            ProcessInfo.processInfo.arguments.contains("--win8-anim-frames") ||
            ProcessInfo.processInfo.arguments.contains("--snapshot-dir") ||
            ProcessInfo.processInfo.arguments.contains("--win8-edit-snapshot") { return false }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private struct Win8SeededRandom {
    var state: UInt64 = 0x524554524F444F43
    mutating func nextUnit() -> Double {
        state = state &* 2862933555777941757 &+ 3037000493
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func delay() -> TimeInterval {
        Win8TileAnimation.flipMinimumDelay +
            nextUnit() * (Win8TileAnimation.flipMaximumDelay - Win8TileAnimation.flipMinimumDelay)
    }
    mutating func firstDelay() -> TimeInterval {
        Win8TileAnimation.firstFlipMinimumDelay +
            nextUnit() * (Win8TileAnimation.firstFlipMaximumDelay - Win8TileAnimation.firstFlipMinimumDelay)
    }
    mutating func backDwell() -> TimeInterval {
        Win8TileAnimation.backDwellMinimum +
            nextUnit() * (Win8TileAnimation.backDwellMaximum - Win8TileAnimation.backDwellMinimum)
    }
}

@MainActor
enum Win8Drawing {
    struct Accent {
        let name: String
        let value: UInt32
        let color: NSColor
    }

    static let accents: [Accent] = [
        Accent(name: "Purple", value: 0x2D004E, color: NSColor(hex: 0x2D004E)),
        Accent(name: "Dark blue", value: 0x001E4E, color: NSColor(hex: 0x001E4E)),
        Accent(name: "Blue", value: 0x0078D7, color: NSColor(hex: 0x0078D7)),
        Accent(name: "Green", value: 0x107C10, color: NSColor(hex: 0x107C10)),
        Accent(name: "Orange", value: 0xD83B01, color: NSColor(hex: 0xD83B01)),
        Accent(name: "Teal", value: 0x008272, color: NSColor(hex: 0x008272))
    ]

    static func accent(_ value: UInt32) -> NSColor {
        accents.first(where: { $0.value == value })?.color ?? accents[0].color
    }

    static func logo(in rect: NSRect, color: NSColor = .white, gapFraction: CGFloat = 0.08, minGap: CGFloat = 1, cornerRadius: CGFloat = 0) {
        color.setFill()
        let gap = max(minGap, rect.width * gapFraction)
        let w = (rect.width - gap) / 2
        let h = (rect.height - gap) / 2
        for row in 0..<2 {
            for col in 0..<2 {
                let pane = NSRect(x: rect.minX + CGFloat(col) * (w + gap),
                                  y: rect.minY + CGFloat(row) * (h + gap), width: w, height: h)
                if cornerRadius == 0 { pane.fill() }
                else { NSBezierPath(roundedRect: pane, xRadius: cornerRadius, yRadius: cornerRadius).fill() }
            }
        }
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .symbolTinted([.white])
    }
}

/// Use the same rectangles for drawing and hit targets; optional tray rows yield to the clock.
struct Win8TrayLayout {
    var input = NSRect.zero
    var clock = NSRect.zero
    var flag = NSRect.zero
    var desktop = NSRect.zero

    init(bounds: NSRect, vertical: Bool, showInput: Bool, showClock: Bool,
         showDesktop: Bool, clockWidth: CGFloat, config c: TrayStyle.Win8) {
        if vertical {
            let desktopHeight = showDesktop ? min(c.desktop, bounds.height) : 0
            let available = max(0, bounds.height - desktopHeight - c.verticalInset)
            let clockHeight: CGFloat = showClock ? c.clockVerticalHeight : 0
            if showInput {
                // The language cell is mandatory. Reserve it first, then drop
                // the optional flag and shrink the clock as space runs out.
                let inputHeight = min(c.inputHeight, max(1, available))
                let remaining = max(0, available - inputHeight)
                let includeFlag = remaining >= c.actionHeight + clockHeight
                let flagHeight = includeFlag ? c.actionHeight : 0
                let actualClockHeight = min(clockHeight, max(0, remaining - flagHeight))
                var y = max(0, bounds.height - desktopHeight - inputHeight - actualClockHeight - flagHeight - c.trailing)
                input = NSRect(x: c.trailing, y: y, width: max(1, bounds.width - c.verticalInset), height: inputHeight)
                y += inputHeight
                if actualClockHeight > 0 {
                    clock = NSRect(x: c.trailing, y: y, width: max(0, bounds.width - c.verticalInset), height: actualClockHeight)
                    y += actualClockHeight
                }
                if includeFlag {
                    flag = NSRect(x: c.trailing, y: y, width: max(0, bounds.width - c.verticalInset), height: flagHeight)
                }
                if showDesktop {
                    desktop = NSRect(x: 0, y: bounds.height - desktopHeight, width: bounds.width, height: desktopHeight)
                }
                return
            }
            var includeFlag = true
            var includeInput = showInput
            if clockHeight + c.actionHeight + (includeInput ? c.inputHeight : 0) > available { includeFlag = false }
            if clockHeight + (includeFlag ? c.actionHeight : 0) + (includeInput ? c.inputHeight : 0) > available { includeInput = false }
            let actualClockHeight = min(clockHeight, available)
            let total = actualClockHeight + (includeInput ? c.inputHeight : 0) + (includeFlag ? c.actionHeight : 0)
            var y = max(0, bounds.height - desktopHeight - total - c.trailing)
            if includeInput {
                input = NSRect(x: c.trailing, y: y, width: max(0, bounds.width - c.verticalInset), height: c.inputHeight)
                y += c.inputHeight
            }
            if actualClockHeight > 0 {
                clock = NSRect(x: c.trailing, y: y, width: max(0, bounds.width - c.verticalInset), height: actualClockHeight)
                y += actualClockHeight
            }
            if includeFlag {
                flag = NSRect(x: c.trailing, y: y, width: max(0, bounds.width - c.verticalInset), height: c.actionHeight)
            }
            if showDesktop {
                desktop = NSRect(x: 0, y: bounds.height - desktopHeight, width: bounds.width, height: desktopHeight)
            }
        } else {
            let desktopWidth = showDesktop ? min(c.desktop, bounds.width) : 0
            let available = max(0, bounds.width - desktopWidth - c.horizontalInset)
            let preferredClockWidth = showClock ? max(c.clockMinWidth, clockWidth + c.clockExtraWidth) : 0
            if showInput {
                // Keep the language cell visible even when the clock and flag
                // cannot both fit in the available notification area.
                let inputWidth = min(c.inputWidth, max(1, available))
                let remaining = max(0, available - inputWidth)
                let includeFlag = remaining >= c.actionWidth + preferredClockWidth
                let flagWidth = includeFlag ? c.actionWidth : 0
                let actualClockWidth = showClock ? max(0, remaining - flagWidth) : 0
                var x = c.leading
                input = NSRect(x: x, y: 0, width: inputWidth, height: bounds.height)
                x += inputWidth
                if actualClockWidth > 0 {
                    clock = NSRect(x: x, y: max(0, (bounds.height - c.clockHeight) / 2),
                                   width: actualClockWidth, height: min(c.clockHeight, bounds.height))
                    x += actualClockWidth
                }
                if includeFlag {
                    flag = NSRect(x: x, y: 0, width: c.actionWidth, height: bounds.height)
                }
                if showDesktop {
                    desktop = NSRect(x: bounds.width - desktopWidth, y: 0, width: desktopWidth, height: bounds.height)
                }
                return
            }
            var includeFlag = true
            var includeInput = showInput
            if preferredClockWidth + c.actionWidth + (includeInput ? c.inputWidth : 0) > available { includeFlag = false }
            if preferredClockWidth + (includeFlag ? c.actionWidth : 0) + (includeInput ? c.inputWidth : 0) > available { includeInput = false }
            var x = c.leading
            if includeInput {
                input = NSRect(x: x, y: 0, width: c.inputWidth, height: bounds.height)
                x += c.inputWidth
            }
            if showClock {
                let width = max(0, available - (includeInput ? c.inputWidth : 0) - (includeFlag ? c.actionWidth : 0))
                clock = NSRect(x: x, y: max(0, (bounds.height - c.clockHeight) / 2),
                               width: width, height: min(c.clockHeight, bounds.height))
                x += width
            }
            if includeFlag {
                flag = NSRect(x: x, y: 0, width: c.actionWidth, height: bounds.height)
            }
            if showDesktop {
                desktop = NSRect(x: bounds.width - desktopWidth, y: 0, width: desktopWidth, height: bounds.height)
            }
        }
    }
}

@MainActor
final class Win8StartPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Win8StartScreenView: NSView, NSSearchFieldDelegate {
    struct Application {
        let url: URL
        let name: String
        let icon: NSImage
        let originalIndex: Int?
        /// Web App Collection description, shown as a tooltip.
        let detail: String?
        /// Set for a row that comes from a collection.
        let collectionItem: CollectionItem?

        var listEntry: AppListEntry { collectionItem.map(AppListEntry.collectionItem) ?? .app(url) }

        init(url: URL, name: String, icon: NSImage, originalIndex: Int? = nil, detail: String? = nil, collectionItem: CollectionItem? = nil) {
            self.url = url
            self.name = name
            self.icon = icon
            self.originalIndex = originalIndex
            self.detail = detail
            self.collectionItem = collectionItem
        }
    }

    private let settings: TaskbarSettings
    let coversTaskbar: Bool
    private var applications: [Application]
    private var webFolders: [CollectionFolder]
    private var webItems: [CollectionItem]
    private let search = NSSearchField()
    private let scroll = Win8HorizontalScrollView()
    private let document = Win8DocumentView()
    private let power = Win8GlyphButton()
    private let modeButton = Win8GlyphButton()
    private let startButton = Win8GlyphButton()
    private let debugColumnMajorPacker: Bool
    private var allApps: Bool
    private var searching: Bool
    private var query: String
    private var contentSize = NSSize.zero
    private var visibleForAnimations = false
    private var flipTimers: [Timer] = []
    private var scrollSettleTimer: Timer?
    private var isScrolling = false
    private var suppressScrollBounds = false
    private var random = Win8SeededRandom()
    private let layoutStore = Win8LayoutStore()
    private var packCallCount = 0
    // A drag works against a materialized layout. This keeps the legacy
    // placement intact until a drop actually commits the order.
    private var workingLayoutEntries: [Win8LayoutEntry]?
    private var drag: DragState?
    private var debugLastRelayout: [(Win8AppTile, NSRect, NSRect)] = []
    var reduceMotionOverride: Bool?
    private(set) var isShowingPowerMenu = false
    var taskbarStartRect: NSRect? { didSet { needsLayout = true } }
    var onLaunch: ((AppListEntry) -> Void)?
    var onCommand: ((StartItem) -> Void)?
    var onClose: (() -> Void)?

    private struct DragState {
        struct Candidate {
            let index: Int
            let order: [Application]
            let packed: [PackedTile]
            let slot: NSRect
        }

        let key: String
        let originalOrder: [Application]
        let sourceIndex: Int
        var targetIndex: Int
        let pointerOffset: NSPoint
        var previewOrder: [Application]
        var previewPacked: [PackedTile]
        var candidates: [Candidate]
        var layoutEntries: [Win8LayoutEntry]
        weak var draggedTile: Win8AppTile?
    }

    init(settings: TaskbarSettings, coversTaskbar: Bool, allApps: Bool = false, searchText: String = "",
         debugColumnMajorPacker: Bool? = nil) {
        self.settings = settings
        self.coversTaskbar = coversTaskbar
        self.debugColumnMajorPacker = debugColumnMajorPacker ?? Win8TileAnimation.debugColumnMajorPacker
        self.applications = Self.loadApplications()
        self.webFolders = AppCollections.folders(settings: settings)
        self.webItems = AppCollections.rootItems(settings: settings)
        self.allApps = allApps
        self.query = searchText
        self.searching = !searchText.isEmpty
        super.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: PinStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: HiddenStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: AppCatalog.didChange, object: nil)
        wantsLayer = true
        search.placeholderString = L.t("Search apps", settings.resolvedLanguage)
        search.font = .systemFont(ofSize: 16)
        search.bezelStyle = .squareBezel
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.isHidden = !searching
        search.stringValue = searchText
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        addSubview(search)

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.onFolderMenu = { [weak self] folder in
            self.map { AppPinMenu.shared.menu(entry: .collectionFolder(folder), settings: $0.settings) }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.onScroll = { [weak self] in self?.beginScrollInteraction() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        document.wantsLayer = true
        document.clipsToBounds = true
        document.layer?.masksToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.masksToBounds = true
        addSubview(scroll)

        power.symbol = "power"
        power.toolTip = L.t("Power", settings.resolvedLanguage)
        power.setAccessibilityLabel(L.t("Power", settings.resolvedLanguage))
        power.onClick = { [weak self] in self?.showPowerMenu() }
        addSubview(power)
        modeButton.onClick = { [weak self] in self?.toggleMode() }
        addSubview(modeButton)
        startButton.drawsLogo = true
        startButton.toolTip = L.t("Start", settings.resolvedLanguage)
        startButton.setAccessibilityLabel(L.t("Start", settings.resolvedLanguage))
        startButton.onClick = { [weak self] in self?.onClose?() }
        startButton.isHidden = true
        addSubview(startButton)
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        scrollSettleTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func focusSearch() {
        if !searching { window?.makeFirstResponder(self) }
        else { window?.makeFirstResponder(search) }
    }
    func controlTextDidChange(_ obj: Notification) { updateSearch() }
    @objc private func pinsChanged() { rebuild() }
    @objc private func hiddenEntriesChanged() {
        applications = Self.loadApplications()
        webFolders = AppCollections.folders(settings: settings)
        webItems = AppCollections.rootItems(settings: settings)
        rebuild()
    }
    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        guard !suppressScrollBounds else { return }
        beginScrollInteraction()
    }
    @objc private func searchChanged() {
        updateSearch()
        if NSApp.currentEvent?.keyCode == 36, let app = filtered.first { onLaunch?(app.listEntry) }
    }

    private func updateSearch() {
        query = search.stringValue
        searching = true
        rebuild(animated: true)
        needsDisplay = true
    }

    private var filtered: [Application] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.isEmpty else {
            return (applications + (webItems + webFolders.flatMap(\.items)).map(Self.application(collectionItem:)))
                .filter { $0.name.localizedStandardContains(q) }
        }
        // The Apps view sorts first-level collection items in with the apps; the Start tiles stay apps only.
        guard allApps, !webItems.isEmpty else { return applications }
        return (applications + webItems.map(Self.application(collectionItem:)))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func application(collectionItem item: CollectionItem) -> Application {
        Application(url: item.url, name: item.name, icon: item.icon, detail: item.detail, collectionItem: item)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if drag != nil { cancelDrag() }
            else { onClose?() }
            return
        }
        if routeSearchKey(event) { return }
        super.keyDown(with: event)
    }

    /// Forward the first printable keystroke to AppKit's field editor, including input-method handling.
    func routeSearchKey(_ event: NSEvent) -> Bool {
        guard !isShowingPowerMenu,
              !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 32 && !($0.value >= 0xF700 && $0.value <= 0xF8FF) }),
              window?.firstResponder !== search.currentEditor() else { return false }
        searching = true
        search.isHidden = false
        needsDisplay = true
        window?.makeFirstResponder(search)
        search.currentEditor()?.keyDown(with: event)
        return true
    }

    private func toggleMode() {
        allApps = searching ? false : !allApps
        searching = false
        query = ""
        search.stringValue = ""
        layoutContent()
        rebuild(animated: true)
        window?.makeFirstResponder(self)
    }

    private func showPowerMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in [StartItem.run, .settings, .shutDown] {
            let item = NSMenuItem(title: L.t(command.titleKey, settings.resolvedLanguage),
                                 action: #selector(commandSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        isShowingPowerMenu = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: power.bounds.maxY), in: power)
        isShowingPowerMenu = false
    }

    @objc private func commandSelected(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StartItem else { return }
        onCommand?(item)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        search.frame = NSRect(x: 48, y: 96, width: min(430, max(0, bounds.width - 96)), height: 34)
        search.isHidden = !searching
        power.frame = NSRect(x: max(0, bounds.width - 80), y: 32, width: 40, height: 40)
        modeButton.frame = NSRect(x: 34, y: max(0, bounds.height - 76), width: 48, height: 48)
        modeButton.symbol = allApps || searching ? "arrow.up.circle" : "arrow.down.circle"
        modeButton.symbolSize = 28
        modeButton.toolTip = L.t(allApps || searching ? "Start" : "Apps", settings.resolvedLanguage)
        modeButton.setAccessibilityLabel(modeButton.toolTip ?? "")
        if coversTaskbar, let rect = taskbarStartRect {
            startButton.frame = rect
            startButton.isHidden = false
        }
        scroll.frame = NSRect(x: 48, y: 160, width: max(0, bounds.width - 96),
                              height: max(0, bounds.height - 260))
        if contentSize != scroll.contentSize {
            contentSize = scroll.contentSize
            rebuild()
        }
        needsDisplay = true
    }

    private func rebuild(animated: Bool = false) {
        let wasVisible = visibleForAnimations
        stopAnimations(resetTiles: true)
        document.subviews.forEach { $0.removeFromSuperview() }
        document.headings = []
        document.folderHeadings = []
        if allApps || searching {
            buildApps(filtered, searchResults: searching)
        } else {
            let pins = PinStore().startApps
            let base = pins.isEmpty ? applications : pins.map { pin in
                applications.first { PinnedApp(url: $0.url).matches(pin) } ??
                    Application(url: pin.url, name: pin.url.deletingPathExtension().lastPathComponent,
                                icon: AppIconCache.shared.icon(for: pin.url))
            }
            let indexedBase = base.enumerated().map { index, app in
                Application(url: app.url, name: app.name, icon: app.icon, originalIndex: index)
            }
            let selected = orderedForLayout(indexedBase)
            buildTiles(selected)
        }
        if filtered.isEmpty {
            document.headings = [(L.t(AppCatalog.shared.isReady ? "No apps found" : "Loading…", settings.resolvedLanguage),
                                  NSRect(x: 0, y: 12, width: 360, height: 28))]
        }
        document.needsDisplay = true
        setScrollOrigin(.zero, notify: false)
        if wasVisible {
            visibleForAnimations = true
            if animated { animateContentTransition() }
            scheduleLiveTiles()
        }
    }

    private func addApp(_ app: Application, in rect: NSRect, color: NSColor?) {
        let tile = Win8AppTile(application: app, color: color)
        tile.allowsDrag = !allApps && !searching
        tile.frame = rect
        tile.onClick = { [weak self] in self?.onLaunch?(app.listEntry) }
        tile.onMenu = { [weak self] in
            guard let self else { return nil }
            let listed = self.allApps || self.searching
            let menu = AppPinMenu.shared.menu(entry: app.listEntry, settings: self.settings, includeHide: listed)
            if !listed { self.addResizeMenu(to: menu, tile: tile) }
            return menu
        }
        tile.onDragBegin = { [weak self, weak tile] point in self?.beginDrag(tile: tile, point: point) }
        tile.onDragMove = { [weak self, weak tile] point in self?.moveDrag(tile: tile, point: point) }
        tile.onDragEnd = { [weak self, weak tile] point in self?.endDrag(tile: tile, point: point) }
        tile.onDragCancel = { [weak self] in self?.cancelDrag() }
        document.addSubview(tile)
    }

    private func buildTiles(_ apps: [Application]) {
        let colors = [0x2672EC, 0x00A600, 0xDC572E, 0xE51400, 0xA200FF, 0x00ABA9].map { NSColor(hex: UInt32($0)) }
        let packed = packedRects(for: apps)
        for (index, item) in packed.enumerated() {
            let originalIndex = item.app.originalIndex ?? index
            addApp(item.app, in: item.rect, color: colors[originalIndex % colors.count])
            if let tile = document.subviews.last as? Win8AppTile {
                tile.entranceColumn = item.entranceColumn
                tile.liveTile = item.size != .small
                tile.isWideTile = item.size == .wide || item.size == .large
                tile.tileSize = item.size
            }
        }
        let lastX = packed.map(\.rect.maxX).max() ?? 0
        let rows = max(4, Int((max(150, contentSize.height - 20) + 10) / 80))
        document.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, lastX + 12),
                                height: max(max(contentSize.height, CGFloat(rows) * 80), 150))
    }

    private static func defaultTileSize(_ index: Int) -> Win8TileSize {
        switch index % 8 {
        case 0, 3, 6: return .medium
        case 1, 5: return .wide
        default: return .small
        }
    }

    private func addResizeMenu(to menu: NSMenu, tile: Win8AppTile) {
        let resize = NSMenuItem(title: L.t("Resize", settings.resolvedLanguage), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for size in Win8TileSize.allCases {
            let item = NSMenuItem(title: L.t(size.rawValue.capitalized, settings.resolvedLanguage),
                                  action: #selector(resizeTile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size.menuTag
            item.representedObject = tile
            item.state = tile.tileSize == size ? .on : .off
            submenu.addItem(item)
        }
        resize.submenu = submenu
        menu.addItem(resize)
    }

    @objc private func resizeTile(_ sender: NSMenuItem) {
        guard let tile = sender.representedObject as? Win8AppTile,
              let size = Win8TileSize(menuTag: sender.tag) else { return }
        let currentOrder = document.subviews.compactMap { ($0 as? Win8AppTile)?.application }
            .map { PinnedApp(url: $0.url) }
        layoutStore.setOrder(currentOrder)
        layoutStore.setSize(size, for: PinnedApp(url: tile.application.url))
        relayoutInPlace(animated: true)
    }

    private struct PackedTile {
        let app: Application
        let rect: NSRect
        let size: Win8TileSize
        let entranceColumn: Int
    }

    private func legacyPackedRects(for apps: [Application]) -> [PackedTile] {
        let rows = max(4, Int((max(150, contentSize.height - 20) + 10) / 80))
        let columns = 4
        var occupied = Array(repeating: Array(repeating: false, count: rows), count: columns)
        var group = 0
        var result: [PackedTile] = []
        for (index, app) in apps.enumerated() {
            let originalIndex = app.originalIndex ?? index
            let tileSize = layoutStore.size(for: PinnedApp(url: app.url)) ?? Self.defaultTileSize(originalIndex)
            let dimensions = tileSize.dimensions
            var position: (Int, Int)?
            while position == nil {
                for column in 0...(columns - dimensions.width) {
                    for row in 0...(rows - dimensions.height) {
                        let free = (column..<(column + dimensions.width)).allSatisfy { c in
                            (row..<(row + dimensions.height)).allSatisfy { !occupied[c][$0] }
                        }
                        if free { position = (column, row); break }
                    }
                    if position != nil { break }
                }
                if position == nil {
                    group += 1
                    occupied = Array(repeating: Array(repeating: false, count: rows), count: columns)
                }
            }
            guard let (column, row) = position else { continue }
            for c in column..<(column + dimensions.width) {
                for r in row..<(row + dimensions.height) { occupied[c][r] = true }
            }
            let rect = NSRect(x: CGFloat(group) * 360 + CGFloat(column) * 80, y: CGFloat(row) * 80,
                              width: CGFloat(dimensions.width) * 80 - 10,
                              height: CGFloat(dimensions.height) * 80 - 10)
            result.append(PackedTile(app: app, rect: rect, size: tileSize,
                                     entranceColumn: group * columns + column))
        }
        assertPackedRects(result)
        return result
    }

    private func packedRects(for apps: [Application]) -> [PackedTile] {
        let entries = workingLayoutEntries ?? layoutStore.entries
        if entries.isEmpty { return legacyPackedRects(for: apps) }
        return packedRects(for: apps, entries: entries)
    }

    /// The one custom packer used by relayout, drag previews, and drop commits.
    private func packedRects(for apps: [Application], entries: [Win8LayoutEntry]) -> [PackedTile] {
        packedRects(for: apps, entries: entries, columnMajor: debugColumnMajorPacker)
    }

    /// The custom packer is shared by relayout, drag preview, and drop commit.
    /// The column-first mode is only exposed for the edit-snapshot regression image.
    private func packedRects(for apps: [Application], entries: [Win8LayoutEntry], columnMajor: Bool) -> [PackedTile] {
        packCallCount += 1
        let rows = max(4, Int((max(150, contentSize.height - 20) + 10) / 80))
        let columns = 4
        var occupied = Array(repeating: Array(repeating: false, count: rows), count: columns)
        var group = 0
        var result: [PackedTile] = []
        var smallBlock: (group: Int, column: Int, row: Int, quarter: Int)?

        func findFree(width: Int, height: Int) -> (Int, Int)? {
            let columnRange = 0...(columns - width)
            let rowRange = 0...(rows - height)
            let outer = columnMajor ? columnRange : rowRange
            let inner = columnMajor ? rowRange : columnRange
            for first in outer {
                for second in inner {
                    let column = columnMajor ? first : second
                    let row = columnMajor ? second : first
                    let free = (column..<(column + width)).allSatisfy { c in
                        (row..<(row + height)).allSatisfy { !occupied[c][$0] }
                    }
                    if free { return (column, row) }
                }
            }
            return nil
        }

        for (index, app) in apps.enumerated() {
            let originalIndex = app.originalIndex ?? index
            let tileSize = entries.first { $0.key == PinnedApp(url: app.url).identityKey }
                .flatMap { $0.size }.flatMap(Win8TileSize.init(rawValue:)) ?? Self.defaultTileSize(originalIndex)
            let dimensions = tileSize.dimensions
            if tileSize == .small {
                if let block = smallBlock, block.quarter < 4 {
                    let quarter = block.quarter
                    smallBlock = (block.group, block.column, block.row, quarter + 1)
                    let column = block.column + (quarter % 2)
                    let row = block.row + (quarter / 2)
                    result.append(PackedTile(app: app,
                                              rect: NSRect(x: CGFloat(block.group) * 360 + CGFloat(column) * 80,
                                                           y: CGFloat(row) * 80, width: 70, height: 70),
                                              size: tileSize,
                                              entranceColumn: block.group * columns + column))
                    continue
                }
                smallBlock = nil
                while true {
                    if let (column, row) = findFree(width: 2, height: 2) {
                        for c in column..<(column + 2) {
                            for r in row..<(row + 2) { occupied[c][r] = true }
                        }
                        smallBlock = (group, column, row, 1)
                        result.append(PackedTile(app: app,
                                                  rect: NSRect(x: CGFloat(group) * 360 + CGFloat(column) * 80,
                                                               y: CGFloat(row) * 80, width: 70, height: 70),
                                                  size: tileSize,
                                                  entranceColumn: group * columns + column))
                        break
                    }
                    group += 1
                    occupied = Array(repeating: Array(repeating: false, count: rows), count: columns)
                }
                continue
            }
            var position = findFree(width: dimensions.width, height: dimensions.height)
            while position == nil {
                group += 1
                occupied = Array(repeating: Array(repeating: false, count: rows), count: columns)
                position = findFree(width: dimensions.width, height: dimensions.height)
            }
            guard let (column, row) = position else { continue }
            for c in column..<(column + dimensions.width) {
                for r in row..<(row + dimensions.height) { occupied[c][r] = true }
            }
            let rect = NSRect(x: CGFloat(group) * 360 + CGFloat(column) * 80, y: CGFloat(row) * 80,
                              width: CGFloat(dimensions.width) * 80 - 10,
                              height: CGFloat(dimensions.height) * 80 - 10)
            result.append(PackedTile(app: app, rect: rect, size: tileSize,
                                     entranceColumn: group * columns + column))
        }
        assertPackedRects(result)
        return result
    }

    private func assertPackedRects(_ packed: [PackedTile]) {
        for i in packed.indices {
            guard !packed[i].rect.isEmpty else { continue }
            assert(packed[i].rect.minX >= 0 && packed[i].rect.minY >= 0)
            for j in packed.indices where j > i {
                guard !packed[j].rect.isEmpty else { continue }
                assert(!packed[i].rect.intersects(packed[j].rect),
                       "Win8 packed tiles overlap: \(packed[i].app.name) \(packed[i].rect) and \(packed[j].app.name) \(packed[j].rect)")
            }
        }
    }

    private func relayoutInPlace(animated: Bool) {
        guard !allApps, !searching else { return }
        let tiles = document.subviews.compactMap { $0 as? Win8AppTile }
        let apps = orderedForLayout(tiles.map(\.application))
        let packed = packedRects(for: apps)
        let destinationByKey = Dictionary(firstWins: packed.map {
            (PinnedApp(url: $0.app.url).identityKey, ($0.rect, $0.size))
        })
        let oldOrigin = scroll.contentView.bounds.origin
        let oldFrames = Dictionary(firstWins: tiles.map { ($0.identityKey, $0.frame) })
        pauseLiveTiles()
        debugLastRelayout = tiles.compactMap { tile in
            guard let destination = destinationByKey[tile.identityKey] else { return nil }
            return (tile, oldFrames[tile.identityKey] ?? tile.frame, destination.0)
        }
        for tile in tiles {
            if let destination = destinationByKey[tile.identityKey] {
                tile.tileSize = destination.1
                tile.liveTile = destination.1 != .small
                tile.isWideTile = destination.1 == .wide || destination.1 == .large
            }
        }
        let maxX = packed.map(\.rect.maxX).max() ?? 0
        let rows = max(4, Int((max(150, contentSize.height - 20) + 10) / 80))
        document.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, maxX + 12),
                                height: max(max(contentSize.height, CGFloat(rows) * 80), 150))
        let maxScrollX = max(0, document.bounds.width - scroll.contentView.bounds.width)
        let clampedOrigin = NSPoint(x: min(max(0, oldOrigin.x), maxScrollX), y: 0)
        setScrollOrigin(clampedOrigin, notify: false)
        if animated && shouldAnimate && !isScrolling {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (tile, _, destination) in debugLastRelayout { tile.animator().frame = destination }
            }
        } else {
            for (tile, _, destination) in debugLastRelayout { tile.frame = destination }
        }
        if drag == nil { scheduleLiveTiles() }
    }

    private func pauseLiveTiles() {
        flipTimers.forEach { $0.invalidate() }
        flipTimers.removeAll()
        document.subviews.compactMap { $0 as? Win8AppTile }.forEach { $0.resetFront() }
    }

    private func finishPendingReflow() {
        guard !debugLastRelayout.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (tile, _, destination) in debugLastRelayout {
            tile.layer?.removeAllAnimations()
            tile.frame = destination
        }
        CATransaction.commit()
    }

    private func beginScrollInteraction() {
        scrollSettleTimer?.invalidate()
        if !isScrolling {
            isScrolling = true
            if drag != nil { cancelDrag() }
            finishPendingReflow()
            pauseLiveTiles()
        }
        scrollSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.endScrollInteraction() }
        }
    }

    private func endScrollInteraction() {
        scrollSettleTimer?.invalidate()
        scrollSettleTimer = nil
        finishPendingReflow()
        pauseLiveTiles()
        isScrolling = false
        scheduleLiveTiles()
    }

    private func setScrollOrigin(_ origin: NSPoint, notify: Bool = true) {
        if notify { beginScrollInteraction() }
        suppressScrollBounds = true
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        suppressScrollBounds = false
    }

    private func beginDrag(tile: Win8AppTile?, point: NSPoint) {
        guard !allApps, !searching, drag == nil, let tile else { return }
        let tiles = document.subviews.compactMap { $0 as? Win8AppTile }
        let current = orderedForLayout(tiles.map(\.application))
        let tilesByKey = Dictionary(firstWins: tiles.map { ($0.identityKey, $0) })
        let orderedTiles = current.compactMap { tilesByKey[PinnedApp(url: $0.url).identityKey] }
        guard let sourceIndex = current.firstIndex(where: { PinnedApp(url: $0.url).identityKey == tile.identityKey }) else { return }
        // Materialize the visible order and sizes before the first preview. This
        // switches an uncustomized layout to the custom packer in memory only.
        workingLayoutEntries = orderedTiles.map { Win8LayoutEntry(key: $0.identityKey, size: $0.tileSize.rawValue) }
        let candidates = makeDragCandidates(originalOrder: current, sourceIndex: sourceIndex)
        guard let initial = candidates.first(where: { $0.index == sourceIndex }) else { return }
        drag = DragState(key: tile.identityKey, originalOrder: current, sourceIndex: sourceIndex,
                         targetIndex: sourceIndex,
                         pointerOffset: NSPoint(x: point.x - tile.frame.minX, y: point.y - tile.frame.minY),
                         previewOrder: initial.order,
                         previewPacked: initial.packed,
                         candidates: candidates,
                         layoutEntries: workingLayoutEntries ?? [],
                         draggedTile: tile)
        pauseLiveTiles()
        relayoutInPlace(animated: false)
        document.addSubview(tile, positioned: .above, relativeTo: nil)
        tile.setDragging(true)
        tile.layer?.zPosition = 100
        applyDragLayout(pointer: point, animated: false)
    }

    private func makeDragCandidates(originalOrder: [Application], sourceIndex: Int) -> [DragState.Candidate] {
        let remaining = originalOrder.enumerated().compactMap { index, app in index == sourceIndex ? nil : app }
        let moved = originalOrder[sourceIndex]
        return (0...remaining.count).compactMap { index in
            var order = remaining
            order.insert(moved, at: index)
            let packed = packedRects(for: order)
            guard let slot = packed.first(where: { $0.app.url == moved.url })?.rect else { return nil }
            return DragState.Candidate(index: index, order: order, packed: packed, slot: slot)
        }
    }

    private func moveDrag(tile: Win8AppTile?, point: NSPoint) {
        guard let tile, drag?.key == tile.identityKey else { return }
        applyDragLayout(pointer: point, animated: true)
    }

    private func endDrag(tile: Win8AppTile?, point: NSPoint) {
        guard let tile, let state = drag, state.key == tile.identityKey else { return }
        let inside = document.bounds.contains(point)
        if inside {
            let order = state.previewOrder
            let sizes = Dictionary(firstWins: (workingLayoutEntries ?? []).compactMap { entry in
                entry.size.map { (entry.key, $0) }
            })
            let committed = order.map {
                Win8LayoutEntry(key: PinnedApp(url: $0.url).identityKey,
                                size: sizes[PinnedApp(url: $0.url).identityKey])
            }
            let keys = Set(committed.map(\.key))
            layoutStore.entries = committed + layoutStore.entries.filter { !keys.contains($0.key) }
            let tilesByKey: [String: Win8AppTile] = Dictionary(firstWins: document.subviews.compactMap { view in
                guard let tile = view as? Win8AppTile else { return nil }
                return (tile.identityKey, tile)
            })
            tilesByKey.values.forEach { $0.removeFromSuperview() }
            for app in order.reversed() {
                if let tile = tilesByKey[PinnedApp(url: app.url).identityKey] {
                    document.addSubview(tile)
                }
            }
        }
        tile.setDragging(false)
        tile.layer?.zPosition = 0
        document.dragGapFrame = nil
        drag = nil
        workingLayoutEntries = nil
        if inside { relayoutInPlace(animated: false) }
        else { rebuild(animated: false) }
    }

    private func cancelDrag() {
        guard let state = drag else { return }
        let tiles = document.subviews.compactMap { $0 as? Win8AppTile }
        let tile = tiles.first { $0.identityKey == state.key }
        tile?.setDragging(false)
        tile?.layer?.zPosition = 0
        document.dragGapFrame = nil
        let tilesByKey = Dictionary(firstWins: tiles.map { ($0.identityKey, $0) })
        tiles.forEach { $0.removeFromSuperview() }
        for app in state.originalOrder {
            if let tile = tilesByKey[PinnedApp(url: app.url).identityKey] { document.addSubview(tile) }
        }
        drag = nil
        workingLayoutEntries = nil
        relayoutInPlace(animated: false)
    }

    private func applyDragLayout(pointer: NSPoint, animated: Bool) {
        guard var state = drag else { return }
        let currentEntries = workingLayoutEntries ?? []
        if state.layoutEntries != currentEntries {
            state.candidates = makeDragCandidates(originalOrder: state.originalOrder, sourceIndex: state.sourceIndex)
            state.layoutEntries = currentEntries
        }
        guard let best = state.candidates.min(by: {
            hypot($0.slot.midX - pointer.x, $0.slot.midY - pointer.y) <
                hypot($1.slot.midX - pointer.x, $1.slot.midY - pointer.y)
        }), let current = state.candidates.first(where: { $0.index == state.targetIndex }) else { return }
        let bestDistance = hypot(best.slot.midX - pointer.x, best.slot.midY - pointer.y)
        let currentDistance = hypot(current.slot.midX - pointer.x, current.slot.midY - pointer.y)
        let chosen: DragState.Candidate
        if best.index == current.index || best.slot.contains(pointer) || bestDistance + 12 < currentDistance {
            chosen = best
        } else {
            chosen = current
        }
        let origin = NSPoint(x: pointer.x - state.pointerOffset.x, y: pointer.y - state.pointerOffset.y)
        state.previewOrder = chosen.order
        state.previewPacked = chosen.packed
        if chosen.index == state.targetIndex {
            state.draggedTile?.frame.origin = origin
            if document.dragGapFrame != chosen.slot { document.dragGapFrame = chosen.slot }
            drag = state
            return
        }
        state.targetIndex = chosen.index
        drag = state
        if document.dragGapFrame != chosen.slot { document.dragGapFrame = chosen.slot }
        let destinationByKey = Dictionary(firstWins: chosen.packed.map {
            (PinnedApp(url: $0.app.url).identityKey, $0.rect)
        })
        let update = { state.draggedTile?.frame.origin = origin }
        if animated && shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for view in self.document.subviews.compactMap({ $0 as? Win8AppTile }) where view.identityKey != state.key {
                    if let destination = destinationByKey[view.identityKey] { view.animator().frame = destination }
                }
            }
            update()
        } else {
            for view in document.subviews.compactMap({ $0 as? Win8AppTile }) where view.identityKey != state.key {
                if let destination = destinationByKey[view.identityKey] {
                    view.frame = destination
                }
            }
            update()
        }
    }

    private func orderedForLayout(_ apps: [Application]) -> [Application] {
        let entries = workingLayoutEntries ?? layoutStore.entries
        guard !entries.isEmpty else { return apps }
        var remaining = apps
        var ordered: [Application] = []
        for entry in entries {
            guard let index = remaining.firstIndex(where: { PinnedApp(url: $0.url).identityKey == entry.key }) else { continue }
            ordered.append(remaining.remove(at: index))
        }
        return ordered + remaining
    }

    private func buildApps(_ apps: [Application], searchResults: Bool) {
        var x: CGFloat = 0, y: CGFloat = 0
        let columnWidth: CGFloat = 260
        let height = max(120, contentSize.height - 16)
        var lastLetter = ""
        for app in apps {
            let letter = String(app.name.prefix(1)).uppercased()
            let needsHeading = !searchResults && letter != lastLetter
            if y + (needsHeading ? 68 : 38) > height {
                x += columnWidth
                y = 0
                if !searchResults { lastLetter = "" }
            }
            if !searchResults && letter != lastLetter {
                document.headings.append((letter, NSRect(x: x, y: y, width: 240, height: 26)))
                y += 30
                lastLetter = letter
            }
            addApp(app, in: NSRect(x: x, y: y, width: 240, height: 34), color: nil)
            y += 38
        }
        // The Apps view ends with one headed column group per collection folder.
        for folder in searchResults ? [] : webFolders {
            if y > 0 { x += columnWidth; y = 0 }
            document.headings.append((folder.name, NSRect(x: x, y: y, width: 240, height: 26)))
            document.folderHeadings.append((folder, NSRect(x: x, y: y, width: 240, height: 26)))
            y += 30
            for app in folder.items {
                if y + 38 > height { x += columnWidth; y = 0 }
                addApp(Self.application(collectionItem: app), in: NSRect(x: x, y: y, width: 240, height: 34), color: nil)
                y += 38
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, x + 260),
                                height: max(contentSize.height, height))
    }

    private var shouldAnimate: Bool { !(reduceMotionOverride ?? Win8TileAnimation.reduceMotion) && !Win8TileAnimation.snapshotMode }

    func beginVisibleAnimations() {
        visibleForAnimations = true
        random = Win8SeededRandom()
        if shouldAnimate {
            animateEntrance()
        }
        scheduleLiveTiles()
    }

    func stopAnimations(resetTiles: Bool = true) {
        visibleForAnimations = false
        flipTimers.forEach { $0.invalidate() }
        flipTimers.removeAll()
        document.layer?.removeAllAnimations()
        document.subviews.compactMap { $0 as? Win8AppTile }.forEach {
            $0.layer?.removeAllAnimations()
            if resetTiles { $0.resetFront() }
        }
    }

    var debugFlipTimerCount: Int { flipTimers.count }
    fileprivate var debugPackCallCount: Int { packCallCount }
    var debugAnimationCount: Int {
        document.subviews.reduce(0) { total, view in
            let tileCount = (view as? Win8AppTile)?.debugAnimationCount ?? 0
            return total + (view.layer?.animationKeys()?.count ?? 0) + tileCount
        }
    }

    private func animateEntrance() {
        for tile in document.subviews.compactMap({ $0 as? Win8AppTile }) {
            tile.animateEntrance(delay: CFTimeInterval(tile.entranceColumn) * Win8TileAnimation.entranceStagger)
        }
    }

    private func animateContentTransition() {
        guard shouldAnimate, let layer = document.layer else { return }
        let direction: CGFloat = allApps || searching ? 1 : -1
        let incoming = CATransition()
        incoming.type = .push
        incoming.subtype = direction > 0 ? .fromRight : .fromLeft
        incoming.duration = Win8TileAnimation.transitionDuration
        incoming.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(incoming, forKey: "win8-content-transition")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Win8TileAnimation.transitionDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "win8-content-fade")
    }

    private func scheduleLiveTiles() {
        guard visibleForAnimations, shouldAnimate, !isScrolling, drag == nil else { return }
        let tiles = document.subviews.compactMap { $0 as? Win8AppTile }.filter { $0.liveTile }
        for tile in tiles {
            schedule(tile: tile, delay: random.firstDelay())
        }
    }

    private func schedule(tile: Win8AppTile, delay: TimeInterval) {
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak tile] timer in
            Task { @MainActor [weak self, weak tile] in
                guard let self, let tile, self.visibleForAnimations, self.drag == nil else { return }
                self.flipTimers.removeAll { $0 === timer }
                self.runLiveCycle(tile: tile)
            }
        }
        flipTimers.append(timer)
    }

    private func runLiveCycle(tile: Win8AppTile) {
        guard visibleForAnimations, drag == nil else { return }
        tile.animateFlip(toBack: true) { [weak self, weak tile] in
            guard let self, let tile, self.visibleForAnimations, self.drag == nil else { return }
            let dwell = self.random.backDwell()
            let timer = Timer.scheduledTimer(withTimeInterval: dwell, repeats: false) { [weak self, weak tile] timer in
                Task { @MainActor [weak self, weak tile] in
                    guard let self, let tile, self.visibleForAnimations, self.drag == nil else { return }
                    self.flipTimers.removeAll { $0 === timer }
                    tile.animateFlip(toBack: false) { [weak self, weak tile] in
                        guard let self, let tile, self.visibleForAnimations, self.drag == nil else { return }
                        self.schedule(tile: tile, delay: self.random.delay())
                    }
                }
            }
            self.flipTimers.append(timer)
        }
    }

    func debugPrepareForFrames() {
        visibleForAnimations = true
        document.layoutSubtreeIfNeeded()
    }

    fileprivate func debugSetTransition(_ progress: CGFloat) {
        guard let layer = document.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = Float(0.2 + 0.8 * max(0, min(1, progress)))
        layer.setAffineTransform(CGAffineTransform(translationX: (1 - progress) * 40, y: 0))
        CATransaction.commit()
    }

    fileprivate func debugTiles() -> [Win8AppTile] {
        let tiles = document.subviews.compactMap { $0 as? Win8AppTile }
        let byKey = Dictionary(firstWins: tiles.map { ($0.identityKey, $0) })
        return orderedForLayout(tiles.map(\.application)).compactMap {
            byKey[PinnedApp(url: $0.url).identityKey]
        }
    }

    fileprivate var debugScrollOrigin: NSPoint { scroll.contentView.bounds.origin }
    fileprivate var debugDocumentOrigin: NSPoint { document.frame.origin }
    fileprivate var debugDocumentBounds: NSRect { document.bounds }
    fileprivate var debugTilesHaveIdentityTransforms: Bool {
        document.subviews.compactMap { $0 as? Win8AppTile }.allSatisfy {
            CATransform3DEqualToTransform($0.layer?.transform ?? CATransform3DIdentity, CATransform3DIdentity)
        }
    }
    fileprivate var debugTilesHaveNoAnimations: Bool {
        document.subviews.compactMap { $0 as? Win8AppTile }.allSatisfy {
            $0.debugAnimationCount == 0 && ($0.layer?.animationKeys()?.isEmpty ?? true)
        }
    }
    fileprivate var debugHasContentTransition: Bool {
        document.layer?.animation(forKey: "win8-content-transition") != nil
    }
    fileprivate var debugStationaryRelayoutTilesAreFixed: Bool {
        debugLastRelayout.allSatisfy { tile, from, to in
            from != to || tile.frame == from
        }
    }
    fileprivate var debugRelayoutHasChangedTile: Bool {
        debugLastRelayout.contains { $0.1 != $0.2 }
    }
    fileprivate func debugSetScrollOrigin(_ origin: NSPoint) {
        let limit = max(0, document.bounds.width - scroll.contentView.bounds.width)
        setScrollOrigin(NSPoint(x: min(max(0, origin.x), limit), y: 0))
        endScrollInteraction()
    }
    fileprivate func debugSettleScroll() {
        endScrollInteraction()
    }
    fileprivate func debugCommitDrop(sourceIndex: Int, targetIndex: Int) {
        let tiles = debugTiles()
        guard sourceIndex >= 0, sourceIndex < tiles.count else { return }
        let apps = tiles.map(\.application)
        workingLayoutEntries = tiles.map { Win8LayoutEntry(key: $0.identityKey, size: $0.tileSize.rawValue) }
        let moved = apps[sourceIndex]
        var order = apps.enumerated().compactMap { $0.offset == sourceIndex ? nil : $0.element }
        order.insert(moved, at: min(max(0, targetIndex), order.count))
        let candidates = makeDragCandidates(originalOrder: apps, sourceIndex: sourceIndex)
        let destinationIndex = min(max(0, targetIndex), apps.count - 1)
        let packed = candidates.first(where: { $0.index == destinationIndex })?.packed ?? packedRects(for: order)
        drag = DragState(key: tiles[sourceIndex].identityKey, originalOrder: apps,
                         sourceIndex: sourceIndex, targetIndex: destinationIndex, pointerOffset: .zero,
                         previewOrder: order, previewPacked: packed, candidates: candidates,
                         layoutEntries: workingLayoutEntries ?? [],
                         draggedTile: tiles[sourceIndex])
        endDrag(tile: tiles[sourceIndex], point: NSPoint(x: 1, y: 1))
    }
    fileprivate func debugSetRelayoutProgress(_ progress: CGFloat) {
        let p = max(0, min(1, progress))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (tile, from, to) in debugLastRelayout {
            tile.frame = NSRect(x: from.minX + (to.minX - from.minX) * p,
                                 y: from.minY + (to.minY - from.minY) * p,
                                 width: from.width + (to.width - from.width) * p,
                                 height: from.height + (to.height - from.height) * p)
        }
        CATransaction.commit()
    }

    fileprivate func debugSetDragProgress(_ progress: CGFloat) {
        let tiles = debugTiles()
        guard let dragged = tiles.first, tiles.count > 1 else { return }
        let clamped = max(0, min(1, progress))
        let source = packedRects(for: drag?.originalOrder ?? tiles.map(\.application))
            .first(where: { $0.app.url == dragged.application.url })?.rect ?? dragged.frame
        if drag == nil {
            beginDrag(tile: dragged, point: NSPoint(x: source.midX, y: source.midY))
        }
        guard let state = drag else { return }
        let targetOrder = state.originalOrder.enumerated().compactMap { $0.offset == state.sourceIndex ? nil : $0.element }
        var movedOrder = targetOrder
        movedOrder.insert(state.originalOrder[state.sourceIndex], at: min(2, targetOrder.count))
        guard let destination = packedRects(for: movedOrder).first(where: {
            $0.app.url == state.originalOrder[state.sourceIndex].url
        })?.rect else { return }
        let point = NSPoint(x: source.midX + (destination.midX - source.midX) * clamped,
                            y: source.midY + (destination.midY - source.midY) * clamped)
        applyDragLayout(pointer: point, animated: false)
    }

    fileprivate func debugEndDrag() {
        guard let tile = drag.flatMap({ state in debugTiles().first { $0.identityKey == state.key } }) else { return }
        let point = NSPoint(x: tile.frame.midX, y: tile.frame.midY)
        endDrag(tile: tile, point: point)
    }
    fileprivate func debugCancelDrag() { cancelDrag() }

    fileprivate var debugDragOrder: [String]? {
        drag?.previewOrder.map { PinnedApp(url: $0.url).identityKey }
    }
    fileprivate var debugDragKey: String? { drag?.key }
    fileprivate var debugDragIndex: Int? { drag?.targetIndex }
    fileprivate var debugDragGapFrame: NSRect? { document.dragGapFrame }
    fileprivate var debugViewFrames: [String: NSRect] {
        Dictionary(firstWins: debugTiles().map { ($0.identityKey, $0.frame) })
    }
    fileprivate func debugBeginDrag(sourceIndex: Int) {
        let tiles = debugTiles()
        guard sourceIndex >= 0, sourceIndex < tiles.count else { return }
        let tile = tiles[sourceIndex]
        beginDrag(tile: tile, point: NSPoint(x: tile.frame.midX, y: tile.frame.midY))
    }
    fileprivate func debugDrag(to point: NSPoint) {
        guard let tile = drag.flatMap({ state in debugTiles().first { $0.identityKey == state.key } }) else { return }
        moveDrag(tile: tile, point: point)
    }
    fileprivate func debugPackedFrames(for order: [String]) -> [String: NSRect] {
        let byKey = Dictionary(firstWins: debugTiles().map { ($0.identityKey, $0.application) })
        let apps = order.compactMap { byKey[$0] }
        return Dictionary(firstWins: packedRects(for: apps).map {
            (PinnedApp(url: $0.app.url).identityKey, $0.rect)
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        Win8Drawing.accent(settings.win8StartColor).setFill()
        bounds.fill()
        let title = searching ? "Search" : (allApps ? "Apps" : "Start")
        let titleWidth = max(0, min(400, bounds.width - 420))
        Retro.drawText(L.t(title, settings.resolvedLanguage),
                       in: NSRect(x: 40, y: 28, width: titleWidth, height: 54),
                       font: .systemFont(ofSize: 40, weight: .light), color: .white, smoothing: true)
        let avatar = NSRect(x: power.frame.minX - 50, y: 32, width: 36, height: 36)
        let nameRight = avatar.minX - 10
        Retro.drawText(SnapshotFixture.userName,
                       in: NSRect(x: max(40, nameRight - 220), y: 38,
                                  width: min(220, max(0, nameRight - 40)), height: 26),
                       font: .systemFont(ofSize: 14), color: .white, smoothing: true, alignment: .right)
        if let image = Win8Drawing.symbol("person.crop.circle") {
            Retro.drawImage(image, in: avatar)
        }
    }

    private static func loadApplications() -> [Application] {
        if SnapshotFixture.isActive, let catalog = ApplicationCatalog.override {
            let hidden = HiddenStore().snapshot()
            return catalog.map { Application(url: $0.url, name: $0.name, icon: $0.icon) }.filter { !hidden.isHidden(app: $0.url) }
        }
        let hidden = HiddenStore().snapshot()
        return AppCatalog.shared.deepApps().filter { !hidden.isHidden(app: $0.url) }.map {
            Application(url: $0.url, name: $0.nameWithoutSuffix, icon: AppIconCache.shared.icon(for: $0.url))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
private final class Win8DocumentView: NSView {
    var headings: [(String, NSRect)] = []
    var folderHeadings: [(CollectionFolder, NSRect)] = []
    var onFolderMenu: ((CollectionFolder) -> NSMenu?)?
    var dragGapFrame: NSRect? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return folderHeadings.first { $0.1.contains(point) }.flatMap { onFolderMenu?($0.0) }
    }
    override func draw(_ dirtyRect: NSRect) {
        for (title, rect) in headings {
            Retro.drawText(title, in: rect, font: .systemFont(ofSize: 18, weight: .light),
                           color: .white, smoothing: true)
        }
        if let gap = dragGapFrame {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(rect: gap.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

@MainActor
private final class Win8HorizontalScrollView: NSScrollView {
    var onScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        onScroll?()
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let distance = event.hasPreciseScrollingDeltas ? delta : delta * 20
        let limit = max(0, documentView.bounds.width - contentView.bounds.width)
        let x = min(limit, max(0, contentView.bounds.minX - distance))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private class Win8Control: NSControl {
    var onClick: (() -> Void)?
    var hovered = false { didSet { needsDisplay = true } }
    fileprivate(set) var pressed = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        endPressAnimation()
        if inside { onClick?() }
    }
    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !inside { pressed = false; endPressAnimation() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onClick?() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    func endPressAnimation() {}
}

@MainActor
private final class Win8GlyphButton: Win8Control {
    var symbol = "" { didSet { needsDisplay = true } }
    var symbolSize: CGFloat = 24
    var drawsLogo = false
    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.white.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
        let rect = NSRect(x: bounds.midX - symbolSize / 2, y: bounds.midY - symbolSize / 2,
                          width: symbolSize, height: symbolSize)
        if drawsLogo { Win8Drawing.logo(in: rect) }
        else if let image = Win8Drawing.symbol(symbol) { Retro.drawImage(image, in: rect) }
    }
}

@MainActor
private final class Win8AppTile: Win8Control {
    fileprivate let application: Win8StartScreenView.Application
    private let color: NSColor?
    var onMenu: (() -> NSMenu?)?
    var onDragBegin: ((NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var onDragCancel: (() -> Void)?
    var allowsDrag = false
    var entranceColumn = 0
    var liveTile = false
    fileprivate var isWideTile = false
    fileprivate var tileSize: Win8TileSize = .small
    fileprivate var identityKey: String { PinnedApp(url: application.url).identityKey }
    fileprivate var debugColor: NSColor? { color }
    private(set) var showingBack = false
    private(set) var debugAnimationCount = 0
    private var hoverOverlay: CALayer?
    private var hoverBorder: CALayer?
    private var flipRestoreAnchor: CGPoint?
    private var flipRestorePosition: CGPoint?
    private var mouseDownPoint = NSPoint.zero
    private var didBeginDrag = false
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    init(application: Win8StartScreenView.Application, color: NSColor?) {
        self.application = application
        self.color = color
        super.init(frame: .zero)
        if !Win8TileAnimation.snapshotMode {
            wantsLayer = true
            if layer == nil { layer = CALayer() }
            layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let overlay = CALayer()
            overlay.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            overlay.opacity = 0
            let border = CALayer()
            border.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
            border.borderWidth = 2
            border.opacity = 0
            layer?.addSublayer(overlay)
            layer?.addSublayer(border)
            hoverOverlay = overlay
            hoverBorder = border
        }
        toolTip = application.detail.map { "\(application.name)\n\($0)" } ?? application.name
        setAccessibilityLabel(application.name)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        hoverOverlay?.frame = bounds
        hoverBorder?.frame = bounds.insetBy(dx: 1, dy: 1)
    }
    override var hovered: Bool {
        didSet {
            guard oldValue != hovered else { return }
            updateHoverAnimation()
        }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        mouseDownPoint = event.locationInWindow
        didBeginDrag = false
        pressed = true
        animatePress(scale: Win8TileAnimation.pressScale)
    }
    override func mouseDragged(with event: NSEvent) {
        let delta = NSPoint(x: event.locationInWindow.x - mouseDownPoint.x,
                            y: event.locationInWindow.y - mouseDownPoint.y)
        if allowsDrag && !didBeginDrag && hypot(delta.x, delta.y) >= 4 {
            didBeginDrag = true
            let point = superview?.convert(event.locationInWindow, from: nil) ?? .zero
            onDragBegin?(point)
        }
        guard didBeginDrag else { return }
        let point = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        onDragMove?(point)
    }
    override func mouseUp(with event: NSEvent) {
        if didBeginDrag {
            let point = superview?.convert(event.locationInWindow, from: nil) ?? .zero
            onDragEnd?(point)
            didBeginDrag = false
            pressed = false
            endPressAnimation()
            return
        }
        super.mouseUp(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, didBeginDrag {
            onDragCancel?()
            didBeginDrag = false
            pressed = false
            endPressAnimation()
            return
        }
        super.keyDown(with: event)
    }
    func setDragging(_ value: Bool) {
        alphaValue = value ? 0.72 : 1
        needsDisplay = true
        guard let layer, !Win8TileAnimation.snapshotMode else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = value ? CATransform3DMakeScale(1.03, 1.03, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
    override func endPressAnimation() {
        animatePress(scale: 1)
    }
    private func animatePress(scale: CGFloat) {
        guard let layer, !Win8TileAnimation.snapshotMode else { return }
        let reduce = Win8TileAnimation.reduceMotion
        let target = reduce ? 1 : scale
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.value(forKeyPath: "transform") ?? NSValue(caTransform3D: layer.transform)
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeScale(target, target, 1))
        animation.duration = reduce ? 0 : Win8TileAnimation.pressDuration
        animation.damping = 18
        animation.initialVelocity = 0
        animation.isRemovedOnCompletion = true
        if animation.duration > 0 { layer.add(animation, forKey: "win8-press") }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(target, target, 1)
        CATransaction.commit()
    }
    private func updateHoverAnimation() {
        guard let overlay = hoverOverlay, let border = hoverBorder, !Win8TileAnimation.snapshotMode else { return }
        let value: Float = hovered ? 1 : 0
        let duration = (Win8TileAnimation.reduceMotion ? 0 : Win8TileAnimation.hoverDuration)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.opacity = value; border.opacity = value
        CATransaction.commit()
        guard duration > 0 else { return }
        for (layer, key) in [(overlay, "win8-hover-overlay"), (border, "win8-hover-border")] {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = layer.presentation()?.opacity ?? (hovered ? 0 : 1)
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        }
    }
    func animateEntrance(delay: CFTimeInterval) {
        guard let layer, !Win8TileAnimation.snapshotMode else { return }
        let reduce = Win8TileAnimation.reduceMotion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        guard !reduce else { return }
        let start = CATransform3DConcat(CATransform3DMakeTranslation(0, Win8TileAnimation.entranceOffset, 0),
                                        CATransform3DMakeScale(Win8TileAnimation.entranceScale, Win8TileAnimation.entranceScale, 1))
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: start)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transform.duration = Win8TileAnimation.entranceDuration
        transform.beginTime = CACurrentMediaTime() + delay
        transform.fillMode = .backwards
        transform.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0; opacity.toValue = 1
        opacity.duration = Win8TileAnimation.entranceDuration
        opacity.beginTime = transform.beginTime
        opacity.fillMode = .backwards
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transform, forKey: "win8-entrance-transform")
        layer.add(opacity, forKey: "win8-entrance-opacity")
    }
    func debugSetEntrance(_ progress: CGFloat) {
        guard let layer else { return }
        let p = max(0, min(1, progress))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = Float(p)
        let offset = (1 - p) * Win8TileAnimation.entranceOffset
        let scale = Win8TileAnimation.entranceScale + (1 - Win8TileAnimation.entranceScale) * p
        layer.transform = CATransform3DConcat(CATransform3DMakeTranslation(0, offset, 0), CATransform3DMakeScale(scale, scale, 1))
        CATransaction.commit()
    }
    func animateFlip(toBack: Bool, force: Bool = false, completion: @escaping () -> Void) {
        guard let layer, (liveTile || force), !Win8TileAnimation.snapshotMode else { completion(); return }
        let originalAnchor = layer.anchorPoint
        let originalPosition = layer.position
        if flipRestoreAnchor == nil {
            flipRestoreAnchor = originalAnchor
            flipRestorePosition = originalPosition
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()
        debugAnimationCount += 1
        func transform(_ degrees: CGFloat) -> CATransform3D {
            var result = CATransform3DMakeRotation(degrees * .pi / 180, 1, 0, 0)
            result.m34 = Win8TileAnimation.perspective
            return result
        }
        let start = transform(0)
        let plusNinety = transform(90)
        let minusNinety = transform(-90)
        let end = transform(0)
        let rotation = CAKeyframeAnimation(keyPath: "transform")
        rotation.values = [NSValue(caTransform3D: start), NSValue(caTransform3D: plusNinety),
                           NSValue(caTransform3D: minusNinety), NSValue(caTransform3D: end)]
        rotation.keyTimes = [0, 0.5, 0.5001, 1]
        rotation.duration = Win8TileAnimation.flipDuration
        rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rotation.fillMode = .forwards
        rotation.isRemovedOnCompletion = false
        rotation.delegate = Win8FlipDelegate { [weak self] in
            guard let self else { completion(); return }
            self.debugAnimationCount = max(0, self.debugAnimationCount - 1)
            self.showingBack = toBack
            if !toBack {
                self.resetFront()
            } else {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.layer?.removeAnimation(forKey: "win8-live-flip")
                self.layer?.transform = CATransform3DIdentity
                CATransaction.commit()
                self.needsDisplay = true
            }
            completion()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = end
        CATransaction.commit()
        layer.add(rotation, forKey: "win8-live-flip")
        DispatchQueue.main.asyncAfter(deadline: .now() + Win8TileAnimation.flipDuration / 2) { [weak self] in
            guard let self, self.layer?.animation(forKey: "win8-live-flip") != nil else { return }
            self.showingBack = toBack
            self.needsDisplay = true
        }
    }
    func resetFront() {
        showingBack = false
        debugAnimationCount = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAllAnimations(); layer?.transform = CATransform3DIdentity
        if let anchor = flipRestoreAnchor, let position = flipRestorePosition {
            layer?.anchorPoint = anchor
            layer?.position = position
        }
        CATransaction.commit()
        flipRestoreAnchor = nil
        flipRestorePosition = nil
        needsDisplay = true
    }
    func debugSetFlipAngle(_ degrees: CGFloat) {
        guard let layer else { return }
        var transform = CATransform3DMakeRotation(degrees * .pi / 180, 1, 0, 0)
        transform.m34 = Win8TileAnimation.perspective
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
        showingBack = degrees > 90
        needsDisplay = true
    }
    fileprivate func debugStartFlip() {
        animateFlip(toBack: true, force: true) {}
    }
    fileprivate func debugFlatBitmap() -> NSBitmapImageRep? {
        guard layer != nil else { return nil }
        let saved = layer?.transform ?? CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        let rep = SnapshotFixture.bitmap(for: self)
        if let rep { cacheDisplay(in: bounds, to: rep) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = saved
        CATransaction.commit()
        return rep
    }
    func debugSetPressed(_ down: Bool) { animatePress(scale: down ? Win8TileAnimation.pressScale : 1) }
    func debugSetHovered(_ value: Bool) { hovered = value }
    override func draw(_ dirtyRect: NSRect) {
        if let color {
            color.setFill()
            bounds.fill()
        }
        if hovered && Win8TileAnimation.snapshotMode {
            NSColor.white.withAlphaComponent(0.18).setFill()
            bounds.fill()
        }
        if showingBack {
            Retro.drawText(application.name, in: NSRect(x: 10, y: bounds.midY - 24, width: bounds.width - 20, height: 34),
                           font: .systemFont(ofSize: 19, weight: .medium), color: .white, smoothing: true)
            Retro.drawText(applicationKind, in: NSRect(x: 10, y: bounds.midY + 14, width: bounds.width - 20, height: 20),
                           font: .systemFont(ofSize: 12), color: .white.withAlphaComponent(0.86), smoothing: true)
            return
        }
        if color == nil {
            Retro.drawImage(application.icon, in: NSRect(x: 0, y: 5, width: 24, height: 24))
            Retro.drawText(application.name, in: NSRect(x: 34, y: 0, width: bounds.width - 40, height: bounds.height),
                           font: .systemFont(ofSize: 13), color: .white, smoothing: true)
        } else {
            let iconSize: CGFloat = bounds.height > 100 ? 48 : 28
            Retro.drawImage(application.icon,
                            in: NSRect(x: bounds.midX - iconSize / 2, y: (bounds.height - 24 - iconSize) / 2,
                                       width: iconSize, height: iconSize))
            Retro.drawText(application.name,
                           in: NSRect(x: 8, y: bounds.height - 26, width: bounds.width - 16, height: 20),
                           font: .systemFont(ofSize: 12), color: .white, smoothing: true)
        }
    }
    private var applicationKind: String {
        let isFolder = (try? application.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let language = SnapshotFixture.isActive ? SnapshotFixture.settings.resolvedLanguage : SettingsStore.shared.current.resolvedLanguage
        if isFolder { return L.t("Folder", language) }
        if application.url.pathExtension.lowercased() == "app" { return L.t("Application", language) }
        return L.t("Open", language)
    }
}

private final class Win8FlipDelegate: NSObject, CAAnimationDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { if flag { done() } }
}

@MainActor
enum Win8AnimationDebug {
    static func runSelfTest() -> Int {
        SnapshotFixture.activate()
        let layoutStore = Win8LayoutStore()
        layoutStore.entries = []
        let view = Win8StartScreenView(settings: SnapshotFixture.settings, coversTaskbar: false)
        view.frame = SnapshotFixture.screenFrame
        view.layoutSubtreeIfNeeded()
        let defaultTiles = view.debugTiles()
        let defaultNames = defaultTiles.map { $0.application.name }
        let defaultSizes = defaultTiles.map { $0.tileSize }
        let defaultUnchanged = defaultNames == SnapshotFixture.catalog.map(\.name) &&
            defaultSizes.prefix(3).elementsEqual([Win8TileSize.medium, .wide, .small])
        guard defaultUnchanged else {
            fputs("FAIL win8 layout selftest default layout changed names=\(defaultNames) sizes=\(defaultSizes)\n", stderr)
            return 1
        }
        guard let first = defaultTiles.first, let second = defaultTiles.dropFirst().first,
              let third = defaultTiles.dropFirst(2).first else {
            fputs("FAIL win8 layout selftest missing fixture tiles\n", stderr)
            return 1
        }
        let customEntries = [
            Win8LayoutEntry(key: third.identityKey, size: Win8TileSize.large.rawValue),
            Win8LayoutEntry(key: first.identityKey, size: Win8TileSize.small.rawValue),
            Win8LayoutEntry(key: second.identityKey, size: Win8TileSize.wide.rawValue)
        ]
        layoutStore.entries = customEntries
        let customView = Win8StartScreenView(settings: SnapshotFixture.settings, coversTaskbar: false)
        customView.frame = SnapshotFixture.screenFrame
        customView.layoutSubtreeIfNeeded()
        let customTiles = customView.debugTiles()
        let customApplied = customTiles.prefix(3).map { $0.application.name } ==
            [third.application.name, first.application.name, second.application.name] &&
            customTiles.prefix(3).map { $0.tileSize } == [.large, .small, .wide]
        let defaultColors = Dictionary(firstWins: defaultTiles.compactMap { tile in
            tile.debugColor.map { (tile.identityKey, $0) }
        })
        let customColors = Dictionary(firstWins: customTiles.compactMap { tile in
            tile.debugColor.map { (tile.identityKey, $0) }
        })
        let colorsPreserved = defaultColors.count == customColors.count &&
            defaultColors.allSatisfy { key, color in customColors[key]?.isEqual(color) == true }
        let roundTrip = Win8LayoutStore.encode(customEntries).flatMap(Win8LayoutStore.decode) == customEntries
        layoutStore.remove(PinnedApp(url: third.application.url))
        let unpinRemoved = !layoutStore.entries.contains { $0.key == third.identityKey }
        layoutStore.entries = []
        guard customApplied, colorsPreserved, roundTrip, unpinRemoved else {
            fputs("FAIL win8 layout selftest custom=\(customApplied) colors=\(colorsPreserved) roundTrip=\(roundTrip) unpin=\(unpinRemoved)\n", stderr)
            return 1
        }
        view.beginVisibleAnimations()
        let scheduled = view.debugFlipTimerCount
        var resized = SnapshotFixture.screenFrame
        resized.size.height -= 40
        view.frame = resized
        view.layoutSubtreeIfNeeded()
        let survivesRebuild = view.debugFlipTimerCount > 0
        view.frame = SnapshotFixture.screenFrame
        view.layoutSubtreeIfNeeded()
        let tiles = view.debugTiles()
        let wide = tiles.first { $0.isWideTile }
        let layerFrameBefore = wide?.layer?.frame
        let viewFrameBefore = wide?.frame
        let beforePosition = wide?.layer?.position
        wide?.debugStartFlip()
        let flipAnimation = wide?.layer?.animation(forKey: "win8-live-flip")
        let transformValues: [CATransform3D] = {
            if let keyframe = flipAnimation as? CAKeyframeAnimation {
                return (keyframe.values ?? []).compactMap { ($0 as? NSValue)?.caTransform3DValue }
            }
            if let basic = flipAnimation as? CABasicAnimation {
                return [basic.fromValue, basic.toValue].compactMap { ($0 as? NSValue)?.caTransform3DValue }
            }
            return []
        }()
        let fromM34 = transformValues.first?.m34 ?? 0
        let toM34 = transformValues.last?.m34 ?? 0
        let afterPosition = wide?.layer?.position
        let liveAnchor = wide?.layer?.anchorPoint
        let liveLayerFrame = wide?.layer?.frame
        let liveViewFrame = wide?.frame
        let animationKeyPath = (flipAnimation as? CAPropertyAnimation)?.keyPath
        let layerExists = wide?.layer != nil
        let animationKeyExists = flipAnimation != nil
        let keyPathOK = animationKeyPath == "transform"
        let m34OK = abs(fromM34 - Win8TileAnimation.perspective) < 0.000001 &&
            abs(toM34 - Win8TileAnimation.perspective) < 0.000001
        let anchorOK = liveAnchor == CGPoint(x: 0.5, y: 0.5)
        let layerFrameUnchanged = liveLayerFrame == layerFrameBefore
        let viewFrameUnchanged = liveViewFrame == viewFrameBefore
        let runtimeFlip = wide != nil && layerExists && animationKeyExists && keyPathOK && m34OK && anchorOK &&
            layerFrameUnchanged && viewFrameUnchanged
        RunLoop.current.run(until: Date().addingTimeInterval(Win8TileAnimation.flipDuration + 0.05))
        let dwellHeld = wide?.showingBack == true
        view.stopAnimations()
        let clean = view.debugFlipTimerCount == 0 && view.debugAnimationCount == 0
        view.reduceMotionOverride = true
        view.beginVisibleAnimations()
        let reduced = view.debugFlipTimerCount == 0 && view.debugAnimationCount == 0
        view.stopAnimations()
        guard scheduled > 0, survivesRebuild, runtimeFlip, dwellHeld, clean, reduced else {
            let widths = tiles.map { String(format: "%.1f", $0.frame.width) }.joined(separator: ",")
            let wideWidth = wide.map { String(format: "%.1f", $0.frame.width) } ?? "nil"
            fputs("FAIL win8 animation selftest scheduled=\(scheduled) survivesRebuild=\(survivesRebuild) runtimeFlip=\(runtimeFlip) dwellHeld=\(dwellHeld) clean=\(clean) reduced=\(reduced) wideFound=\(wide != nil) wideWidth=\(wideWidth) allWidths=[\(widths)] layer=\(layerExists) animationKey=\(animationKeyExists) keyPath=\(animationKeyPath ?? "nil") keyPathOK=\(keyPathOK) fromM34=\(fromM34) toM34=\(toM34) m34OK=\(m34OK) liveAnchor=\(String(describing: liveAnchor)) anchorOK=\(anchorOK) positionBefore=\(String(describing: beforePosition)) positionAfter=\(String(describing: afterPosition)) layerFrameBefore=\(String(describing: layerFrameBefore)) liveLayerFrame=\(String(describing: liveLayerFrame)) layerFrameUnchanged=\(layerFrameUnchanged) viewFrameBefore=\(String(describing: viewFrameBefore)) liveViewFrame=\(String(describing: liveViewFrame)) viewFrameUnchanged=\(viewFrameUnchanged)\n", stderr)
            return 1
        }
        print("PASS win8 animation selftest timers=\(scheduled) layout=1")
        return 0
    }

    static func renderEditSnapshots(to directory: URL) -> Int {
        SnapshotFixture.activate()
        SnapshotFixture.win8LayoutEntries = []
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SnapshotFixture.settings
        let defaultView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        defaultView.frame = SnapshotFixture.screenFrame
        defaultView.layoutSubtreeIfNeeded()
        save(defaultView, to: directory.appendingPathComponent("layout-default.png"))

        let defaultTiles = defaultView.debugTiles()
        guard defaultTiles.count >= 3 else { return 1 }
        let defaultUnchanged = defaultTiles.map { $0.application.name } == SnapshotFixture.catalog.map(\.name) &&
            defaultTiles.prefix(3).map { $0.tileSize } == [.medium, .wide, .small]
        guard defaultUnchanged else {
            fputs("FAIL win8 edit snapshot default layout changed\n", stderr)
            return 1
        }
        let first = defaultTiles[0]
        let second = defaultTiles[1]
        let third = defaultTiles[2]
        let customEntries = [
            Win8LayoutEntry(key: third.identityKey, size: Win8TileSize.large.rawValue),
            Win8LayoutEntry(key: first.identityKey, size: Win8TileSize.small.rawValue),
            Win8LayoutEntry(key: second.identityKey, size: Win8TileSize.wide.rawValue)
        ]
        let layoutStore = Win8LayoutStore()
        layoutStore.entries = customEntries
        let roundTrip = Win8LayoutStore.encode(customEntries).flatMap(Win8LayoutStore.decode) == customEntries
        layoutStore.remove(PinnedApp(url: third.application.url))
        let unpinRemoved = !layoutStore.entries.contains { $0.key == third.identityKey }
        layoutStore.entries = customEntries
        let customView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        customView.frame = SnapshotFixture.screenFrame
        customView.layoutSubtreeIfNeeded()
        let customTiles = customView.debugTiles()
        let customApplied = customTiles.prefix(3).map { $0.application.name } ==
            [third.application.name, first.application.name, second.application.name] &&
            customTiles.prefix(3).map { $0.tileSize } == [.large, .small, .wide]
        let defaultColors = Dictionary(firstWins: defaultTiles.compactMap { tile in
            tile.debugColor.map { (tile.identityKey, $0) }
        })
        let customColors = Dictionary(firstWins: customTiles.compactMap { tile in
            tile.debugColor.map { (tile.identityKey, $0) }
        })
        let colorsPreserved = defaultColors.count == customColors.count &&
            defaultColors.allSatisfy { key, color in customColors[key]?.isEqual(color) == true }
        guard customApplied, colorsPreserved, roundTrip, unpinRemoved else {
            fputs("FAIL win8 edit snapshot custom=\(customApplied) colors=\(colorsPreserved) roundTrip=\(roundTrip) unpin=\(unpinRemoved)\n", stderr)
            return 1
        }
        save(customView, to: directory.appendingPathComponent("layout-custom.png"))

        let pageEntries = defaultTiles.map {
            Win8LayoutEntry(key: $0.identityKey, size: Win8TileSize.large.rawValue)
        }
        layoutStore.entries = pageEntries
        let pageView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        pageView.frame = SnapshotFixture.screenFrame
        pageView.layoutSubtreeIfNeeded()
        func validPageState(_ view: Win8StartScreenView) -> Bool {
            let tiles = view.debugTiles()
            let nonOverlapping = tiles.enumerated().allSatisfy { index, tile in
                tiles.dropFirst(index + 1).allSatisfy { other in !tile.frame.intersects(other.frame) }
            }
            let inBounds = tiles.allSatisfy { view.debugDocumentBounds.contains($0.frame) }
            return nonOverlapping && inBounds && view.debugTilesHaveIdentityTransforms && view.debugTilesHaveNoAnimations
        }
        let pagePositions: [(CGFloat, String)] = [
            (0, "page-scroll-000"), (200, "page-scroll-001"), (360, "page-scroll-002"),
            (500, "page-scroll-003"), (0, "page-scroll-004")
        ]
        var pagesValid = true
        for (x, name) in pagePositions {
            pageView.debugSetScrollOrigin(NSPoint(x: x, y: 0))
            pageView.debugSettleScroll()
            pagesValid = pagesValid && validPageState(pageView)
            save(pageView, to: directory.appendingPathComponent("\(name).png"))
            if x == 0 && name == "page-scroll-000" {
                save(pageView, to: directory.appendingPathComponent("page-000.png"))
            } else if x == 360 {
                save(pageView, to: directory.appendingPathComponent("page-mid.png"))
            } else if x == 500 {
                save(pageView, to: directory.appendingPathComponent("page-end.png"))
                save(pageView, to: directory.appendingPathComponent("page-glitch-repro.png"))
            }
        }
        guard pageView.debugDocumentBounds.width >= 720, pagesValid else {
            fputs("FAIL win8 edit snapshot page scroll state valid=\(pagesValid) bounds=\(pageView.debugDocumentBounds)\n", stderr)
            return 1
        }

        let smallEntries = defaultTiles.enumerated().map { index, tile in
            Win8LayoutEntry(key: tile.identityKey,
                            size: (index < 4 ? Win8TileSize.small : (index == 4 ? .medium : (index == 5 ? .wide : .small))).rawValue)
        }
        layoutStore.entries = smallEntries
        let smallView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        smallView.frame = SnapshotFixture.screenFrame
        smallView.layoutSubtreeIfNeeded()
        let smallTiles = smallView.debugTiles().prefix(4)
        let smallOrigin = smallTiles.first?.frame.origin ?? .zero
        let expectedSmallFrames = [
            NSRect(x: smallOrigin.x, y: smallOrigin.y, width: 70, height: 70),
            NSRect(x: smallOrigin.x + 80, y: smallOrigin.y, width: 70, height: 70),
            NSRect(x: smallOrigin.x, y: smallOrigin.y + 80, width: 70, height: 70),
            NSRect(x: smallOrigin.x + 80, y: smallOrigin.y + 80, width: 70, height: 70)
        ]
        let smallsPacked = smallTiles.count == 4 && zip(smallTiles, expectedSmallFrames).allSatisfy { tile, expected in
            tile.frame == expected
        }
        guard smallsPacked else {
            fputs("FAIL win8 edit snapshot small tiles did not form a 2x2 block frames=\(smallTiles.map(\.frame))\n", stderr)
            return 1
        }
        save(smallView, to: directory.appendingPathComponent("layout-smalls.png"))

        layoutStore.entries = customEntries
        let dropView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        dropView.frame = SnapshotFixture.screenFrame
        dropView.layoutSubtreeIfNeeded()
        let dropTilesBefore = dropView.debugTiles()
        let dropInstances = Dictionary(firstWins: dropTilesBefore.map { ($0.identityKey, $0) })
        dropView.debugSetScrollOrigin(.zero)
        let originBeforeDrop = dropView.debugScrollOrigin
        let documentOriginBeforeDrop = dropView.debugDocumentOrigin
        dropView.debugCommitDrop(sourceIndex: 0, targetIndex: 2)
        let dropTilesAfter = dropView.debugTiles()
        let sameInstances = dropTilesAfter.allSatisfy { dropInstances[$0.identityKey] === $0 }
        let originUnchanged = dropView.debugScrollOrigin == originBeforeDrop
        let documentOriginUnchanged = dropView.debugDocumentOrigin == documentOriginBeforeDrop
        let noTransition = !dropView.debugHasContentTransition
        let zeroOrigin = originBeforeDrop == .zero
        let hasChangedTile = dropView.debugRelayoutHasChangedTile
        guard sameInstances, originUnchanged, documentOriginUnchanged, noTransition, zeroOrigin, hasChangedTile else {
            fputs("FAIL win8 edit snapshot drop sameInstances=\(sameInstances) originUnchanged=\(originUnchanged) documentOriginUnchanged=\(documentOriginUnchanged) zeroOrigin=\(zeroOrigin) hasChangedTile=\(hasChangedTile) noTransition=\(noTransition) before=\(originBeforeDrop) after=\(dropView.debugScrollOrigin)\n", stderr)
            return 1
        }
        var stationaryFramesOK = true
        for percent in stride(from: 0, through: 100, by: 25) {
            dropView.debugSetRelayoutProgress(CGFloat(percent) / 100)
            stationaryFramesOK = stationaryFramesOK && dropView.debugStationaryRelayoutTilesAreFixed &&
                dropView.debugScrollOrigin == originBeforeDrop && dropView.debugDocumentOrigin == documentOriginBeforeDrop
            save(dropView, to: directory.appendingPathComponent(String(format: "drop-%03d.png", percent)))
        }
        guard stationaryFramesOK else {
            fputs("FAIL win8 edit snapshot drop stationary tile or origin moved\n", stderr)
            return 1
        }

        func keys(_ view: Win8StartScreenView) -> [String] {
            view.debugTiles().map(\.identityKey)
        }
        func frames(_ view: Win8StartScreenView) -> [String: NSRect] {
            Dictionary(firstWins: view.debugTiles().map { ($0.identityKey, $0.frame) })
        }
        func smallQuarterInvariant(_ view: Win8StartScreenView) -> Bool {
            struct Block: Hashable {
                let group: Int
                let column: Int
                let row: Int
            }
            var open: Set<Block> = []
            var quarters: [Block: Set<Int>] = [:]
            var nextQuarter: [Block: Int] = [:]
            for tile in view.debugTiles() {
                guard tile.tileSize == .small else { continue }
                let x = Int(tile.frame.minX.rounded())
                let y = Int(tile.frame.minY.rounded())
                let group = x >= 0 ? x / 360 : (x - 359) / 360
                let localX = x - group * 360
                let block = Block(group: group, column: localX / 160, row: y / 160)
                if open.contains(where: { $0 != block }) { return false }
                let quarter = (localX % 160) / 80 + ((y % 160) / 80) * 2
                let expected = nextQuarter[block] ?? 0
                guard quarter == expected else { return false }
                quarters[block, default: []].insert(quarter)
                nextQuarter[block] = expected + 1
                if quarters[block]?.count == 4 { open.remove(block) }
                else { open.insert(block) }
            }
            return true
        }
        func fourthSmallFilled(_ view: Win8StartScreenView, expected: [String]) -> Bool {
            let smalls = view.debugTiles().filter { $0.tileSize == .small }
            guard smalls.count >= 4,
                  smalls.prefix(4).map(\.identityKey) == expected else { return false }
            guard let first = smalls.first else { return false }
            let origin = first.frame.origin
            let expectedFrames = [
                NSRect(x: origin.x, y: origin.y, width: 70, height: 70),
                NSRect(x: origin.x + 80, y: origin.y, width: 70, height: 70),
                NSRect(x: origin.x, y: origin.y + 80, width: 70, height: 70),
                NSRect(x: origin.x + 80, y: origin.y + 80, width: 70, height: 70)
            ]
            return zip(smalls.prefix(4), expectedFrames).allSatisfy { $0.frame == $1 }
        }
        func exerciseDrag(_ view: Win8StartScreenView, source: Int, path: [NSPoint]) -> Bool {
            view.debugSetScrollOrigin(.zero)
            view.debugBeginDrag(sourceIndex: source)
            guard view.debugDragIndex != nil else {
                fputs("drag debug begin failed source=\(source) tiles=\(view.debugTiles().count)\n", stderr)
                return false
            }
            var indices = [view.debugDragIndex]
            for point in path {
                view.debugDrag(to: point)
                indices.append(view.debugDragIndex)
            }
            let stableJitter = path.last.map { boundary in
                view.debugDrag(to: NSPoint(x: boundary.x - 5, y: boundary.y))
                let first = view.debugDragIndex
                view.debugDrag(to: NSPoint(x: boundary.x + 5, y: boundary.y))
                return first == view.debugDragIndex
            } ?? true
            let lastOrder = view.debugDragOrder ?? []
            let draggedKey = view.debugDragKey
            let lastFrames = view.debugViewFrames
            let lastGap = view.debugDragGapFrame
            view.debugEndDrag()
            let committedOrder = keys(view)
            let committedFrames = frames(view)
            let expectedFrames = view.debugPackedFrames(for: committedOrder)
            let nonDraggedFramesMatch = lastFrames.allSatisfy { key, frame in
                key == draggedKey || committedFrames[key] == frame
            }
            let draggedFrameMatchesGap = draggedKey.flatMap { key in
                guard let gap = lastGap, let frame = committedFrames[key] else { return false }
                return frame == gap
            } ?? false
            let ok = committedOrder == lastOrder && nonDraggedFramesMatch && draggedFrameMatchesGap &&
                committedFrames == expectedFrames && stableJitter && indices.allSatisfy { $0 != nil } &&
                smallQuarterInvariant(view)
            if !ok {
                fputs("drag debug order=\(lastOrder) committed=\(committedOrder) index=\(indices) stable=\(stableJitter) nonDragged=\(nonDraggedFramesMatch) draggedGap=\(draggedFrameMatchesGap)\n", stderr)
            }
            return ok
        }

        let dragEntries = defaultTiles.enumerated().map { index, tile in
            Win8LayoutEntry(key: tile.identityKey,
                            size: (index < 4 ? Win8TileSize.small : (index == 4 ? .medium :
                                (index == 5 ? .wide : (index == 6 ? .large : .small)))).rawValue)
        }
        func makeDragView(entries: [Win8LayoutEntry]) -> Win8StartScreenView {
            layoutStore.entries = entries
            let v = Win8StartScreenView(settings: settings, coversTaskbar: false)
            v.frame = SnapshotFixture.screenFrame
            v.layoutSubtreeIfNeeded()
            v.debugSetScrollOrigin(.zero)
            return v
        }
        let quarterView = makeDragView(entries: dragEntries)
        let quarterTiles = quarterView.debugTiles()
        let quarterPath = [NSPoint(x: 120, y: 40), NSPoint(x: 180, y: 40), NSPoint(x: 260, y: 40)]
        let quarterOK = exerciseDrag(quarterView, source: 0, path: quarterPath)
        let mediumView = makeDragView(entries: dragEntries)
        let mediumOK = exerciseDrag(mediumView, source: 0,
                                    path: [NSPoint(x: 420, y: 40), NSPoint(x: 520, y: 40)])
        let wideView = makeDragView(entries: dragEntries)
        let wideOK = exerciseDrag(wideView, source: 0,
                                  path: [NSPoint(x: 700, y: 40), NSPoint(x: 900, y: 40)])
        let groupView = makeDragView(entries: dragEntries)
        let groupOK = exerciseDrag(groupView, source: 0,
                                   path: [NSPoint(x: 1180, y: 40), NSPoint(x: 1320, y: 40)])
        layoutStore.entries = []
        let firstDragView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        firstDragView.frame = SnapshotFixture.screenFrame
        firstDragView.layoutSubtreeIfNeeded()
        let firstDragOK = exerciseDrag(firstDragView, source: 0,
                                       path: [NSPoint(x: 120, y: 40), NSPoint(x: 500, y: 40)])
        var fourthSmallEntries = dragEntries
        if fourthSmallEntries.indices.contains(7) {
            fourthSmallEntries[7] = Win8LayoutEntry(key: fourthSmallEntries[7].key,
                                                    size: Win8TileSize.medium.rawValue)
        }
        let fourthSmallView = makeDragView(entries: fourthSmallEntries)
        fourthSmallView.debugCommitDrop(sourceIndex: 0, targetIndex: 3)
        let fourthSmallExpected = [defaultTiles[1], defaultTiles[2], defaultTiles[3], defaultTiles[0]].map(\.identityKey)
        let fourthSmallOK = fourthSmallFilled(fourthSmallView, expected: fourthSmallExpected) &&
            smallQuarterInvariant(fourthSmallView)
        layoutStore.entries = []
        let cancelView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        cancelView.frame = SnapshotFixture.screenFrame
        cancelView.layoutSubtreeIfNeeded()
        let cancelOrder = keys(cancelView)
        let cancelFrames = frames(cancelView)
        cancelView.debugBeginDrag(sourceIndex: 0)
        cancelView.debugDrag(to: NSPoint(x: 500, y: 40))
        cancelView.debugCancelDrag()
        let cancelOK = keys(cancelView) == cancelOrder && frames(cancelView) == cancelFrames && layoutStore.entries.isEmpty
        let scrollCancelView = makeDragView(entries: dragEntries)
        let scrollCancelOrder = keys(scrollCancelView)
        let scrollCancelFrames = frames(scrollCancelView)
        scrollCancelView.debugBeginDrag(sourceIndex: 0)
        scrollCancelView.debugDrag(to: NSPoint(x: 500, y: 40))
        scrollCancelView.debugSetScrollOrigin(NSPoint(x: 200, y: 0))
        let scrollCancelOK = scrollCancelView.debugDragKey == nil &&
            keys(scrollCancelView) == scrollCancelOrder && frames(scrollCancelView) == scrollCancelFrames
        guard quarterOK, mediumOK, wideOK, groupOK, firstDragOK, cancelOK, scrollCancelOK,
              fourthSmallOK, quarterTiles.count >= 4 else {
            fputs("FAIL win8 edit snapshot drag preview tests quarter=\(quarterOK) medium=\(mediumOK) wide=\(wideOK) group=\(groupOK) first=\(firstDragOK) cancel=\(cancelOK) scrollCancel=\(scrollCancelOK) fourthSmall=\(fourthSmallOK)\n", stderr)
            return 1
        }

        layoutStore.entries = dragEntries
        let dragDisplayView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        dragDisplayView.frame = SnapshotFixture.screenFrame
        dragDisplayView.layoutSubtreeIfNeeded()
        dragDisplayView.debugSetScrollOrigin(.zero)
        dragDisplayView.debugBeginDrag(sourceIndex: 0)
        let dragStart = dragDisplayView.debugTiles().first?.frame ?? .zero
        let dragEnd = NSPoint(x: 450, y: 40)
        for (index, progress) in [CGFloat(0), 0.25, 0.5, 0.75, 1].enumerated() {
            dragDisplayView.debugDrag(to: NSPoint(x: dragStart.midX + (dragEnd.x - dragStart.midX) * progress,
                                                  y: dragStart.midY + (dragEnd.y - dragStart.midY) * progress))
            save(dragDisplayView, to: directory.appendingPathComponent(String(format: "dragdisp-%03d.png", index * 25)))
        }
        dragDisplayView.debugEndDrag()
        guard smallQuarterInvariant(dragDisplayView) else {
            fputs("FAIL win8 edit snapshot drag display left an open small quarter\n", stderr)
            return 1
        }
        save(dragDisplayView, to: directory.appendingPathComponent("dragdisp-drop.png"))

        let perfView = makeDragView(entries: dragEntries)
        let perfInstances = Dictionary(firstWins: perfView.debugTiles().map { ($0.identityKey, $0) })
        perfView.debugBeginDrag(sourceIndex: 0)
        guard let perfDragStart = perfView.debugTiles().first?.frame else {
            fputs("FAIL win8 edit snapshot drag performance setup\n", stderr)
            return 1
        }
        let cachedPackCalls = perfView.debugPackCallCount
        for jitter in 0..<30 {
            let delta: CGFloat = jitter.isMultiple(of: 2) ? 3 : -3
            perfView.debugDrag(to: NSPoint(x: perfDragStart.midX + delta,
                                           y: perfDragStart.midY + delta / 2))
        }
        let stablePackCache = perfView.debugPackCallCount == cachedPackCalls
        perfView.debugDrag(to: NSPoint(x: 500, y: perfDragStart.midY))
        let changedIndex = perfView.debugDragIndex != 0
        let changedPackCache = perfView.debugPackCallCount == cachedPackCalls
        let previewFrames = perfView.debugViewFrames
        let previewOrder = perfView.debugDragOrder
        let previewGap = perfView.debugDragGapFrame
        let draggedKey = perfView.debugDragKey
        let identitiesStable = perfView.debugTiles().allSatisfy { perfInstances[$0.identityKey] === $0 }
        perfView.debugEndDrag()
        let dropFrames = perfView.debugViewFrames
        let dropOrder = perfView.debugTiles().map(\.identityKey)
        let expectedPerfFrames = perfView.debugPackedFrames(for: dropOrder)
        let previewDropFrames = previewOrder == dropOrder && previewFrames.allSatisfy { key, frame in
            key == draggedKey || dropFrames[key] == frame
        } && draggedKey.flatMap { key in
            guard let gap = previewGap, let frame = dropFrames[key] else { return false }
            return gap == frame
        } == true
        let perfFramesMatch = dropFrames == expectedPerfFrames
        guard stablePackCache, changedIndex, changedPackCache, identitiesStable, previewDropFrames, perfFramesMatch else {
            fputs("FAIL win8 edit snapshot drag performance stableCache=\(stablePackCache) changedIndex=\(changedIndex) changedCache=\(changedPackCache) identities=\(identitiesStable) previewDrop=\(previewDropFrames) frames=\(perfFramesMatch) calls=\(perfView.debugPackCallCount) cached=\(cachedPackCalls)\n", stderr)
            return 1
        }

        let dragPerfView = makeDragView(entries: dragEntries)
        dragPerfView.debugBeginDrag(sourceIndex: 0)
        let dragPerfStart = dragPerfView.debugTiles().first?.frame ?? .zero
        let dragPerfEnd = NSPoint(x: 520, y: dragPerfStart.midY)
        var dragPerfFrames: [CGImage] = []
        for percent in stride(from: 0, through: 100, by: 10) {
            let progress = CGFloat(percent) / 100
            dragPerfView.debugDrag(to: NSPoint(x: dragPerfStart.midX + (dragPerfEnd.x - dragPerfStart.midX) * progress,
                                               y: dragPerfStart.midY + (dragPerfEnd.y - dragPerfStart.midY) * progress))
            save(dragPerfView, to: directory.appendingPathComponent(String(format: "dragperf-%03d.png", percent)))
            if let image = capture(dragPerfView) { dragPerfFrames.append(image) }
        }
        dragPerfView.debugEndDrag()
        save(dragPerfView, to: directory.appendingPathComponent("dragperf-drop.png"))
        if let image = capture(dragPerfView) { dragPerfFrames.append(image) }
        saveGIF(dragPerfFrames, to: directory.appendingPathComponent("dragperf.gif"))

        func hasNoEarlierEmptyMediumSlot(_ view: Win8StartScreenView) -> Bool {
            struct Cell: Hashable {
                let group: Int
                let column: Int
                let row: Int
            }
            let tiles = view.debugTiles()
            let grouped = Dictionary(grouping: tiles) { tile in
                Int(tile.frame.minX.rounded(.down)) / 360
            }
            for (group, groupTiles) in grouped {
                var occupied: Set<Cell> = []
                for tile in groupTiles {
                    let localX = Int(tile.frame.minX.rounded(.down)) - group * 360
                    let row = Int(tile.frame.minY.rounded(.down)) / 80
                    for column in (localX / 80)..<(localX / 80 + tile.tileSize.dimensions.width) {
                        for currentRow in row..<(row + tile.tileSize.dimensions.height) {
                            occupied.insert(Cell(group: group, column: column, row: currentRow))
                        }
                    }
                }
                for tile in groupTiles {
                    let localX = Int(tile.frame.minX.rounded(.down)) - group * 360
                    let tileColumn = localX / 80
                    let tileRow = Int(tile.frame.minY.rounded(.down)) / 80
                    for row in 0..<(tileRow + 1) {
                        for column in 0..<3 where row < tileRow || column < tileColumn {
                            let free = (column..<(column + 2)).allSatisfy { currentColumn in
                                (row..<(row + 2)).allSatisfy {
                                    !occupied.contains(Cell(group: group, column: currentColumn, row: $0))
                                }
                            }
                            if free { return false }
                        }
                    }
                }
            }
            return true
        }

        ApplicationCatalog.override = SnapshotFixture.denseWin8Catalog
        let denseSizes: [Win8TileSize] = [.wide, .medium, .medium] +
            Array(repeating: .small, count: SnapshotFixture.denseWin8Catalog.count - 3)
        let denseEntries = zip(SnapshotFixture.denseWin8Catalog, denseSizes).map { app, size in
            Win8LayoutEntry(key: PinnedApp(url: app.url).identityKey, size: size.rawValue)
        }
        layoutStore.entries = denseEntries
        let denseBefore = Win8StartScreenView(settings: settings, coversTaskbar: false,
                                              debugColumnMajorPacker: true)
        denseBefore.frame = SnapshotFixture.screenFrame
        denseBefore.layoutSubtreeIfNeeded()
        save(denseBefore, to: directory.appendingPathComponent("dense-before.png"))
        let denseAfter = Win8StartScreenView(settings: settings, coversTaskbar: false)
        denseAfter.frame = SnapshotFixture.screenFrame
        denseAfter.layoutSubtreeIfNeeded()
        save(denseAfter, to: directory.appendingPathComponent("dense-after.png"))
        let denseTiles = denseAfter.debugTiles()
        let denseSmalls = denseTiles.filter { $0.tileSize == .small }
        let secondSmallBlock = denseSmalls.count >= 8 && denseSmalls.dropFirst(4).prefix(4).allSatisfy {
            $0.frame.minX >= 160 && $0.frame.maxX <= 320 && $0.frame.minY >= 320 && $0.frame.maxY <= 480
        }
        let denseUsedRows = denseTiles.map { tile in
            Int(tile.frame.minY.rounded(.down)) / 80 + tile.tileSize.dimensions.height
        }.max() ?? 0
        let denseMinimal = hasNoEarlierEmptyMediumSlot(denseAfter) && denseUsedRows == 6

        let denseDragView = Win8StartScreenView(settings: settings, coversTaskbar: false)
        denseDragView.frame = SnapshotFixture.screenFrame
        denseDragView.layoutSubtreeIfNeeded()
        denseDragView.debugSetScrollOrigin(.zero)
        denseDragView.debugBeginDrag(sourceIndex: 0)
        for percent in stride(from: 0, through: 100, by: 10) {
            denseDragView.debugSetDragProgress(CGFloat(percent) / 100)
            save(denseDragView, to: directory.appendingPathComponent(String(format: "dense-drag-%03d.png", percent)))
        }
        let densePreviewOrder = denseDragView.debugDragOrder
        let densePreviewFrames = denseDragView.debugViewFrames
        let densePreviewGap = denseDragView.debugDragGapFrame
        let densePreviewKey = denseDragView.debugDragKey
        denseDragView.debugEndDrag()
        let denseDropOrder = keys(denseDragView)
        let denseDropFrames = frames(denseDragView)
        let denseExpectedFrames = denseDragView.debugPackedFrames(for: denseDropOrder)
        let densePreviewEqualsDrop = densePreviewOrder == denseDropOrder &&
            densePreviewFrames.allSatisfy { key, frame in
                key == densePreviewKey || denseDropFrames[key] == frame
            } &&
            densePreviewKey.flatMap { key in
                guard let gap = densePreviewGap, let frame = denseDropFrames[key] else { return false }
                return gap == frame
            } == true && denseDropFrames == denseExpectedFrames
        save(denseDragView, to: directory.appendingPathComponent("dense-drag-drop.png"))
        guard secondSmallBlock, denseMinimal, densePreviewEqualsDrop else {
            fputs("FAIL win8 edit snapshot dense layout smallBlock=\(secondSmallBlock) minimal=\(denseMinimal) previewDrop=\(densePreviewEqualsDrop) usedRows=\(denseUsedRows)\n", stderr)
            return 1
        }

        for percent in stride(from: 0, through: 100, by: 25) {
            customView.debugSetDragProgress(CGFloat(percent) / 100)
            save(customView, to: directory.appendingPathComponent(String(format: "drag-%03d.png", percent)))
        }
        print("PASS win8 edit snapshots \(directory.path)")
        return 0
    }

    static func renderFrames(to directory: URL) -> Int {
        SnapshotFixture.activate()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = Win8StartScreenView(settings: SnapshotFixture.settings, coversTaskbar: false)
        view.frame = SnapshotFixture.screenFrame
        view.layoutSubtreeIfNeeded()
        view.debugPrepareForFrames()
        let tiles = view.debugTiles()
        let entranceTimes = [0, 60, 120, 180, 240, 300, 360, 450]
        for milliseconds in entranceTimes {
            let p = CGFloat(min(1, Double(milliseconds) / (Win8TileAnimation.entranceDuration * 1000)))
            tiles.forEach { $0.debugSetEntrance(p) }
            save(view, to: directory.appendingPathComponent(String(format: "entrance-%03dms.png", milliseconds)))
        }
        if let tile = tiles.first(where: { $0.isWideTile }) ?? tiles.first(where: { $0.liveTile }) ?? tiles.first {
            for degrees in [0, 30, 60, 89, 91, 120, 150, 180] {
                tile.debugSetFlipAngle(CGFloat(degrees))
                saveProjectedFlip(view, tile: tile, degrees: CGFloat(degrees),
                                 to: directory.appendingPathComponent(String(format: "flip-%03ddeg.png", degrees)))
            }
            tile.debugSetPressed(true); save(view, to: directory.appendingPathComponent("press-down.png"))
            tile.debugSetPressed(false); save(view, to: directory.appendingPathComponent("press-up.png"))
            tile.debugSetHovered(true); save(view, to: directory.appendingPathComponent("hover-on.png"))
            tile.debugSetHovered(false); save(view, to: directory.appendingPathComponent("hover-off.png"))
        }
        for percent in [0, 25, 50, 75, 100] {
            view.debugSetTransition(CGFloat(percent) / 100)
            save(view, to: directory.appendingPathComponent(String(format: "transition-%03dpercent.png", percent)))
        }
        print("PASS win8 animation frames \(directory.path)")
        return 0
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = SnapshotFixture.bitmap(for: view) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func capture(_ view: NSView) -> CGImage? {
        guard let rep = SnapshotFixture.bitmap(for: view) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func saveGIF(_ frames: [CGImage], to url: URL) {
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString,
                                                                frames.count, nil) else { return }
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.06]
        ]
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
        for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary) }
        CGImageDestinationFinalize(destination)
    }

    private static func saveProjectedFlip(_ view: NSView, tile: Win8AppTile, degrees: CGFloat, to url: URL) {
        guard let tileRep = tile.debugFlatBitmap() else { return }
        let hidden = tile.isHidden
        tile.isHidden = true
        guard let baseRep = SnapshotFixture.bitmap(for: view) else { tile.isHidden = hidden; return }
        view.cacheDisplay(in: view.bounds, to: baseRep)
        tile.isHidden = hidden
        guard let baseImage = baseRep.cgImage, let tileImage = tileRep.cgImage else { return }

        let scale = CGFloat(baseRep.pixelsWide) / max(view.bounds.width, 1)
        let projectedDegrees = degrees > 90 ? degrees - 180 : degrees
        var transform = CATransform3DMakeRotation(projectedDegrees * .pi / 180, 1, 0, 0)
        transform.m34 = Win8TileAnimation.perspective
        let center = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
        func projected(_ point: CGPoint) -> CGPoint {
            let x = point.x - tile.bounds.midX
            let y = point.y - tile.bounds.midY
            let z: CGFloat = 0
            let tx = transform.m11 * x + transform.m21 * y + transform.m31 * z + transform.m41
            let ty = transform.m12 * x + transform.m22 * y + transform.m32 * z + transform.m42
            let tz = transform.m13 * x + transform.m23 * y + transform.m33 * z + transform.m43
            let tw = transform.m14 * x + transform.m24 * y + transform.m34 * z + transform.m44
            _ = tz
            let appKitPoint = CGPoint(x: center.x + tx / tw, y: center.y + ty / tw)
            return CGPoint(x: appKitPoint.x * scale,
                           y: (view.bounds.height - appKitPoint.y) * scale)
        }

        let topLeft = projected(CGPoint(x: tile.bounds.minX, y: tile.bounds.minY))
        let topRight = projected(CGPoint(x: tile.bounds.maxX, y: tile.bounds.minY))
        let bottomRight = projected(CGPoint(x: tile.bounds.maxX, y: tile.bounds.maxY))
        let bottomLeft = projected(CGPoint(x: tile.bounds.minX, y: tile.bounds.maxY))
        let filter = CIFilter(name: "CIPerspectiveTransform")
        filter?.setValue(CIImage(cgImage: tileImage), forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter?.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter?.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        filter?.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        guard let projectedTile = filter?.outputImage else { return }
        let base = CIImage(cgImage: baseImage)
        let composed = projectedTile.composited(over: base)
        let extent = CGRect(x: 0, y: 0, width: baseRep.pixelsWide, height: baseRep.pixelsHigh)
        guard let output = CIContext().createCGImage(composed, from: extent) else { return }
        let outputRep = NSBitmapImageRep(cgImage: output)
        outputRep.size = view.bounds.size
        guard let data = outputRep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
