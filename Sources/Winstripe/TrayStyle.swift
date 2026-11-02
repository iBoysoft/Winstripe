import AppKit

/// Resolved once at load time. Layout is the only tray strategy discriminator.
struct TrayStyle {
    enum Layout: String { case linear, aero, win8 }
    enum Chevron: String { case text, symbol, aeroTriangle }
    enum Input: String { case badge, text }
    enum Action: String { case speechBubble, flag }
    enum Desktop: String { case classicButton, hairline, aeroStrip, none }
    enum Trigger: String { case heightOver, verticalLayout }
    enum Placement: String { case fixed, flow, center, trailing }
    enum Extent: String { case fixed, bounds, remaining }
    enum Measure: String { case clockText, maxClockDate }
    enum Fill: String { case none, solid, gradient }

    struct Paint {
        let base: ThemeColor
        let alpha: CGFloat
        let appliesAlpha: Bool
        @MainActor var color: NSColor {
            let color = base.resolve(settings: TaskbarSettings())
            return appliesAlpha ? color.withAlphaComponent(alpha) : color
        }
    }
    struct Rect {
        let x, y, width, height, insetX, insetY, minWidth, minHeight: CGFloat
        let xPlacement, yPlacement: Placement
        let widthMode, heightMode: Extent
        let floorY, centerUsesMidY, clampWidth, clampHeight, widthWhenVisible, heightWhenVisible: Bool

        func resolve(in bounds: NSRect, flowX: CGFloat = 0, flowY: CGFloat = 0,
                     right: CGFloat, visible: Bool = true) -> NSRect {
            let rx = xPlacement == .trailing ? right - x : xPlacement == .flow ? flowX + x : x
            var w = widthMode == .bounds ? bounds.width - insetX * 2
                : widthMode == .remaining ? right - rx - insetX * 2 : width
            var h = heightMode == .bounds ? bounds.height - insetY * 2 : height
            if clampWidth { w = max(minWidth, w) }
            if clampHeight { h = max(minHeight, h) }
            if widthWhenVisible && !visible { w = 0 }
            if heightWhenVisible && !visible { h = 0 }
            var ry = yPlacement == .center ? (centerUsesMidY ? bounds.midY - h / 2 : (bounds.height - h) / 2) + y
                : yPlacement == .trailing ? bounds.height - y
                : yPlacement == .flow ? flowY + y : y
            if floorY { ry = floor(ry) }
            return NSRect(x: rx, y: ry, width: w, height: h)
        }
    }
    struct ChevronStyle {
        let style: Chevron
        let alwaysShown, drawsText, paintWhenHidden: Bool
        let advance, drawAdvance: CGFloat
        let collapsed, expanded, titleCollapsed, titleExpanded, symbolCollapsed, symbolExpanded: String
        let font, fontVertical: NSFont
        let color: Paint
        let frame, frameVertical, drawRect: Rect
    }
    struct InputStyle {
        let style: Input
        let width, advance, drawAdvance: CGFloat
        let fixedText, fixedTextHorizontal, fixedTextVertical: String
        let maxChars: Int
        let ignoresCollapse: Bool
        let font, fontVertical: NSFont
        let color, fill: Paint
        let rect, rectVertical: Rect
    }
    struct AppIconStyle {
        let width, advance, drawAdvance, verticalAdvance, iconSize, gap: CGFloat
        let rect, rectVertical: Rect
        let chrome: CellChrome
    }
    struct CellChrome {
        let fill: Paint
        let bevel: [(Paint, Paint)]
        let hover: Hover

