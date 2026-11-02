import AppKit

/// Paint/debug rectangles and child hit targets can differ without duplicating layout.
struct TrayItemRect {
    let name: String
    var rect: NSRect
    var visible: Bool
    var paintRect: NSRect
    var childRect: NSRect
    var childVisible: Bool
}

@MainActor
private final class TrayBadgeOverlay: NSView {
    var label: String?
    var iconSize: CGFloat = 16
    var cellSize: NSSize?
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let cell = NSRect(origin: .zero, size: cellSize ?? bounds.size)
        let baseFont = NSFont.systemFont(ofSize: max(7, min(9, iconSize * 0.55)), weight: .bold)
        let font = TrayBadgeLayout.font(for: cell, label: label, baseFont: baseFont)
        let iconRect = TrayBadgeLayout.iconRect(in: cell, iconSize: iconSize)
        guard let badgeRect = TrayBadgeLayout.rect(for: cell, iconRect: iconRect, label: label, font: font),
              let content = TrayBadgeLayout.content(for: label) else { return }
        NSColor.systemRed.setFill()
        if content == .dot {
            NSBezierPath(ovalIn: badgeRect).fill()
            return
        }
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeRect.height / 2, yRadius: badgeRect.height / 2).fill()
        switch content {
        case .text(let text):
            Retro.drawTextUntruncated(text, in: badgeRect, font: font, color: .white, smoothing: true, alignment: .center)
        case .dot: break
        }
    }
}

@MainActor
private final class TrayAppButton: NSView {
    var icon: NSImage? { didSet { needsDisplay = true } }
    var theme = Theme.make(.win95) { didSet { needsDisplay = true } }
    var smoothing = true { didSet { needsDisplay = true } }
    var iconSize: CGFloat = 16 { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.trayStyle.appIconStyle.chrome.draw(in: bounds, hovered: hovered, pressed: pressed)
        guard let icon else { return }
        let size = min(iconSize, min(bounds.width, bounds.height))
        let destination = NSRect(x: floor(bounds.midX - size / 2), y: floor(bounds.midY - size / 2),
                                  width: size, height: size)
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high]
        icon.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: hints)
    }
}

@MainActor
private final class TrayOverflowGridView: NSView {
    private let apps: [TrayAppInfo]
    private let theme: Theme
    private let badges: [String: String]
    private let badgeProvider: ((TrayAppInfo) -> String?)?
    private let onSelect: (TrayAppInfo) -> Void
    private let cell: CGFloat
    private let gap: CGFloat = 4
    private let padding: CGFloat
    private let radius: CGFloat
    private var buttons: [TrayAppButton] = []
    private var overlays: [TrayBadgeOverlay] = []

