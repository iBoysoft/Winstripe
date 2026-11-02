import AppKit

/// Fully resolved paint and geometry for modern (Aero/Win8/Win10/Win11) taskbar buttons.
/// Built once per theme load; every field is non-optional, with Windows 11 values as the
/// modern-family default so a theme missing keys cannot crash the renderer.
struct ModernButtonStyle {
    enum FillMaterial { case plate, aeroButton }
    enum NormalWhen: String { case never, task, runningTask, runningTitledTask }
    enum SymbolSource: String { case sfPlain, sfPalette, win8Glyph }
    enum TitleLayout: String { case afterImage, fixed }
    enum Indicator: String { case none, underline, pill }
    enum BadgeShape: String { case dot, pill }

    /// A colour plus an optional alpha applied at draw time with `withAlphaComponent`, so
    /// dynamic system colours (labelColor …) still follow the current appearance.
    struct Paint {
        let base: NSColor
        let alpha: CGFloat?
        var color: NSColor { alpha.map { base.withAlphaComponent($0) } ?? base }
    }

    struct Fill {
        let material: FillMaterial
        let hover: Paint
        let pressed: Paint
        let active: Paint
        let normal: Paint
        let activeTriggers: Bool
        let normalWhen: NormalWhen
        let inset: CGFloat
        let radius: CGFloat
    }
    struct Icon {
        let taskIconOnly: CGFloat
        let iconOnly: CGFloat
        let labelled: CGFloat
        let plain: CGFloat
        let smallIconUsesPlain: Bool
        let clampInset: CGFloat?
        let labelledX: CGFloat
        let centerWhenTitled: Bool
        let taskYOffsetIconOnly: CGFloat
        let taskYOffsetLabelled: CGFloat
        let symbolSource: SymbolSource
        let symbolColor: NSColor
        let symbolSize: CGFloat?
        let symbolLabelledX: CGFloat?
    }
    struct Title {
        let show: Bool
        let font: NSFont
        let centeredFont: NSFont
        let color: NSColor
        let layout: TitleLayout
        let iconGap: CGFloat
        let trailingInset: CGFloat
        let fixedX: CGFloat
        let followsSmoothingSetting: Bool
    }
    struct RunningIndicator {
        let type: Indicator
        let runningWidth: CGFloat
        let activeWidth: CGFloat
        let activeFullWidth: Bool
        let height: CGFloat
        let bottomInset: CGFloat
        let radius: CGFloat
        let runningColor: NSColor
        let activeColor: NSColor
    }
    struct Badge {
        let shape: BadgeShape
        let size: NSSize
        let offset: NSPoint
        let radius: CGFloat
        let fill: NSColor
        let textColor: NSColor
        let font: NSFont
        let showsText: Bool
        func rect(in r: NSRect) -> NSRect {
            NSRect(x: r.maxX + offset.x, y: offset.y, width: size.width, height: size.height)
        }
    }

    let fill: Fill
    let icon: Icon
    let tintQuickLaunchTemplateSymbols: Bool
    let title: Title
    let indicator: RunningIndicator
    let badge: Badge
    let aero: AeroButtonStyle
    let desktopStrip: AeroStripStyle?