        @MainActor
        func draw(in rect: NSRect, hovered: Bool, pressed: Bool) {
            fill.color.setFill()
            rect.fill()
            let down = pressed && hover.enabled
            for (index, layer) in bevel.enumerated() {
                Retro.edge(index == 0 ? rect : rect.insetBy(dx: CGFloat(index), dy: CGFloat(index)),
                           tl: (down ? layer.1 : layer.0).color,
                           br: (down ? layer.0 : layer.1).color)
            }
            guard hover.enabled, hovered || pressed else { return }
            hover.color.color.setFill()
            let highlight = hover.rect.resolve(in: rect, right: rect.width)
            NSBezierPath(roundedRect: highlight, xRadius: hover.radius, yRadius: hover.radius).fill()
        }
    }
    struct ActionStyle {
        let style: Action
        let advance, drawAdvance, rightReserve: CGFloat
        let symbol: String
        let toggles: Bool
        let offsetsBounds, offsetsBoundsVertical: Bool
        let color: Paint
        let frame, frameVertical: Rect
    }
    struct ClockLine {
        let offsetY, height: CGFloat
        let halves, fullHeight: Bool
        let font, fontVertical: NSFont
    }
    struct ClockStyle {
        let measure: Measure
        let measureFont, measureDateFont: NSFont
        let measureFallback: String
        let ceil: Bool
        let minWidth, extraWidth: CGFloat
        let color: Paint
        let alignment: NSTextAlignment
        let rect, rectVertical: Rect
        let lines: [ClockLine]
        let verticalHalves: Bool
    }
    struct DesktopStyle {
        let style: Desktop
        let reserve, drawReserve, drawReserveWhenHidden: CGFloat
        let frame, frameVertical, line, lineVertical: Rect
        let color, colorVertical: Paint
    }
    struct Row {
        let name: String
        let height: CGFloat
        let always, preferred: Bool
    }
    struct Vertical {
        let supported: Bool
        let trigger: Trigger
        let threshold, base, trailing, contentBase: CGFloat
        let rows: [Row]
        let dropOrder: [String]
        let stacked, buttonRows: Bool
        let minRow, rowCount, actionRow, desktopReserve: CGFloat
        func height(_ name: String) -> CGFloat { rows.first { $0.name == name }?.height ?? 0 }
    }
    struct Container {
        let fill: Fill
        let angle: CGFloat
        let colors: [Paint]
        let bevel: [(Paint, Paint)]
        let leadingBorder: Paint
        let hasLeadingBorder: Bool
        let leadingBorderWidth: CGFloat
        let leadingLines: [(x: CGFloat, y: CGFloat, width: CGFloat, insetY: CGFloat, color: Paint)]
    }
    struct Hover {
        let enabled: Bool
        let rect: Rect
        let radius: CGFloat
        let color: Paint
    }
    struct Win8 {
        let leading, horizontalInset, verticalInset, trailing: CGFloat
        let inputWidth, inputHeight, actionWidth, actionHeight, clockHeight, clockVerticalHeight, desktop: CGFloat
        let clockMinWidth, clockExtraWidth: CGFloat
    }

    let layout: Layout
    let items: [String]
    let baseWidth, minWidth, contentLeading: CGFloat
    let widthClamp: ClosedRange<CGFloat>
    let followsSmoothingSetting: Bool
    let chevronStyle: ChevronStyle
    let inputStyle: InputStyle
    let inputChrome: CellChrome
    let appIconStyle: AppIconStyle
    let actionStyle: ActionStyle
    let clockStyle: ClockStyle
    let desktopStyle: DesktopStyle
    let vertical: Vertical
    let container: Container
    let hover: Hover
    let win8: Win8

    var alwaysChevron: Bool { chevronStyle.alwaysShown }
    var supportsVertical: Bool { vertical.supported }
    var hasActionCenter: Bool { items.contains("actionCenter") }
    var showDesktopAllowed: Bool { desktopStyle.style != .none }
    var desktop: Desktop { desktopStyle.style }
    var inputFixedText: String { inputStyle.fixedText }

    init() { self.init(ThemeLoader().load("win95").theme) }