    init(apps: [TrayAppInfo], theme: Theme, badges: [String: String],
         badgeProvider: ((TrayAppInfo) -> String?)?, onSelect: @escaping (TrayAppInfo) -> Void) {
        self.apps = apps
        self.theme = theme
        self.badges = badges
        self.badgeProvider = badgeProvider
        self.onSelect = onSelect
        cell = theme.kind == .win11 ? 36 : 34
        padding = theme.kind == .win11 ? 10 : 8
        radius = theme.kind == .win11 ? 8 : 0
        let columns = max(1, min(4, apps.count))
        let rows = Int(ceil(Double(apps.count) / Double(columns)))
        let width = padding * 2 + CGFloat(columns) * cell + CGFloat(max(0, columns - 1)) * gap
        let height = padding * 2 + CGFloat(rows) * cell + CGFloat(max(0, rows - 1)) * gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        for app in apps {
            let button = TrayAppButton()
            button.icon = app.icon
            button.theme = theme
            button.iconSize = theme.trayStyle.appIconStyle.iconSize
            button.toolTip = app.name
            button.onClick = { [weak self] in self?.onSelect(app) }
            addSubview(button)
            buttons.append(button)
            let overlay = TrayBadgeOverlay()
            overlay.iconSize = theme.trayStyle.appIconStyle.iconSize
            overlay.label = badgeProvider?(app) ?? badges[app.path] ?? badges[app.name]
            addSubview(overlay)
            overlays.append(overlay)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill: NSColor = {
            switch theme.kind {
            case .win11: return NSColor(calibratedWhite: dark ? 0.12 : 0.96, alpha: 0.94)
            case .win10: return NSColor(hex: dark ? 0x2B2B2B : 0xF3F3F3, alpha: 0.98)
            default: return theme.face
            }
        }()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(dark ? 0.28 : 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        let columns = max(1, min(4, buttons.count))
        for index in buttons.indices {
            let column = index % columns
            let row = index / columns
            let frame = NSRect(x: padding + CGFloat(column) * (cell + gap),
                               y: padding + CGFloat(row) * (cell + gap), width: cell, height: cell)
            buttons[index].frame = frame
            overlays[index].frame = frame
            overlays[index].cellSize = frame.size
        }
    }
}

@MainActor
final class TrayOverflowPanel: NSPanel {
    let apps: [TrayAppInfo]
    let cornerRadius: CGFloat
    private var monitor: Any?
    private var globalMonitor: Any?
    private let isToggleLocation: (NSPoint) -> Bool

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(apps: [TrayAppInfo], theme: Theme, badges: [String: String],
         badgeProvider: ((TrayAppInfo) -> String?)?, onSelect: @escaping (TrayAppInfo) -> Void,
         onClose: @escaping () -> Void,
         isToggleLocation: @escaping (NSPoint) -> Bool = { _ in false }) {
        self.apps = apps
        self.isToggleLocation = isToggleLocation
        cornerRadius = theme.kind == .win11 ? 8 : 0
        let grid = TrayOverflowGridView(apps: apps, theme: theme, badges: badges,
                                        badgeProvider: badgeProvider, onSelect: onSelect)
        super.init(contentRect: grid.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = grid
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { onClose(); return nil }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let point = NSEvent.mouseLocation
                if !self.frame.contains(point) && !self.isToggleLocation(point) {
                    onClose()
                    return event
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if self.isToggleLocation(NSEvent.mouseLocation) { return }
            onClose()
        }
    }

    override func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        monitor = nil
        globalMonitor = nil
        super.close()
    }

    static func size(appCount: Int, theme: Theme) -> NSSize {
        let columns = max(1, min(4, appCount))
        let rows = Int(ceil(Double(appCount) / Double(columns)))
        let cell: CGFloat = theme.kind == .win11 ? 36 : 34
        let padding: CGFloat = theme.kind == .win11 ? 10 : 8
        return NSSize(width: padding * 2 + CGFloat(columns) * cell + CGFloat(max(0, columns - 1)) * 4,
                      height: padding * 2 + CGFloat(rows) * cell + CGFloat(max(0, rows - 1)) * 4)
    }
}

@MainActor
final class TrayView: NSView {
    private var usesModernTrayChevron: Bool {
        switch theme.kind {
        case .win11: return theme.trayStyle.chevronStyle.style == .symbol
        case .win10: return theme.trayStyle.chevronStyle.style != .aeroTriangle
        default: return false
        }
    }
    var theme = Theme.make(.win95) {
        didSet {
            chevron.trayChevron = usesModernTrayChevron
            chevron.trayChevronThin = theme.kind == .win11 && usesModernTrayChevron
            needsDisplay = true
        }
    }
    var smoothing = true { didSet { needsDisplay = true } }
    var clockText = "" { didSet { needsDisplay = true } }
    var dateText = "" { didSet { needsDisplay = true } }
    var showClock = true
    var inputText = "EN" { didSet { needsDisplay = true } }
    var showInput = false
    var collapse = false
    var expanded = false
    var showDesktop = false
    var verticalLayout = false
    var edge: TaskbarEdge = .bottom
    var language: Language = .english
    var trayApps: [String] = [] { didSet { if trayApps != oldValue { rebuildTrayApps() } } }
    var trayAppsAlwaysShow: [String] = [] { didSet { if trayAppsAlwaysShow != oldValue { needsLayout = true; arrange() } } }
    var trayBadges: [String: String] = [:] {
        didSet { needsDisplay = true; if !trayAppButtons.isEmpty { arrange() } }
    }
    var badgeProvider: ((TrayAppInfo) -> String?)? {
        didSet { needsDisplay = true; if !trayAppButtons.isEmpty { arrange() } }
    }
    var onShowDesktop: (() -> Void)?
    var onToggle: (() -> Void)?
    var onOverflowPanelChanged: (() -> Void)?

    private let chevron = RetroButton()
    private let actionCenter = RetroButton()
    private let desktopButton = RetroButton()
    private var trayAppButtons: [TrayAppButton] = []
    private var trayBadgeOverlays: [TrayBadgeOverlay] = []
    private var resolvedTrayApps: [TrayAppInfo] = []
    private var overflowPanel: TrayOverflowPanel?
    private var hovered = false { didSet { needsDisplay = true } }

    func setSnapshotState(hovered: Bool) {
        precondition(SnapshotFixture.isActive)
        self.hovered = hovered
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.kind = .plain
        chevron.onClick = { [weak self] in self?.onToggle?() }
        actionCenter.kind = .plain
        actionCenter.toolTip = L.t("Action Center", .english)
        addSubview(actionCenter)
        desktopButton.kind = .plain
        desktopButton.onClick = { [weak self] in self?.onShowDesktop?() }
        addSubview(chevron)
        addSubview(desktopButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    private var trayStyle: TrayStyle { theme.trayStyle }
    private var inlineTrayAppIndices: [Int] {
        guard !collapse else {
            if theme.classic && expanded { return Array(resolvedTrayApps.indices) }
            return resolvedTrayApps.indices.filter { trayAppsAlwaysShow.contains(resolvedTrayApps[$0].path) }
        }
        return Array(resolvedTrayApps.indices)
    }
    private var collapsedTrayAppIndices: [Int] {
        guard collapse else { return [] }
        let inline = Set(inlineTrayAppIndices)
        return resolvedTrayApps.indices.filter { !inline.contains($0) }
    }
    private var trayAppsVisible: Bool { !inlineTrayAppIndices.isEmpty }
    private var hasCollapsedTrayApps: Bool { !collapsedTrayAppIndices.isEmpty }
    private var showChevron: Bool {
        trayStyle.alwaysChevron || (collapse && (hasCollapsedTrayApps || (theme.classic && !resolvedTrayApps.isEmpty)))
    }
    /// Modern themes have no chevron item of their own; they add one only for tray apps,
    /// so trays without apps keep their original layout.
    private var showAddedChevron: Bool {
        showChevron && (trayStyle.items.contains("chevron") || !resolvedTrayApps.isEmpty)
    }
    private var inputVisible: Bool {
        // The input method cell is a system status item, so it remains visible
        // regardless of tray collapse state. Keep the JSON flag for theme
        // compatibility, but do not allow it to hide the cell.
        showInput
    }
    private var trayIconAdvance: CGFloat { trayStyle.appIconStyle.advance }
    private var trayIconDrawAdvance: CGFloat { trayStyle.appIconStyle.drawAdvance }
    private var trayIconVerticalAdvance: CGFloat { trayStyle.appIconStyle.verticalAdvance }
    private var trayIconSize: CGFloat { trayStyle.appIconStyle.iconSize }

    private func rebuildTrayApps() {
        overflowPanel?.close()
        overflowPanel = nil
        resolvedTrayApps = trayApps.compactMap(TrayAppInfo.resolve)
        for button in trayAppButtons { button.removeFromSuperview() }
        for overlay in trayBadgeOverlays { overlay.removeFromSuperview() }
        trayAppButtons = resolvedTrayApps.map { app in
            let button = TrayAppButton()
            button.icon = app.icon
            button.toolTip = app.name
            button.onClick = { app.activate() }
            addSubview(button)
            return button
        }
        trayBadgeOverlays = resolvedTrayApps.map { _ in
            let overlay = TrayBadgeOverlay()
            overlay.wantsLayer = true
            addSubview(overlay)
            return overlay
        }
        needsLayout = true
        needsDisplay = true
    }

    var isOverflowPanelOpen: Bool { overflowPanel?.isVisible == true }
    var collapsedTrayAppsForPanel: [TrayAppInfo] { collapsedTrayAppIndices.map { resolvedTrayApps[$0] } }
    var overflowPanelFrame: NSRect? { overflowPanel?.frame }
    var overflowPanelItemCount: Int { overflowPanel?.apps.count ?? 0 }
    var overflowPanelContentView: NSView? { overflowPanel?.contentView }
    var overflowPanelCornerRadius: CGFloat { overflowPanel?.cornerRadius ?? 0 }
    var debugChevronGlyph: String { chevron.symbol ?? chevron.title }

    func toggleOverflowPanel(taskbarFrame: NSRect, edge: TaskbarEdge) {
        if isOverflowPanelOpen {
            closeOverflowPanel()
        } else {
            openOverflowPanel(taskbarFrame: taskbarFrame, edge: edge)
        }
    }

    func openOverflowPanel(taskbarFrame: NSRect, edge: TaskbarEdge) {
        guard !theme.classic, collapse, !collapsedTrayAppIndices.isEmpty else { return }
        overflowPanel?.close()
        let apps = collapsedTrayAppIndices.map { resolvedTrayApps[$0] }
        let chevronRect = itemRects().first(where: { $0.name == "chevron" && $0.visible })?.rect
        let toggleScreenRect: NSRect? = chevronRect.map {
            NSRect(x: taskbarFrame.minX + frame.minX + $0.minX,
                   y: taskbarFrame.minY + frame.minY + $0.minY,
                   width: $0.width, height: $0.height)
        }
        let panel = TrayOverflowPanel(apps: apps, theme: theme, badges: trayBadges,
                                      badgeProvider: badgeProvider,
                                      onSelect: { [weak self] app in
                                          app.activate()
                                          self?.closeOverflowPanel()
                                      },
                                      onClose: { [weak self] in self?.closeOverflowPanel() },
                                      isToggleLocation: { point in
                                          guard let toggleScreenRect else { return false }
                                          return toggleScreenRect.insetBy(dx: -2, dy: -2).contains(point)
                                      })
        let size = TrayOverflowPanel.size(appCount: apps.count, theme: theme)
        let anchor = chevronRect
        let localAnchor = anchor.map { NSPoint(x: frame.minX + $0.midX, y: frame.minY + $0.midY) }
            ?? NSPoint(x: frame.midX, y: frame.midY)
        let screenAnchor = NSPoint(x: taskbarFrame.minX + localAnchor.x,
                                   y: taskbarFrame.minY + localAnchor.y)
        var origin = NSPoint(x: screenAnchor.x - size.width / 2, y: taskbarFrame.maxY + 8)
        switch edge {
        case .bottom: origin = NSPoint(x: screenAnchor.x - size.width / 2, y: taskbarFrame.maxY + 8)
        case .top: origin = NSPoint(x: screenAnchor.x - size.width / 2, y: taskbarFrame.minY - size.height - 8)
        case .left: origin = NSPoint(x: taskbarFrame.maxX + 8, y: screenAnchor.y - size.height / 2)
        case .right: origin = NSPoint(x: taskbarFrame.minX - size.width - 8, y: screenAnchor.y - size.height / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        overflowPanel = panel
        expanded = true
        arrange()
        onOverflowPanelChanged?()
    }

    func closeOverflowPanel() {
        overflowPanel?.close()
        overflowPanel = nil
        expanded = false
        arrange()
        onOverflowPanelChanged?()
    }
    private var paintVertical: Bool {
        let v = trayStyle.vertical
        return v.trigger == .heightOver ? bounds.height > v.threshold : verticalLayout
    }
    private func visible(_ name: String) -> Bool {
        switch name {
        case "chevron": return showChevron
        case "inputLanguage", "input": return inputVisible
        case "clock": return showClock
        case "showDesktop", "desktop": return showDesktop
        case "actionCenter": return trayStyle.hasActionCenter
        case let name where name.hasPrefix("trayApp"):
            return trayAppsVisible
        default: return false
        }
    }

    var preferredVerticalHeight: CGFloat {
        let v = trayStyle.vertical
        return v.base + (trayAppsVisible ? trayIconVerticalAdvance * CGFloat(inlineTrayAppIndices.count) + trayStyle.appIconStyle.gap * 2 : 0) + v.rows.reduce(CGFloat.zero) {
            $0 + ($1.preferred && ($1.always || visible($1.name)) ? $1.height : 0)
        } + v.trailing
    }

    private var measuredClockWidth: CGFloat {
        let c = trayStyle.clockStyle
        let text = c.measure == .clockText && clockText.isEmpty ? c.measureFallback : clockText
        let clock = Retro.textSize(text, font: c.measureFont).width
        let width = c.measure == .clockText ? clock : max(clock, Retro.textSize(dateText, font: c.measureDateFont).width)
        return c.ceil ? ceil(width) : width
    }

    func preferredWidth() -> CGFloat {
        let s = trayStyle
        let advances: [(String, CGFloat)] = [
            ("chevron", s.chevronStyle.advance), ("inputLanguage", s.inputStyle.advance),
            ("actionCenter", s.actionStyle.advance)
        ]
        var width = s.baseWidth
        for (name, advance) in advances where s.items.contains(name) && visible(name) { width += advance }
        if showAddedChevron && !s.items.contains("chevron") { width += s.chevronStyle.advance }
        if trayAppsVisible { width += trayIconAdvance * CGFloat(inlineTrayAppIndices.count) + trayStyle.appIconStyle.gap * 2 }
        if trayAppsVisible && showDesktop { width += trayStyle.appIconStyle.gap }
        if trayAppsVisible && s.hasActionCenter { width += trayStyle.appIconStyle.gap }
        if showClock { width += max(s.clockStyle.minWidth, measuredClockWidth + s.clockStyle.extraWidth) }
        if showDesktop { width += s.desktopStyle.reserve }
        return max(width, s.minWidth)
    }

    override func layout() {
        super.layout()
        arrange()
    }

    /// The three strategies share resolved rect expressions. Only Win8 owns a separate
    /// packing algorithm; row dropping and hit-target rows are independent policies.
    func itemRects() -> [TrayItemRect] {
        let s = trayStyle
        let v = s.vertical
        let vertical = paintVertical
        let desktop = s.desktopStyle
        let right = bounds.width - (showDesktop ? desktop.drawReserve : desktop.drawReserveWhenHidden)
            - s.actionStyle.rightReserve
            - (trayAppsVisible && showDesktop ? s.appIconStyle.gap : 0)
        func frame(_ horizontal: TrayStyle.Rect, _ upright: TrayStyle.Rect, right: CGFloat,
                   visible: Bool) -> NSRect {
            (verticalLayout ? upright : horizontal).resolve(in: bounds, right: right, visible: visible)
        }
        func item(_ name: String, _ rect: NSRect, _ visible: Bool,
                  paint: NSRect? = nil, child: NSRect? = nil, childVisible: Bool? = nil) -> TrayItemRect {
            TrayItemRect(name: name, rect: rect, visible: visible, paintRect: paint ?? rect,
                         childRect: child ?? rect, childVisible: childVisible ?? visible)
        }
        switch s.layout {
        case .win8:
            var layout = Win8TrayLayout(bounds: bounds, vertical: verticalLayout,
                                        showInput: showInput, showClock: showClock,
                                        showDesktop: showDesktop, clockWidth: measuredClockWidth, config: s.win8)
            if trayAppsVisible {
                let reserve = s.appIconStyle.gap * 2 + CGFloat(inlineTrayAppIndices.count) * s.appIconStyle.advance
                if verticalLayout {
                    layout.clock.origin.y += reserve
                    layout.clock.size.height = max(0, layout.clock.height - reserve)
                    if !layout.flag.isEmpty { layout.flag.origin.y += reserve + s.appIconStyle.gap }
                    if !layout.desktop.isEmpty { layout.desktop.origin.y += reserve + s.appIconStyle.gap * 2 }
                } else {
                    layout.clock.origin.x += reserve
                    layout.clock.size.width = max(0, layout.clock.width - reserve)
                    if !layout.flag.isEmpty { layout.clock.size.width = max(0, layout.clock.width - s.appIconStyle.gap) }
                }
            }
            if showAddedChevron {
                if verticalLayout {
                    layout.input.origin.y += s.chevronStyle.advance
                    if inputVisible && (trayAppsVisible || hasCollapsedTrayApps) {
                        layout.input.origin.y += s.appIconStyle.gap
                    }
                    layout.clock.origin.y += s.chevronStyle.advance
                    layout.flag.origin.y += s.chevronStyle.advance
                    layout.desktop.origin.y += s.chevronStyle.advance
                } else {
                    layout.input.origin.x += s.chevronStyle.advance
                    if inputVisible && (trayAppsVisible || hasCollapsedTrayApps) {
                        layout.input.origin.x += s.appIconStyle.gap
                    }
                    layout.clock.origin.x += s.chevronStyle.advance
                    layout.flag.origin.x += s.chevronStyle.advance
                    layout.desktop.origin.x += s.chevronStyle.advance
                }
            }
            let chevronFrame = frame(s.chevronStyle.frame, s.chevronStyle.frameVertical,
                                     right: bounds.width, visible: false)
            var result = [
                item("chevron", chevronFrame, showAddedChevron), item("actionCenter", layout.flag, !layout.flag.isEmpty),
                item("desktop", layout.desktop, !layout.desktop.isEmpty),
                item("input", layout.input, !layout.input.isEmpty),
                item("clock", layout.clock, !layout.clock.isEmpty)
            ]
            if verticalLayout && showAddedChevron,
               let index = result.firstIndex(where: { $0.name == "chevron" }) {
                result[index].rect = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
                result[index].paintRect = result[index].rect
            }
            if trayAppsVisible {
                if verticalLayout {
                    let start = layout.input.isEmpty ? 0 : layout.input.maxY + s.appIconStyle.gap
                    for (offset, index) in inlineTrayAppIndices.enumerated() {
                        let y = start + CGFloat(offset) * trayIconVerticalAdvance
                        let width = bounds.width - (showDesktop ? desktop.reserve : 0)
                        result.append(item("trayApp\(index)", NSRect(x: 0, y: y, width: max(0, width),
                                                                       height: max(trayIconSize, trayIconVerticalAdvance - s.appIconStyle.gap)), true))
                    }
                } else {
                    let start = layout.input.isEmpty ? s.win8.leading : layout.input.maxX + s.appIconStyle.gap
                    for (offset, index) in inlineTrayAppIndices.enumerated() {
                        let x = start + CGFloat(offset) * s.appIconStyle.advance
                        let rect = NSRect(x: x, y: 0, width: s.appIconStyle.width, height: bounds.height)
                        result.append(item("trayApp\(index)", rect, true))
                    }
                }
            }
            return result
        case .linear, .aero:
            var chevronFrame = frame(s.chevronStyle.frame, s.chevronStyle.frameVertical,
                                     right: bounds.width, visible: showChevron)
            var actionFrame = frame(s.actionStyle.frame, s.actionStyle.frameVertical,
                                    right: bounds.width - (showDesktop ? desktop.reserve : 0), visible: s.hasActionCenter)
            let desktopFrame = frame(desktop.frame, desktop.frameVertical, right: bounds.width, visible: showDesktop)
            if verticalLayout && v.buttonRows {
                let row = max(v.minRow, floor((bounds.height - (showDesktop ? v.desktopReserve : 0)) / v.rowCount))
                chevronFrame = NSRect(x: 0, y: 0, width: bounds.width, height: showChevron ? row : 0)
                actionFrame = NSRect(x: 0, y: row * v.actionRow, width: bounds.width, height: row)
                if trayAppsVisible && showChevron { actionFrame.origin.y += s.appIconStyle.gap }
            }
            if trayAppsVisible && verticalLayout && showChevron && !v.buttonRows && !actionFrame.isEmpty {
                actionFrame.origin.y += s.appIconStyle.gap
            }
            let actionGap = trayAppsVisible && !verticalLayout && showChevron && !actionFrame.isEmpty
                && actionFrame.minX <= chevronFrame.maxX ? s.appIconStyle.gap : 0
            if actionGap > 0 { actionFrame.origin.x += actionGap }
            var result = [
                item("chevron", chevronFrame, showChevron && s.items.contains("chevron"),
                     paint: s.chevronStyle.drawRect.resolve(in: bounds, flowX: s.contentLeading, right: right)),
                item("actionCenter", actionFrame, s.hasActionCenter),
                item("desktop", desktopFrame, showDesktop)
            ]
            if vertical && v.stacked {
                var included = ["chevron": showChevron, "actionCenter": s.hasActionCenter, "inputLanguage": inputVisible]
                func total() -> CGFloat {
                    // The clock reserves its row even when hidden, matching the original drop policy.
                    v.height("clock") + (showDesktop ? v.height("showDesktop") : 0)
                        + CGFloat(trayAppsVisible ? inlineTrayAppIndices.count : 0) * trayIconVerticalAdvance
                        + included.reduce(CGFloat.zero) { $0 + ($1.value ? v.height($1.key) : 0) }
                }
                // Input language is mandatory. Drop optional controls in the
                // theme's order, skipping it even if legacy JSON lists it.
                for name in v.dropOrder where name != "inputLanguage" && total() > bounds.height {
                    included[name] = false
                }
                var y: CGFloat = 0
                for name in ["chevron", "actionCenter"] where included[name] == true {
                    let rect = NSRect(x: 0, y: y, width: bounds.width, height: v.height(name))
                    if let index = result.firstIndex(where: { $0.name == name }) {
                        result[index].rect = rect
                        result[index].paintRect = rect
                    }
                    y += v.height(name)
                    if trayAppsVisible { y += s.appIconStyle.gap }
                }
                if included["inputLanguage"] == true {
                    let rect = NSRect(x: 0, y: y, width: bounds.width, height: v.height("inputLanguage"))
                    result.append(item("input", rect, true))
                    y += v.height("inputLanguage")
                }
                if trayAppsVisible {
                    y += s.appIconStyle.gap
                    for index in inlineTrayAppIndices {
                        let width = bounds.width - (showDesktop ? desktop.reserve : 0)
                        let rect = NSRect(x: 0, y: y, width: max(0, width),
                                          height: max(trayIconSize, trayIconVerticalAdvance - s.appIconStyle.gap))
                        result.append(item("trayApp\(index)", rect, true))
                        y += trayIconVerticalAdvance
                    }
                    y += s.appIconStyle.gap
                }
                for index in result.indices where ["chevron", "actionCenter"].contains(result[index].name) {
                    result[index].visible = included[result[index].name] == true
                }
                var clock = s.clockStyle.rectVertical.resolve(in: bounds, flowY: y, right: right)
                if showClock {
                    let desktopReserve = showDesktop ? v.height("showDesktop") : 0
                    clock.size.height = min(clock.height, max(0, bounds.height - y - desktopReserve))
                    clock.origin.y = min(clock.origin.y, max(0, bounds.height - desktopReserve - clock.height))
                }
                result.append(item("clock", clock, showClock))
                // Historical debug order puts the desktop child before the action glyph.
                result.swapAt(1, 2)
                return result
            }
            var x = s.contentLeading + (showChevron ? s.chevronStyle.drawAdvance : 0)
                + (s.hasActionCenter ? s.actionStyle.drawAdvance + actionGap * 2 : 0)
            var y = v.contentBase + (showChevron ? v.height("chevron") : 0)
            let mandatoryInputGap = showChevron && inputVisible && (trayAppsVisible || hasCollapsedTrayApps)
                ? s.appIconStyle.gap : 0
            if verticalLayout { y += mandatoryInputGap }
            else { x += mandatoryInputGap }
            if verticalLayout && v.buttonRows && trayAppsVisible {
                if showChevron { y += s.appIconStyle.gap }
                if s.hasActionCenter { y += v.height("actionCenter") + s.appIconStyle.gap }
            }
            if inputVisible {
                if trayAppsVisible && verticalLayout && !actionFrame.isEmpty {
                    y = max(y, actionFrame.maxY + s.appIconStyle.gap)
                }
                let rect = (vertical ? s.inputStyle.rectVertical : s.inputStyle.rect)
                    .resolve(in: bounds, flowX: x, flowY: y, right: right)
                result.append(item("input", rect, true))
                x += s.inputStyle.drawAdvance
                y += v.height("inputLanguage")
                // Some vertical themes use a fixed input-language rect. When tray
                // apps are present, continue the flow after that resolved rect so
                // the app cells cannot overlap the input cell.
                if trayAppsVisible && verticalLayout {
                    y = max(y, rect.maxY)
                }
            }
            if trayAppsVisible {
                if verticalLayout && !actionFrame.isEmpty {
                    y = max(y, actionFrame.maxY + s.appIconStyle.gap)
                }
                if verticalLayout && showChevron {
                    y = max(y, chevronFrame.maxY + s.appIconStyle.gap)
                }
                x += vertical ? 0 : s.appIconStyle.gap
                y += vertical ? s.appIconStyle.gap : 0
                for index in inlineTrayAppIndices {
                    let rect: NSRect
                    if vertical {
                        let width = bounds.width - (showDesktop ? desktop.reserve : 0)
                        rect = NSRect(x: 0, y: y, width: max(0, width),
                                      height: max(trayIconSize, trayIconVerticalAdvance - s.appIconStyle.gap))
                        y += trayIconVerticalAdvance
                    } else {
                        let resolved = s.appIconStyle.rect.resolve(in: bounds, flowX: x, right: right)
                        rect = resolved.isEmpty
                            ? NSRect(x: x, y: max(0, (bounds.height - trayIconSize) / 2),
                                     width: s.appIconStyle.width, height: trayIconSize)
                            : resolved
                        x += trayIconDrawAdvance
                    }
                    result.append(item("trayApp\(index)", rect, true))
                }
                x += vertical ? 0 : s.appIconStyle.gap
                y += vertical ? s.appIconStyle.gap : 0
            }
            let clock = (vertical ? s.clockStyle.rectVertical : s.clockStyle.rect)
                .resolve(in: bounds, flowX: x, flowY: y, right: right)
            var resolvedClock = clock
            if trayAppsVisible && verticalLayout && showClock {
                // Vertical themes such as Win11 keep a fixed clock rect. Inline
                // tray apps consume rows above it, so move the clock below the
                // final app cell while preserving its width and height.
                resolvedClock.origin.y = max(resolvedClock.origin.y, y)
            }
            result.append(item("clock", resolvedClock, showClock))
            return result
        }
    }

    func arrange() {
        let s = trayStyle
        var laidOutApps = Set<Int>()
        for geometry in itemRects() {
            let button: RetroButton
            switch geometry.name {
            case "chevron": button = chevron
            case "actionCenter": button = actionCenter
            case "desktop": button = desktopButton
            default:
                if let index = Int(String(geometry.name.dropFirst("trayApp".count))), index < trayAppButtons.count {
                    let trayButton = trayAppButtons[index]
                    laidOutApps.insert(index)
                    trayButton.theme = theme
                    trayButton.smoothing = smoothing
                    trayButton.iconSize = trayIconSize
                    trayButton.frame = geometry.childRect
                    trayButton.isHidden = !geometry.childVisible
                    let overlay = trayBadgeOverlays[index]
                    let app = resolvedTrayApps[index]
                    overlay.iconSize = trayIconSize
                    overlay.label = badgeProvider?(app) ?? trayBadges[app.path] ?? trayBadges[app.name]
                    let cell = NSRect(origin: .zero, size: geometry.childRect.size)
                    let baseFont = NSFont.systemFont(ofSize: max(7, min(9, trayIconSize * 0.55)), weight: .bold)
                    let font = TrayBadgeLayout.font(for: cell, label: overlay.label, baseFont: baseFont)
                    let icon = TrayBadgeLayout.iconRect(in: cell, iconSize: trayIconSize)
                    let badgeWidth = TrayBadgeLayout.rect(for: cell, iconRect: icon, label: overlay.label, font: font)?.maxX ?? cell.width
                    overlay.cellSize = cell.size
                    overlay.frame = NSRect(x: geometry.childRect.minX, y: geometry.childRect.minY,
                                           width: max(cell.width, badgeWidth), height: cell.height)
                    overlay.isHidden = !geometry.childVisible
                    overlay.needsDisplay = true
                }
                continue
            }
            button.theme = theme
            if geometry.name != "desktop" { button.smoothing = smoothing }
            button.frame = geometry.childRect
            button.isHidden = !geometry.childVisible
        }
        for index in trayAppButtons.indices where !laidOutApps.contains(index) {
            trayAppButtons[index].isHidden = true
            trayAppButtons[index].frame = .zero
            trayBadgeOverlays[index].isHidden = true
            trayBadgeOverlays[index].frame = .zero
        }
        chevron.title = expanded ? s.chevronStyle.titleExpanded : s.chevronStyle.titleCollapsed
        let symbol = expanded ? s.chevronStyle.symbolExpanded : s.chevronStyle.symbolCollapsed
        chevron.symbol = symbol.isEmpty ? nil : symbol
        actionCenter.symbol = s.actionStyle.symbol.isEmpty ? nil : s.actionStyle.symbol
        if !s.actionStyle.symbol.isEmpty || s.actionStyle.toggles { actionCenter.toolTip = L.t("Action Center", language) }
        actionCenter.onClick = s.actionStyle.toggles ? { [weak self] in self?.onToggle?() } : nil
        desktopButton.aeroDesktopStrip = s.desktopStyle.style == .aeroStrip
        desktopButton.toolTip = L.t("Show Desktop", language)
        desktopButton.title = ""
        chevron.trayChevron = usesModernTrayChevron
        chevron.trayChevronThin = theme.kind == .win11 && usesModernTrayChevron
        if chevron.trayChevron {
            switch edge {
            case .bottom: chevron.symbol = expanded ? "chevron.down" : "chevron.up"
            case .top: chevron.symbol = expanded ? "chevron.up" : "chevron.down"
            case .left: chevron.symbol = expanded ? "chevron.left" : "chevron.right"
            case .right: chevron.symbol = expanded ? "chevron.right" : "chevron.left"
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = trayStyle
        let c = s.container
        if c.fill == .solid, let color = c.colors.first {
            color.color.setFill()
            bounds.fill()
        } else if c.fill == .gradient,
                  let gradient = NSGradient(colors: c.colors.map(\.color)) {
            gradient.draw(in: NSBezierPath(rect: bounds), angle: c.angle)
        }
        if c.fill == .solid, !c.bevel.isEmpty {
            for (index, layer) in c.bevel.enumerated() {
                Retro.edge(index == 0 ? bounds : bounds.insetBy(dx: CGFloat(index), dy: CGFloat(index)),
                           tl: layer.0.color, br: layer.1.color)
            }
        } else if c.hasLeadingBorder {
            c.leadingBorder.color.setFill()
            NSRect(x: 0, y: 0, width: c.leadingBorderWidth, height: bounds.height).fill()
        }
        for line in c.leadingLines {
            line.color.color.setFill()
            NSRect(x: line.x, y: line.y, width: line.width, height: bounds.height - line.insetY * 2).fill()
        }
        let right = bounds.width - (showDesktop ? s.desktopStyle.drawReserve : s.desktopStyle.drawReserveWhenHidden)
        if hovered && s.hover.enabled {
            s.hover.color.color.setFill()
            NSBezierPath(roundedRect: s.hover.rect.resolve(in: bounds, right: right),
                         xRadius: s.hover.radius, yRadius: s.hover.radius).fill()
        }
        let geometry = itemRects()
        var order = paintVertical && s.vertical.stacked
            ? ["chevron", "actionCenter", "inputLanguage", "clock", "showDesktop"] : s.items
        if showAddedChevron && !order.contains("chevron") { order.insert("chevron", at: 0) }
        let smooth = s.followsSmoothingSetting ? smoothing : true
        for name in order {
            let key = name == "inputLanguage" ? "input" : name == "showDesktop" ? "desktop" : name
            guard let item = geometry.first(where: { $0.name == key }),
                  item.visible || (key == "chevron" && s.chevronStyle.paintWhenHidden) else { continue }
            let rect = item.paintRect
            switch key {
            case "chevron":
                if chevron.trayChevron {
                    break
                } else if s.chevronStyle.style == .aeroTriangle {
                    let center = NSPoint(x: item.childRect.midX, y: item.childRect.midY)
                    let direction: CGFloat = expanded ? -1 : 1
                    let arrow = NSBezierPath()
                    arrow.move(to: NSPoint(x: center.x - 3.5, y: center.y + 2 * direction))
                    arrow.line(to: NSPoint(x: center.x, y: center.y - 2 * direction))
                    arrow.line(to: NSPoint(x: center.x + 3.5, y: center.y + 2 * direction))
                    arrow.close()
                    s.chevronStyle.color.color.setFill()
                    arrow.fill()
                } else if s.chevronStyle.drawsText {
                    Retro.drawText(expanded ? s.chevronStyle.expanded : s.chevronStyle.collapsed, in: rect,
                                   font: paintVertical ? s.chevronStyle.fontVertical : s.chevronStyle.font,
                                   color: s.chevronStyle.color.color, smoothing: smooth, alignment: .center)
                }
            case "input":
                if s.inputStyle.style == .badge {
                    s.inputChrome.draw(in: rect, hovered: false, pressed: false)
                }
                let fixed = paintVertical ? s.inputStyle.fixedTextVertical : s.inputStyle.fixedTextHorizontal
                var text = fixed.isEmpty ? inputText : fixed
                if s.inputStyle.maxChars > 0 && text.count > s.inputStyle.maxChars { text = String(text.prefix(s.inputStyle.maxChars)) }
                Retro.drawText(text, in: rect, font: paintVertical ? s.inputStyle.fontVertical : s.inputStyle.font,
                               color: s.inputStyle.color.color, smoothing: smooth, alignment: .center)
            case "clock":
                for (index, line) in s.clockStyle.lines.enumerated() {
                    let halves = line.halves || (paintVertical && s.clockStyle.verticalHalves)
                    let height = line.fullHeight ? rect.height : halves ? rect.height / 2 : line.height
                    let offset = halves ? CGFloat(index) * height : line.offsetY
                    let textRect = NSRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: height)
                    let font = paintVertical ? line.fontVertical : line.font
                    if theme.kind == .winXP {
                        Retro.drawText(index == 0 ? clockText : dateText, in: textRect.offsetBy(dx: 1, dy: 1),
                                       font: font, color: NSColor(hex: 0x0F4A9B), smoothing: smooth,
                                       alignment: s.clockStyle.alignment)
                    }
                    Retro.drawText(index == 0 ? clockText : dateText, in: textRect, font: font,
                                   color: s.clockStyle.color.color, smoothing: smooth, alignment: s.clockStyle.alignment)
                }
            case "actionCenter":
                if s.actionStyle.style == .speechBubble {
                    let offsets = paintVertical ? s.actionStyle.offsetsBoundsVertical : s.actionStyle.offsetsBounds
                    drawSpeechBubble(in: offsets ? rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY) : rect,
                                     color: s.actionStyle.color.color)
                }
            case "desktop":
                if s.desktopStyle.style == .hairline {
                    let spec = paintVertical ? s.desktopStyle.lineVertical : s.desktopStyle.line
                    (paintVertical ? s.desktopStyle.colorVertical : s.desktopStyle.color).color.setFill()
                    spec.resolve(in: bounds, flowX: rect.minX, flowY: rect.minY, right: bounds.width).fill()
                }
            default: break
            }
        }
    }

    var debugItemRects: [(name: String, frame: NSRect)] {
        itemRects().filter(\.visible).map { ($0.name, $0.rect) }
    }

    private func drawSpeechBubble(in rect: NSRect, color: NSColor) {
        let bubble = NSRect(x: rect.midX - 8, y: rect.midY - 7, width: 16, height: 12)
        color.setStroke()
        let path = NSBezierPath(roundedRect: bubble, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: bubble.minX + 4, y: bubble.maxY))
        path.line(to: NSPoint(x: bubble.minX + 2, y: bubble.maxY + 3))
        path.stroke()
    }
}
