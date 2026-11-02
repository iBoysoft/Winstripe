import AppKit

/// Snapshot-only stacks of real trays, retaining the taskbar's own background.
@MainActor
final class TraySnapshotView: NSView {
    private static let gutter: CGFloat = 4
    private var rows: [(name: String, view: NSView, tray: TrayView)] = []
    override var isFlipped: Bool { true }

    private struct Variant {
        let name: String
        let settings: TaskbarSettings
        var clock: String?
        var expanded = false
        var hovered = false
    }

    private static func variants(settings: TaskbarSettings) -> [Variant] {
        var result = [Variant(name: "defaults", settings: settings)]
        result.append(Variant(name: "clock-12h", settings: settings, clock: "9:41 PM"))
        result.append(Variant(name: "clock-24h", settings: settings, clock: "21:41"))
        func append(_ name: String, expanded: Bool = false,
                    configure: (inout TaskbarSettings) -> Void) {
            var value = settings
            configure(&value)
            result.append(Variant(name: name, settings: value, expanded: expanded))
        }
        append("no-clock") { $0.showClock = false }
        append("input") { $0.showInputLanguage = true }
        append("collapsed") { $0.showInputLanguage = true; $0.collapseTrayIcons = true }
        append("expanded", expanded: true) { $0.showInputLanguage = true; $0.collapseTrayIcons = true }
        append("desktop") { $0.showDesktopButton = true }
        append("no-desktop") { $0.showDesktopButton = false }
        append("everything-on", expanded: true) {
            $0.showInputLanguage = true
            $0.collapseTrayIcons = true
            $0.showDesktopButton = true
            $0.showClock = true
        }
        append("everything-off") {
            $0.showClock = false
            $0.showInputLanguage = false
            $0.showDesktopButton = false
            $0.collapseTrayIcons = false
        }
        if settings.theme == .win11 {
            result.append(Variant(name: "hovered", settings: settings, hovered: true))
        }
        return result
    }