    init(_ resolved: ResolvedTheme) {
        let json = resolved.json
        let defaults = ThemeLoader.resolvedBuiltinJSON(resolved.config.family == .classic ? "win95" : "win11")
        func at(_ json: ThemeJSON, _ path: String) -> ThemeJSON? {
            path.split(separator: ".").reduce(Optional(json)) { node, key in
                if case .array(let values)? = node, let index = Int(key), values.indices.contains(index) { return values[index] }
                return node?[String(key)]
            }
        }
        func node(_ path: String) -> ThemeJSON? { at(json, path) ?? at(defaults, path) }
        func n(_ path: String, _ fallback: CGFloat = 0) -> CGFloat { CGFloat(node(path)?.number ?? Double(fallback)) }
        func s(_ path: String, _ fallback: String = "") -> String { node(path)?.string ?? fallback }
        func b(_ path: String, _ fallback: Bool = false) -> Bool {
            if case .bool(let value)? = node(path) { return value }
            return fallback
        }
        func array(_ path: String) -> [ThemeJSON] {
            if case .array(let values)? = node(path) { return values }
            return []
        }
        func paint(_ path: String, _ fallback: ThemeColor = .system("labelColor"), alphaPath: String = "") -> Paint {
            let base = (try? ThemeColor.parse(node(path) ?? .null, palette: resolved.config.palette)) ?? fallback
            return Paint(base: base, alpha: n(alphaPath, 1), appliesAlpha: !alphaPath.isEmpty && node(alphaPath)?.number != nil)
        }
        func font(_ path: String) -> NSFont {
            var value = node(path)
            if let ref = value?["ref"]?.string { value = node("fonts." + ref) }
            let size = CGFloat(value?["size"]?.number ?? 11)
            let family = value?["family"]?.string ?? "system"
            let weight = value?["weight"]?.string ?? ""
            if family == "system" {
                return .systemFont(ofSize: size, weight: weight == "semibold" ? .semibold : .regular)
            }
            return NSFont(name: family, size: size)
                ?? (value?["fallback"]?.string == "systemBold" ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }
        func rect(_ p: String) -> Rect {
            Rect(x: n(p + ".x"), y: n(p + ".y"), width: n(p + ".width"), height: n(p + ".height"),
                 insetX: n(p + ".insetX"), insetY: n(p + ".insetY"),
                 minWidth: n(p + ".minWidth"), minHeight: n(p + ".minHeight"),
                 xPlacement: Placement(rawValue: s(p + ".xPlacement", "fixed")) ?? .fixed,
                 yPlacement: Placement(rawValue: s(p + ".yPlacement", "fixed")) ?? .fixed,
                 widthMode: Extent(rawValue: s(p + ".widthMode", "fixed")) ?? .fixed,
                 heightMode: Extent(rawValue: s(p + ".heightMode", "bounds")) ?? .bounds,
                 floorY: b(p + ".floorY"), centerUsesMidY: b(p + ".centerUsesMidY"),
                 clampWidth: b(p + ".clampWidth"), clampHeight: b(p + ".clampHeight"),
                 widthWhenVisible: b(p + ".widthWhenVisible"), heightWhenVisible: b(p + ".heightWhenVisible"))
        }
        layout = Layout(rawValue: resolved.config.tray.layout) ?? .linear
        items = resolved.config.tray.items
        baseWidth = n("tray.baseWidth"); minWidth = n("tray.minWidth"); contentLeading = n("tray.contentLeading", 4)
        let clamp = array("tray.widthClamp").compactMap(\.number)
        widthClamp = clamp.count == 2 ? CGFloat(clamp[0])...CGFloat(clamp[1]) : 0...CGFloat.greatestFiniteMagnitude
        followsSmoothingSetting = s("tray.smoothing") == "setting"
        let cp = "tray.chevron"
        chevronStyle = ChevronStyle(
            style: Chevron(rawValue: s(cp + ".style", "symbol")) ?? .symbol,
            alwaysShown: b(cp + ".alwaysShown"), drawsText: b(cp + ".drawsText"), paintWhenHidden: b(cp + ".paintWhenHidden"),
            advance: n(cp + ".advance"), drawAdvance: n(cp + ".drawAdvance"),
            collapsed: s(cp + ".collapsed"), expanded: s(cp + ".expanded"),
            titleCollapsed: s(cp + ".titleCollapsed"), titleExpanded: s(cp + ".titleExpanded"),
            symbolCollapsed: s(cp + ".symbolCollapsed"), symbolExpanded: s(cp + ".symbolExpanded"),
            font: font(cp + ".font"), fontVertical: font(cp + ".fontVertical"), color: paint(cp + ".color"),
            frame: rect(cp + ".frame"), frameVertical: rect(cp + ".frameVertical"), drawRect: rect(cp + ".drawRect"))
        let ip = "tray.inputLanguage"
        inputStyle = InputStyle(
            style: Input(rawValue: s(ip + ".style", "text")) ?? .text, width: n(ip + ".width"),
            advance: n(ip + ".advance"), drawAdvance: n(ip + ".drawAdvance"),
            fixedText: s(ip + ".fixedText"), fixedTextHorizontal: s(ip + ".fixedTextHorizontal"),
            fixedTextVertical: s(ip + ".fixedTextVertical"),
            maxChars: Int(n(ip + ".maxChars")), ignoresCollapse: b(ip + ".ignoresCollapse"),
            font: font(ip + ".font"), fontVertical: font(ip + ".fontVertical"), color: paint(ip + ".textColor"),
            fill: paint(ip + ".fill", .system("clear")), rect: rect(ip + ".rect"), rectVertical: rect(ip + ".rectVertical"))
        inputChrome = CellChrome(fill: inputStyle.fill, bevel: [],
                                 hover: Hover(enabled: false, rect: inputStyle.rect, radius: 0,
                                              color: paint(ip + ".fill", .system("clear"))))
        let ap = "tray.actionCenter"
        actionStyle = ActionStyle(
            style: Action(rawValue: s(ap + ".style", "flag")) ?? .flag,
            advance: n(ap + ".advance"), drawAdvance: n(ap + ".drawAdvance"), rightReserve: n(ap + ".rightReserve"),
            symbol: s(ap + ".symbol"), toggles: b(ap + ".toggles"),
            offsetsBounds: b(ap + ".offsetsBounds"), offsetsBoundsVertical: b(ap + ".offsetsBoundsVertical"),
            color: paint(ap + ".color"),
            frame: rect(ap + ".frame"), frameVertical: rect(ap + ".frameVertical"))
        let kp = "tray.clock"
        clockStyle = ClockStyle(
            measure: Measure(rawValue: s(kp + ".measure", "maxClockDate")) ?? .maxClockDate,
            measureFont: font(kp + ".measureFont"), measureDateFont: font(kp + ".measureDateFont"),
            measureFallback: s(kp + ".measureFallback"), ceil: b(kp + ".ceil"),
            minWidth: n(kp + ".minWidth"), extraWidth: n(kp + ".extraWidth"), color: paint(kp + ".color"),
            alignment: s(kp + ".alignment") == "center" ? .center : .left,
            rect: rect(kp + ".rect"), rectVertical: rect(kp + ".rectVertical"),
            lines: array(kp + ".lines").indices.map { index in
                let p = kp + ".lines.\(index)"
                return ClockLine(offsetY: n(p + ".offsetY"), height: n(p + ".height"),
                                 halves: b(p + ".halves"), fullHeight: b(p + ".fullHeight"),
                                 font: font(p + ".font"), fontVertical: font(p + ".fontVertical"))
            }, verticalHalves: b(kp + ".verticalHalves"))
        let dp = "tray.showDesktop"
        desktopStyle = DesktopStyle(
            style: Desktop(rawValue: s(dp + ".style", "none")) ?? .none,
            reserve: n(dp + ".reserve"), drawReserve: n(dp + ".drawReserve"),
            drawReserveWhenHidden: n(dp + ".drawReserveWhenHidden"),
            frame: rect(dp + ".frame"), frameVertical: rect(dp + ".frameVertical"),
            line: rect(dp + ".line"), lineVertical: rect(dp + ".lineVertical"),
            color: paint(dp + ".line.color", alphaPath: dp + ".line.alpha"),
            colorVertical: paint(dp + ".lineVertical.color", alphaPath: dp + ".lineVertical.alpha"))
        let vp = "tray.vertical"
        vertical = Vertical(
            supported: b(vp + ".supported"), trigger: Trigger(rawValue: s(vp + ".trigger", "verticalLayout")) ?? .verticalLayout,
            threshold: n(vp + ".threshold"), base: n(vp + ".base"), trailing: n(vp + ".trailing"),
            contentBase: n(vp + ".contentBase"),
            rows: array(vp + ".rows").indices.map { index in
                let p = vp + ".rows.\(index)"
                return Row(name: s(p + ".name"), height: n(p + ".height"), always: b(p + ".always"),
                           preferred: b(p + ".preferred", true))
            }, dropOrder: array(vp + ".dropOrder").compactMap(\.string),
            stacked: b(vp + ".stacked"), buttonRows: b(vp + ".buttonRows"),
            minRow: n(vp + ".minRow"), rowCount: n(vp + ".rowCount", 1),
            actionRow: n(vp + ".actionRow"), desktopReserve: n(vp + ".desktopReserve"))
        let aip = "tray.appIcon"
        let appRect = node(aip + ".rect") == nil ? inputStyle.rect : rect(aip + ".rect")
        let appRectVertical = node(aip + ".rectVertical") == nil ? inputStyle.rectVertical : rect(aip + ".rectVertical")
        let classicTray = resolved.config.id == "win95" || resolved.config.id == "win98"
        let appBevelName = s(aip + ".bevel", classicTray ? "statusField" : "")
        let appBevel = resolved.bevels[appBevelName] ?? []
        let appBevelPaint = appBevel.map {
            (Paint(base: $0.topLeft, alpha: 1, appliesAlpha: false),
             Paint(base: $0.bottomRight, alpha: 1, appliesAlpha: false))
        }
        let appHover = Hover(enabled: node("tray.hover")?.object != nil,
                             rect: rect("tray.hover.rect"), radius: n("tray.hover.radius"),
                             color: paint("tray.hover.fill.color", alphaPath: "tray.hover.fill.alpha"))
        let appAdvance = n(aip + ".advance", inputStyle.advance > 0 ? inputStyle.advance : inputStyle.width)
        let appDrawAdvance = n(aip + ".drawAdvance", inputStyle.drawAdvance > 0 ? inputStyle.drawAdvance : appAdvance)
        let verticalRow = n(aip + ".verticalAdvance", vertical.height("inputLanguage"))
        let appIconSize = n(aip + ".iconSize", resolved.config.family == .classic ? 16 : 18)
        appIconStyle = AppIconStyle(
            width: n(aip + ".width", inputStyle.width), advance: appAdvance, drawAdvance: appDrawAdvance,
            verticalAdvance: verticalRow > 0 ? verticalRow : appAdvance, iconSize: appIconSize,
            gap: n(aip + ".gap", resolved.config.family == .modern ? 6 : 2),
            rect: appRect, rectVertical: appRectVertical,
            chrome: CellChrome(fill: paint(aip + ".fill", .system("clear")), bevel: appBevelPaint, hover: appHover))
        let containerPath = "tray.container"
        let material = resolved.config.tray.container.fill
        let colors: [Paint]
        if material.type == "solid" { colors = [paint(containerPath + ".fill.color")] }
        else {
            colors = array(containerPath + ".fill.stops").indices.map { index in
                let p = containerPath + ".fill.stops.\(index)"
                return paint(node(p)?["color"] == nil ? p : p + ".color")
            }
        }
        let bevel = resolved.bevels[resolved.config.tray.container.bevel ?? ""] ?? []
        container = Container(
            fill: Fill(rawValue: material.type) ?? .none, angle: CGFloat(material.angle ?? 0), colors: colors,
            bevel: bevel.map { (Paint(base: $0.topLeft, alpha: 1, appliesAlpha: false),
                               Paint(base: $0.bottomRight, alpha: 1, appliesAlpha: false)) },
            leadingBorder: paint(containerPath + ".leadingBorder"),
            hasLeadingBorder: node(containerPath + ".leadingBorder").map { $0 != .null } ?? false,
            leadingBorderWidth: n(containerPath + ".fill.params.leadingBorderWidth"),
            leadingLines: array(containerPath + ".leadingLines").indices.map { index in
                let p = containerPath + ".leadingLines.\(index)"
                return (n(p + ".x"), n(p + ".y"), n(p + ".width"), n(p + ".insetY"), paint(p + ".color", alphaPath: p + ".alpha"))
            })
        hover = Hover(enabled: node("tray.hover")?.object != nil,
                      rect: rect("tray.hover.rect"), radius: n("tray.hover.radius"),
                      color: paint("tray.hover.fill.color", alphaPath: "tray.hover.fill.alpha"))
        let wp = "tray.win8"
        win8 = Win8(leading: n(wp + ".leading"), horizontalInset: n(wp + ".horizontalInset"),
                    verticalInset: n(wp + ".verticalInset"), trailing: n(wp + ".trailing"),
                    inputWidth: n(wp + ".inputWidth"), inputHeight: n(wp + ".inputHeight"),
                    actionWidth: n(wp + ".actionWidth"), actionHeight: n(wp + ".actionHeight"),
                    clockHeight: n(wp + ".clockHeight"), clockVerticalHeight: n(wp + ".clockVerticalHeight"),
                    desktop: n(wp + ".desktop"), clockMinWidth: clockStyle.minWidth, clockExtraWidth: clockStyle.extraWidth)
    }
}