    static func make(_ resolved: ResolvedTheme) -> ModernButtonStyle? {
        guard resolved.config.family == .modern else { return nil }
        let settings = TaskbarSettings()
        let json = resolved.json
        func node(_ path: String) -> ThemeJSON? { json.at(path.split(separator: ".").map(String.init)) }
        func number(_ path: String, _ fallback: CGFloat) -> CGFloat {
            if case .number(let n)? = node(path) { return CGFloat(n) }
            return fallback
        }
        func optionalNumber(_ path: String) -> CGFloat? {
            if case .number(let n)? = node(path) { return CGFloat(n) }
            return nil
        }
        func string(_ path: String, _ fallback: String) -> String { node(path)?.string ?? fallback }
        func bool(_ path: String, _ fallback: Bool) -> Bool {
            if case .bool(let b)? = node(path) { return b }
            return fallback
        }
        func color(_ path: String, _ fallback: NSColor) -> NSColor {
            resolved.colors[path]?.resolve(settings: settings) ?? fallback
        }
        /// A state fill: `fill.color`, with a sibling `fill.alpha` applied as NSColor.withAlphaComponent.
        func stateColor(_ state: String, _ fallback: NSColor, _ fallbackAlpha: CGFloat) -> Paint {
            guard let base = resolved.colors["buttons.task.\(state).fill.color"]?.resolve(settings: settings) else {
                return Paint(base: fallback, alpha: fallbackAlpha)
            }
            return Paint(base: base, alpha: optionalNumber("buttons.task.\(state).fill.alpha"))
        }
        func font(_ path: String, _ fallback: NSFont) -> NSFont {
            guard let d = resolved.fonts[path] else { return fallback }
            let size = CGFloat(d.size)
            return NSFont(name: d.family, size: size)
                ?? (d.weight == "semibold" ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size))
        }
        func pair(_ path: String, _ fallback: (CGFloat, CGFloat)) -> (CGFloat, CGFloat) {
            guard case .array(let v)? = node(path), v.count == 2,
                  case .number(let a) = v[0], case .number(let b) = v[1] else { return fallback }
            return (CGFloat(a), CGFloat(b))
        }