    private static func bar(settings: TaskbarSettings, size: NSSize? = nil) -> TaskbarView {
        precondition(SnapshotFixture.isActive)
        let vertical = settings.edge.isVertical
        let size = size ?? NSSize(
            width: vertical ? TaskbarView.verticalWidth(for: settings) : SnapshotFixture.screenFrame.width,
            height: vertical ? SnapshotFixture.visibleFrame.height : TaskbarView.thickness(for: settings))
        let bar = TaskbarView(frame: NSRect(origin: .zero, size: size))
        bar.isPreview = true
        bar.usesStartOverflowPanel = settings.capabilities.startButtonOverflow && !vertical
        bar.settings = settings
        bar.clockText = SnapshotFixture.time(settings.resolvedLanguage)
        bar.dateText = SnapshotFixture.longDate(settings.resolvedLanguage)
        bar.shortDateText = Clock.shortDate()
        bar.inputText = "EN"
        bar.trayBadges = SnapshotFixture.trayBadges
        bar.reload()
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private init(settings: TaskbarSettings, vertical: Bool) {
        precondition(SnapshotFixture.isActive)
        var settings = settings
        settings.edge = vertical ? .left : .bottom
        let background = Self.bar(settings: settings)
        let horizontalHeight = background.tray.frame.height
        let trays = Self.variants(settings: settings).map { variant -> (String, TrayView) in
            // Reload configures input language, smoothing, theme accent and vertical
            // behavior exactly as the real taskbar does, before isolating the tray.
            let source = Self.bar(settings: variant.settings)
            let tray = source.tray
            tray.removeFromSuperview()
            tray.edge = variant.settings.edge
            tray.verticalLayout = vertical
            tray.showDesktop = variant.settings.showDesktopButton
            tray.expanded = variant.expanded
            tray.clockText = variant.clock ?? SnapshotFixture.time(settings.resolvedLanguage)
            tray.setSnapshotState(hovered: variant.hovered)
            tray.frame = NSRect(
                origin: .zero,
                size: NSSize(width: vertical ? TaskbarView.verticalWidth(for: settings) : tray.preferredWidth(),
                             height: vertical ? tray.preferredVerticalHeight : horizontalHeight))
            tray.arrange()
            return (variant.name, tray)
        }
        let gutter = Self.gutter
        let size = NSSize(width: (trays.map { $0.1.frame.width }.max() ?? 0) + gutter * 2,
                          height: trays.reduce(gutter) { $0 + $1.1.frame.height + gutter })
        super.init(frame: NSRect(origin: .zero, size: size))

        // Match ButtonSnapshotView: keep the actual bar and acrylic, hiding all
        // normal content even if caching triggers another taskbar layout pass.
        background.frame = bounds
        background.layoutSubtreeIfNeeded()
        for child in background.subviews where !(child is AcrylicView) {
            child.isHidden = true
            child.alphaValue = 0
        }
        addSubview(background)
        var y = gutter
        for (name, tray) in trays {
            tray.frame.origin = NSPoint(x: gutter, y: y)
            addSubview(tray)
            rows.append((name, tray, tray))
            y += tray.frame.height + gutter
        }
    }

    private init(bars: [(String, TaskbarView)]) {
        precondition(SnapshotFixture.isActive)
        let gutter = Self.gutter
        let size = NSSize(width: (bars.map { $0.1.frame.width }.max() ?? 0) + gutter * 2,
                          height: bars.reduce(gutter) { $0 + $1.1.frame.height + gutter })
        super.init(frame: NSRect(origin: .zero, size: size))
        var y = gutter
        for (name, bar) in bars {
            bar.frame.origin = NSPoint(x: gutter, y: y)
            addSubview(bar)
            rows.append((name, bar, bar.tray))
            y += bar.frame.height + gutter
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    @MainActor
    private struct LayoutRow {
        let sheet: String
        let variant: String
        let rowFrame: NSRect
        let trayFrame: NSRect
        let items: [(name: String, frame: NSRect)]

        init(sheet: String, variant: String, rowFrame: NSRect, tray: TrayView) {
            self.sheet = sheet
            self.variant = variant
            self.rowFrame = rowFrame
            trayFrame = tray.frame
            items = tray.debugItemRects
        }

        var json: String {
            func rect(_ rect: NSRect) -> String {
                let values = [rect.minX, rect.minY, rect.width, rect.height].map {
                    let rounded = (Double($0) * 100).rounded() / 100
                    return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                                  rounded == 0 ? 0 : rounded)
                }
                return "[" + values.joined(separator: ", ") + "]"
            }
            // All names are fixed ASCII identifiers defined in this file or
            // TrayView.debugItemRects. Keys and item order are explicit.
            let itemJSON = items.map {
                "{\"frame\": \(rect($0.frame)), \"name\": \"\($0.name)\"}"
            }.joined(separator: ", ")
            return """
                {"items": [\(itemJSON)], "rowFrame": \(rect(rowFrame)), "sheet": "\(sheet)", \
                "trayFrame": \(rect(trayFrame)), "variant": "\(variant)"}
            """
        }
    }

    static func writeSnapshots(to directory: URL,
                               saveView: (NSView, String) -> Void,
                               saveImage: (NSImage, String) -> Void) throws {
        precondition(SnapshotFixture.isActive)
        var layout: [LayoutRow] = []
        func save(_ sheet: TraySnapshotView, name: String, appearance: NSAppearance.Name) {
            sheet.appearance = NSAppearance(named: appearance)
            saveView(sheet, name)
            for row in sheet.rows {
                layout.append(LayoutRow(sheet: name, variant: row.name,
                                        rowFrame: row.view.frame, tray: row.tray))
            }
        }
        for kind in ThemeKind.allCases {
            var settings = SnapshotFixture.settings
            settings.theme = kind
            let id = SnapshotFixture.themeID(kind)
            let appearance: NSAppearance.Name = kind == .win10 ? .darkAqua : .aqua
            let sheet = TraySnapshotView(settings: settings, vertical: false)
            save(sheet, name: "tray-\(id).png", appearance: appearance)
            if kind == .win10 || kind == .win11 {
                save(sheet, name: "tray-\(id)-\(kind == .win10 ? "light" : "dark").png",
                     appearance: kind == .win10 ? .aqua : .darkAqua)
            }
            save(TraySnapshotView(settings: settings, vertical: true),
                 name: "tray-\(id)-vertical.png", appearance: appearance)
        }

        for kind in [ThemeKind.win95, .win7, .win10, .win11, .winXP] {
            var traySettings = SnapshotFixture.settings
            traySettings.theme = kind
            traySettings.collapseTrayIcons = true
            traySettings.trayApps = SnapshotFixture.trayAppPaths
            save(TraySnapshotView(settings: traySettings, vertical: false),
                 name: "tray-apps-\(SnapshotFixture.themeID(kind)).png",
                 appearance: kind == .win10 ? .darkAqua : .aqua)
        }

        func appBar(_ kind: ThemeKind, collapse: Bool, alwaysShow: [String] = []) -> TaskbarView {
            var value = SnapshotFixture.settings
            value.theme = kind
            value.collapseTrayIcons = collapse
            value.trayApps = SnapshotFixture.trayAppPaths
            value.trayAppsAlwaysShow = alwaysShow
            let result = bar(settings: value)
            result.tray.expanded = false
            result.reload()
            result.layoutSubtreeIfNeeded()
            return result
        }
        let off95 = appBar(.win95, collapse: false)
        saveView(off95.tray, "tray-overflow-off-win95.png")
        let off7 = appBar(.win7, collapse: false)
        saveView(off7.tray, "tray-overflow-off-win7.png")
        let on7 = appBar(.win7, collapse: true, alwaysShow: [SnapshotFixture.trayAppPaths[0]])
        saveView(on7.tray, "tray-overflow-on-win7.png")
        for kind in [ThemeKind.win7, .win10, .win11] {
            let value = appBar(kind, collapse: true)
            value.tray.openOverflowPanel(taskbarFrame: NSRect(x: 0, y: 0, width: value.bounds.width,
                                                              height: TaskbarView.thickness(for: value.settings)), edge: .bottom)
            if let panelView = value.tray.overflowPanelContentView {
                let barHeight = value.bounds.height
                let canvas = NSView(frame: NSRect(x: 0, y: 0, width: value.bounds.width,
                                                  height: barHeight + panelView.bounds.height + 8))
                value.frame.origin = .zero
                canvas.addSubview(value)
                let panelFrame = value.tray.overflowPanelFrame
                panelView.frame.origin = NSPoint(x: panelFrame?.minX ?? value.bounds.width - panelView.bounds.width - 8,
                                                 y: barHeight + 8)
                canvas.addSubview(panelView)
                saveView(canvas, "tray-overflow-panel-\(SnapshotFixture.themeID(kind)).png")
                if kind == .win11 {
                    canvas.appearance = NSAppearance(named: .darkAqua)
                    saveView(canvas, "tray-overflow-panel-win11-dark.png")
                }
            }
        }

        let chevronWin11 = appBar(.win11, collapse: true)
        chevronWin11.appearance = NSAppearance(named: .aqua)
        chevronWin11.tray.appearance = NSAppearance(named: .aqua)
        saveView(chevronWin11.tray, "tray-overflow-chevron-win11.png")
        chevronWin11.appearance = NSAppearance(named: .darkAqua)
        chevronWin11.tray.appearance = NSAppearance(named: .darkAqua)
        saveView(chevronWin11.tray, "tray-overflow-chevron-win11-dark.png")

        let toggleClosed = appBar(.win11, collapse: true)
        toggleClosed.tray.appearance = NSAppearance(named: .aqua)
        saveView(toggleClosed.tray, "tray-chevron-toggle-win11-closed.png")
        toggleClosed.tray.openOverflowPanel(
            taskbarFrame: NSRect(x: 0, y: 0, width: toggleClosed.bounds.width,
                                 height: TaskbarView.thickness(for: toggleClosed.settings)),
            edge: .bottom)
        if let panelView = toggleClosed.tray.overflowPanelContentView {
            let barHeight = toggleClosed.bounds.height
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: toggleClosed.bounds.width,
                                              height: barHeight + panelView.bounds.height + 8))
            toggleClosed.frame.origin = .zero
            canvas.addSubview(toggleClosed)
            let panelFrame = toggleClosed.tray.overflowPanelFrame
            panelView.frame.origin = NSPoint(x: panelFrame?.minX ?? toggleClosed.bounds.width - panelView.bounds.width - 8,
                                             y: barHeight + 8)
            canvas.addSubview(panelView)
            saveView(canvas, "tray-chevron-toggle-win11-open.png")
        }

        func imeBar(_ kind: ThemeKind, edge: TaskbarEdge, size: NSSize) -> TaskbarView {
            var value = SnapshotFixture.settings
            value.theme = kind
            value.edge = edge
            value.showInputLanguage = true
            value.collapseTrayIcons = true
            value.trayApps = SnapshotFixture.trayAppPaths
            let result = bar(settings: value, size: size)
            result.tray.expanded = false
            result.reload()
            result.layoutSubtreeIfNeeded()
            return result
        }
        saveView(imeBar(.win95, edge: .bottom, size: NSSize(width: 180, height: 40)).tray,
                 "ime-always-classic.png")
        saveView(imeBar(.win10, edge: .left, size: NSSize(width: 160, height: 307)).tray,
                 "ime-always-win10-vertical.png")
        saveView(imeBar(.win11, edge: .bottom, size: NSSize(width: 280, height: 40)).tray,
                 "ime-always-win11.png")

        var win8 = SnapshotFixture.settings
        win8.theme = .win8
        win8.edge = .bottom
        win8.showInputLanguage = true
        win8.showClock = true
        win8.showDesktopButton = true
        let fullWidth = ceil(bar(settings: win8).tray.preferredWidth()) + 44
        let widths = [fullWidth, fullWidth - 1, fullWidth - 29, CGFloat(94)]
        let win8Bars = widths.map { width in
            ("width-\(Int(width))", bar(settings: win8, size: NSSize(width: width, height: 40)))
        }
        // Lock in the intended threshold cases: optional flag first, while
        // the language cell remains mandatory at every width.
        let win8Items = win8Bars.map { $0.1.tray.debugItemRects.map(\.name) }
        precondition(win8Items[0].contains("actionCenter") && win8Items[0].contains("input"))
        precondition(!win8Items[1].contains("actionCenter") && win8Items[1].contains("input"))
        precondition(!win8Items[2].contains("actionCenter") && win8Items[2].contains("input"))
        save(TraySnapshotView(bars: win8Bars), name: "tray-win8-narrow.png", appearance: .aqua)

        var win10 = SnapshotFixture.settings
        win10.theme = .win10
        win10.edge = .left
        win10.showInputLanguage = true
        win10.collapseTrayIcons = true
        win10.showClock = true
        win10.showDesktopButton = true
        let fullTray = bar(settings: win10)
        fullTray.trayExpanded = true
        fullTray.reload()
        let fullHeight = fullTray.tray.preferredVerticalHeight
        let heights = [fullHeight + 44, fullHeight + 43, fullHeight + 23, fullHeight - 1]
        let win10Bars = heights.map { height in
            let bar = bar(settings: win10, size: NSSize(width: TaskbarView.verticalWidth(for: win10), height: height))
            bar.trayExpanded = true
            bar.reload()
            return ("height-\(Int(height))", bar)
        }
        let win10Items = win10Bars.map { $0.1.tray.debugItemRects.map(\.name) }
        precondition(!win10Items[0].contains("chevron") && win10Items[0].contains("actionCenter")
                     && win10Items[0].contains("input"))
        precondition(!win10Items[1].contains("chevron") && !win10Items[1].contains("actionCenter")
                     && win10Items[1].contains("input"))
        precondition(!win10Items[2].contains("actionCenter") && win10Items[2].contains("input"))
        precondition(win10Items[3].contains("input"))
        save(TraySnapshotView(bars: win10Bars), name: "tray-win10-vertical-narrow.png", appearance: .darkAqua)

        func notification(settings: TaskbarSettings, name: String, variant: String) {
            let image = PreviewRenderer.stripImage(
                settings: settings, kind: .notification, apps: [], activePID: nil,
                snapshotTrayLayout: { tray in
                    layout.append(LayoutRow(
                        sheet: name, variant: variant,
                        rowFrame: NSRect(x: 0, y: 0, width: PreviewRenderer.stripWidth,
                                         height: TaskbarView.thickness(for: settings)),
                        tray: tray))
                })
            saveImage(image, name)
        }
        for kind in ThemeKind.allCases {
            var settings = SnapshotFixture.settings
            settings.theme = kind
            notification(settings: settings, name: "properties-notification-\(SnapshotFixture.themeID(kind)).png",
                         variant: "defaults")
        }
        var classic = SnapshotFixture.settings
        classic.theme = .win95
        classic.collapseTrayIcons.toggle()
        notification(settings: classic, name: "properties-notification-win95-collapse.png", variant: "collapse")
        classic = SnapshotFixture.settings
        classic.theme = .win95
        classic.showInputLanguage.toggle()
        notification(settings: classic, name: "properties-notification-win95-input.png", variant: "input")
        let json = "{\n  \"rows\": [\n" + layout.map { "    " + $0.json }.joined(separator: ",\n") + "\n  ]\n}\n"
        try Data(json.utf8).write(to: directory.appendingPathComponent("tray-layout.json"))
    }
}