        let text = color("palette.text", .labelColor)
        let normalState = string("buttons.task.fillRule.normalState", "normalLabelled")
        let fill = Fill(
            material: string("buttons.task.normal.fill.type", "none") == "aeroButton" ? .aeroButton : .plate,
            hover: stateColor("hover", .labelColor, 0.07),
            pressed: stateColor("pressed", .labelColor, 0.12),
            active: stateColor("active", .labelColor, 0.07),
            normal: stateColor(normalState, .labelColor, 0.035),
            activeTriggers: bool("buttons.task.fillRule.activeTriggers", true),
            normalWhen: NormalWhen(rawValue: string("buttons.task.fillRule.normalWhen", "runningTitledTask")) ?? .runningTitledTask,
            inset: number("buttons.task.hover.inset", 0),
            radius: number("buttons.task.hover.radius", 0))
        let iconPath = "buttons.task.icon"
        let icon = Icon(
            taskIconOnly: number("metrics.taskButton.iconSize", 28),
            iconOnly: number("\(iconPath).iconOnly", 28),
            labelled: number("metrics.taskButton.iconSizeLabelled", 24),
            plain: number("metrics.taskButton.iconSizePlain", 16),
            smallIconUsesPlain: bool("\(iconPath).smallIconUsesPlain", false),
            clampInset: optionalNumber("\(iconPath).clampInset"),
            labelledX: number("buttons.task.iconLeadingLabelled", 8),
            centerWhenTitled: bool("\(iconPath).centerWhenTitled", false),
            taskYOffsetIconOnly: number("buttons.task.iconOffsetY", -2),
            taskYOffsetLabelled: number("buttons.task.iconOffsetYLabelled", -1),
            symbolSource: SymbolSource(rawValue: string("\(iconPath).symbolSource", "sfPlain")) ?? .sfPlain,
            symbolColor: color("\(iconPath).symbolColor", text),
            symbolSize: optionalNumber("\(iconPath).symbolSize"),
            symbolLabelledX: optionalNumber("\(iconPath).symbolLabelledX"))
        let tintQuickLaunchTemplateSymbols = bool("buttons.quickLaunch.tintTemplateSymbols", false)
        let titlePath = "buttons.task.title"
        let title = Title(
            show: bool("\(titlePath).show", true),
            font: font("\(titlePath).font", .systemFont(ofSize: 12)),
            centeredFont: font("\(titlePath).centeredFont", .systemFont(ofSize: 12)),
            color: color("\(titlePath).color", text),
            layout: TitleLayout(rawValue: string("\(titlePath).layout", "afterImage")) ?? .afterImage,
            iconGap: number("\(titlePath).iconGap", 8),
            trailingInset: number("\(titlePath).trailingInset", 11),
            fixedX: number("\(titlePath).x", 0),
            followsSmoothingSetting: string("\(titlePath).smoothing", "always") == "setting")
        let ri = "buttons.task.runningIndicator"
        let indicator = RunningIndicator(
            type: Indicator(rawValue: string("\(ri).type", "pill")) ?? .none,
            runningWidth: number("\(ri).running.width", 6),
            activeWidth: number("\(ri).active.width", 18),
            activeFullWidth: bool("\(ri).active.fullWidth", false),
            height: number("\(ri).height", 3),
            bottomInset: number("\(ri).bottomInset", 5),
            radius: number("\(ri).radius", 1.5),
            runningColor: color("\(ri).running.color", .secondaryLabelColor),
            activeColor: color("\(ri).active.color", .controlAccentColor))
        let size = pair("buttons.badge.size", (16, 14))
        let offset = pair("buttons.badge.offset", (-18, 1))
        let badge = Badge(
            shape: BadgeShape(rawValue: string("buttons.badge.shape", "pill")) ?? .pill,
            size: NSSize(width: size.0, height: size.1),
            offset: NSPoint(x: offset.0, y: offset.1),
            radius: number("buttons.badge.radius", 7),
            fill: color("buttons.badge.fill", .systemRed),
            textColor: color("buttons.badge.textColor", .white),
            font: font("buttons.badge.font", .systemFont(ofSize: 9, weight: .semibold)),
            showsText: bool("buttons.badge.showsText", true))
        let ap = "buttons.task.normal.fill.params"
        let aero = AeroButtonStyle(
            inset: number("\(ap).inset", 1.5), radius: number("\(ap).radius", 3),
            normalAlpha: number("\(ap).normalAlpha", 0.12), hoverAlpha: number("\(ap).hoverAlpha", 0.20),
            pressedAlpha: number("\(ap).pressedAlpha", 0.05), lowerAlpha: number("\(ap).lowerAlpha", 0.08),
            highlightAlpha: number("\(ap).highlightAlpha", 0.12), activeAlpha: number("\(ap).activeAlpha", 0.32),
            activeHighlightAlpha: number("\(ap).activeHighlightAlpha", 0.24), borderAlpha: number("\(ap).borderAlpha", 0.30),
            activeBorderAlpha: number("\(ap).activeBorderAlpha", 0.60), innerBorderAlpha: number("\(ap).innerBorderAlpha", 0.45),
            hotTrack: string("buttons.task.normal.fill.hotTrack", "none") == "iconAverage")
        let strip: AeroStripStyle? = node("buttons.desktopStrip") == nil ? nil : AeroStripStyle(
            normalAlpha: number("buttons.desktopStrip.normalAlpha", 0.20), hoverAlpha: number("buttons.desktopStrip.hoverAlpha", 0.40),
            lowerAlpha: number("buttons.desktopStrip.lowerAlpha", 0.06), edgeAlpha: number("buttons.desktopStrip.edgeAlpha", 0.50))
        return ModernButtonStyle(fill: fill, icon: icon,
                                 tintQuickLaunchTemplateSymbols: tintQuickLaunchTemplateSymbols, title: title,
                                 indicator: indicator, badge: badge, aero: aero, desktopStrip: strip)
    }
}

struct AeroButtonStyle {
    let inset, radius, normalAlpha, hoverAlpha, pressedAlpha, lowerAlpha, highlightAlpha, activeAlpha, activeHighlightAlpha: CGFloat
    let borderAlpha, activeBorderAlpha, innerBorderAlpha: CGFloat
    let hotTrack: Bool
}

struct AeroStripStyle {
    let normalAlpha, hoverAlpha, lowerAlpha, edgeAlpha: CGFloat
}
