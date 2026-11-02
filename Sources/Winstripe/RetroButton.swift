import AppKit

/// A Win9x-style push button drawn entirely in code.
@MainActor
final class RetroButton: NSView {
    enum Kind { case start, task, quickLaunch, plain }

    var kind: Kind = .plain
    var title = "" { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var symbol: String? { didSet { needsDisplay = true } }
    /// Latched-down state (active task, open Start menu).
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var badge: String? { didSet { needsDisplay = true } }
    var theme = Theme.make(.win95) { didSet { needsDisplay = true } }
    var smoothing = true { didSet { needsDisplay = true } }
    var actsOnMouseDown = false
    var aeroDesktopStrip = false
    var isRunning = true
    var usesSmallIcon = false
    /// Tray chevrons use a lightweight, theme-coloured glyph instead of the
    /// generic task-button SF-symbol renderer.
    var trayChevron = false { didSet { needsDisplay = true } }
    var trayChevronThin = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    var onDrag: ((NSEvent, Bool) -> Void)?
    private var dragOrigin: NSPoint?
    private var dragging = false

    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    /// Force interaction states only for deterministic offscreen fixtures.
    func setSnapshotState(hovered: Bool, pressed: Bool) {
        precondition(SnapshotFixture.isActive)
        self.hovered = hovered
        self.pressed = pressed
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = onMenu?(event) {
                menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
            }
            return
        }
        if actsOnMouseDown {
            onClick?()
            return
        }
        pressed = true
        dragOrigin = event.locationInWindow
        dragging = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(event) }

    override func mouseDragged(with event: NSEvent) {
        guard !actsOnMouseDown else { return }
        if let origin = dragOrigin, let onDrag,
           dragging || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4 {
            dragging = true
            pressed = false
            onDrag(event, false)
            return
        }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard !actsOnMouseDown else { return }
        if dragging {
            dragging = false
            dragOrigin = nil
            onDrag?(event, true)
            return
        }
        dragOrigin = nil
        let fire = pressed
        pressed = false
        if fire { onClick?() }
    }

    static func startWidth(title: String, config: ClassicTheme) -> CGFloat {
        config.startWidthIncludesLabel
            ? ceil(Retro.textSize(title, font: config.font("startButton.label.font")).width) + config.startWidth
            : config.startWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let t = theme
        if kind == .start {
            drawStartButton(in: r)
            return
        }
        if let style = t.modernButton {
            drawModern(in: r, style: style)
            return
        }

        guard let c = t.classicConfig else { return }
        let group = kind == .quickLaunch ? "quickLaunch" : (kind == .plain ? "plain" : "task")
        let state = "buttons.\(group).\(pressed ? "pressed" : (isOn && kind != .quickLaunch ? "active" : "normal"))"
        guard let style = c.resolved.states[state] ?? c.resolved.states["buttons.task.normal"] else { return }
        if style.fill.type == "solid" || style.fill.type == "pattern" || style.fill.type == "none" {
            switch kind {
            case .quickLaunch:
                if pressed, let bevel = style.bevel { c.bevel(bevel, in: r) }
            default:
                let pattern = style.fill.type == "pattern"
                c.fill(r, material: pattern ? c.config.buttons.task.normal.fill : style.fill,
                       path: pattern ? "buttons.task.normal.fill" : state + ".fill")
                if pattern && isOn && !pressed && kind == .task {
                    c.checker.setFill()
                    let inset = CGFloat(style.fill.inset ?? 0)
                    r.insetBy(dx: inset, dy: inset).fill()
                }
                if let bevel = style.bevel { c.bevel(bevel, in: r) }
            }
        } else if kind != .quickLaunch || pressed {
            let inset = CGFloat(style.inset ?? 0)
            let rr = r.insetBy(dx: inset, dy: inset)
            let radius = CGFloat(style.radius ?? c.config.metrics.cornerRadius)
            c.fill(rr, material: style.fill, path: state + ".fill", radius: radius)
            if let border = style.border {
                c.color(state + ".border.color").setStroke()
                let path = NSBezierPath(roundedRect: rr, xRadius: radius, yRadius: radius)
                path.lineWidth = CGFloat(border.width)
                path.stroke()
            }
        }

        let offset = style.contentOffset
        let content = r.offsetBy(dx: CGFloat(offset?.first ?? 0), dy: CGFloat(offset?.last ?? 0))
        let textColor = c.color("buttons.\(group == "quickLaunch" ? "task" : group).title.color")

        switch kind {
        case .start: break // Dispatched through the registry above.
        case .quickLaunch:
            if let icon {
                let size = c.n("metrics.quickLaunch.iconSize")
                Retro.drawImage(icon, in: NSRect(x: floor(content.midX - size / 2), y: floor(content.midY - size / 2), width: size, height: size))
            }
        case .task, .plain:
            var x = content.minX + c.n("metrics.taskButton.iconInset")
            let size = c.n("metrics.taskButton.iconSize")
            var img = icon
            if img == nil, let symbol {
                if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                    let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: c.n("metrics.params.symbolSize"), weight: .regular)
                    img = base.symbolTinted([textColor], configuration: sizeConfiguration)
                }
            }
            if let img {
                if title.isEmpty {
                    let s = min(size, min(content.width, content.height) - c.n("metrics.params.iconOnlyInset"))
                    Retro.drawImage(img, in: NSRect(x: floor(content.midX - s / 2), y: floor(content.midY - s / 2), width: s, height: s))
                } else {
                    Retro.drawImage(img, in: NSRect(x: x, y: floor(content.midY - size / 2), width: size, height: size))
                    x += size + c.n("metrics.taskButton.iconTextGap")
                }
            }
            if !title.isEmpty {
                let bold = kind == .task && isOn && c.config.buttons.task.active?.boldTitle == true
                let centered = kind == .plain && img == nil
                let textRect = NSRect(x: centered ? content.minX : x, y: content.minY,
                                      width: centered ? content.width : content.maxX - x - c.n("metrics.taskButton.textTrailingInset"), height: content.height)
                let font = c.font("buttons.\(group).title.\(bold ? "boldFont" : "font")")
                if c.config.id == "winxp" && !centered {
                    Retro.drawText(title, in: textRect.offsetBy(dx: 1, dy: 1), font: font,
                                   color: NSColor(hex: 0x16408D), smoothing: smoothing)
                }
                Retro.drawText(title, in: textRect, font: font, color: textColor, smoothing: smoothing,
                               alignment: centered ? .center : .left)
            }
        }

        if let badge, !badge.isEmpty {
            let font = c.font("buttons.badge.font")
            let w = max(c.n("buttons.badge.minWidth"), ceil(Retro.textSize(badge, font: font).width) + c.n("buttons.badge.textPadding"))
            let trailing = kind == .quickLaunch && c.s("buttons.badge.anchor.quickLaunch") == "topTrailing"
            let br = NSRect(x: content.minX + (trailing ? content.width - w : c.n("buttons.badge.anchor.task.0")),
                            y: content.minY + c.n("buttons.badge.anchor.task.1"), width: w, height: c.n("buttons.badge.height"))
            c.color("buttons.badge.fill").setFill()
            NSBezierPath(roundedRect: br, xRadius: c.n("buttons.badge.radius"), yRadius: c.n("buttons.badge.radius")).fill()
            Retro.drawText(badge, in: br, font: font, color: c.color("buttons.badge.textColor"), smoothing: true, alignment: .center)
        }
    }

    private func drawStartButton(in r: NSRect) {
        let s = theme.startStyle
        guard let drawer = StartButtonDrawer.registry[s.drawer] else { return }
        let plate = !drawer.drawsSurface && s.plate.enabled
        if plate && (pressed || isOn || hovered) {
            let p = s.plate
            (pressed ? p.pressed : (isOn ? p.open : p.hover)).color.setFill()
            if p.inset == 0 && p.radius == 0 { r.fill() }
            else { NSBezierPath(roundedRect: r.insetBy(dx: p.inset, dy: p.inset), xRadius: p.radius, yRadius: p.radius).fill() }
        }
        drawer.draw(.init(rect: r, style: s, title: title, smoothing: smoothing,
                          hovered: hovered, pressed: pressed, isOn: isOn))
        if plate, let modern = theme.modernButton { drawBadge(in: r, style: modern) }
    }

    /// State fill for plate materials: pressed > active > hovered > the configured normal plate.
    private func drawStateFill(in r: NSRect, style: ModernButtonStyle) {
        let f = style.fill
        let color: NSColor
        if pressed { color = f.pressed.color }
        else if isOn && f.activeTriggers { color = f.active.color }
        else if hovered { color = f.hover.color }
        else {
            switch f.normalWhen {
            case .never: return
            case .task: guard kind == .task else { return }
            case .runningTask: guard kind == .task && isRunning else { return }
            case .runningTitledTask: guard kind == .task && isRunning && !title.isEmpty else { return }
            }
            color = f.normal.color
        }
        color.setFill()
        if f.inset == 0 && f.radius == 0 {
            r.fill()
        } else {
            NSBezierPath(roundedRect: r.insetBy(dx: f.inset, dy: f.inset), xRadius: f.radius, yRadius: f.radius).fill()
        }
    }

    private func drawBadge(in r: NSRect, style: ModernButtonStyle) {
        guard let badge, !badge.isEmpty else { return }
        let b = style.badge
        let rect = b.rect(in: r)
        b.fill.setFill()
        switch b.shape {
        case .dot: NSBezierPath(ovalIn: rect).fill()
        case .pill: NSBezierPath(roundedRect: rect, xRadius: b.radius, yRadius: b.radius).fill()
        }
        if b.showsText {
            Retro.drawText(badge, in: rect, font: b.font, color: b.textColor, smoothing: true, alignment: .center)
        }
    }

    /// One renderer for every modern task / quick-launch / plain button:
    /// state fill -> icon -> title -> running indicator -> badge.
    private func drawModern(in r: NSRect, style: ModernButtonStyle) {
        if aeroDesktopStrip, let strip = style.desktopStrip {
            Retro.fill(r, [NSColor(white: 1, alpha: hovered ? strip.hoverAlpha : strip.normalAlpha),
                           NSColor(white: 1, alpha: strip.lowerAlpha)])
            NSColor(white: 1, alpha: strip.edgeAlpha).setFill()
            NSRect(x: 0, y: 0, width: 1, height: r.height).fill()
            return
        }

        // 1. State fill.
        switch style.fill.material {
        case .plate:
            drawStateFill(in: r, style: style)
        case .aeroButton:
            let normal: Bool
            switch style.fill.normalWhen {
            case .never: normal = false
            case .task: normal = kind == .task
            case .runningTask: normal = kind == .task && isRunning
            case .runningTitledTask: normal = kind == .task && isRunning && !title.isEmpty
            }
            if normal || hovered || pressed || (isOn && style.fill.activeTriggers) {
                AeroDrawing.button(r, active: isOn, hovered: hovered, pressed: pressed,
                                   hotColor: style.aero.hotTrack ? icon.map {
                                       SnapshotFixture.isActive ? AeroDrawing.averageColorSync($0) : AeroDrawing.averageColor($0)
                                   } : nil,
                                   style: style.aero)
            }
        }

        if trayChevron {
            drawTrayChevron(in: r, thin: trayChevronThin)
            return
        }

        // 2. Icon (app icon, else the configured symbol source).
        let ic = style.icon
        var fromSymbol = false
        var image = icon
        // Template SF fallbacks supplied as icons need the same palette as symbols.
        // Preserve explicitly coloured images and the existing app-icon geometry.
        if kind == .quickLaunch, style.tintQuickLaunchTemplateSymbols, let template = image, template.isTemplate {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = ic.symbolColor.usingColorSpace(.deviceRGB) ?? ic.symbolColor
                if #available(macOS 12.0, *) {
                    image = template.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? template
                }
            }
        }
        if image == nil, let symbol {
            fromSymbol = true
            switch ic.symbolSource {
            case .win8Glyph: image = Win8Drawing.symbol(symbol)
            case .sfPlain: image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            case .sfPalette:
                if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                    if #available(macOS 12.0, *) {
                        image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ic.symbolColor]))
                    } else {
                        image = base
                    }
                }
            }
        }
        var imageRect = NSRect.zero
        if let image {
            let iconOnly = title.isEmpty || ic.centerWhenTitled
            var size: CGFloat
            if kind == .plain || (usesSmallIcon && ic.smallIconUsesPlain) { size = ic.plain }
            else if title.isEmpty { size = kind == .task ? ic.taskIconOnly : ic.iconOnly }
            else { size = ic.labelled }
            if fromSymbol, let symbolSize = ic.symbolSize { size = symbolSize }
            if let inset = ic.clampInset { size = max(0, min(size, min(r.width, r.height) - inset)) }
            let yOffset = kind == .task ? (title.isEmpty ? ic.taskYOffsetIconOnly : ic.taskYOffsetLabelled) : 0
            let labelledX = fromSymbol ? (ic.symbolLabelledX ?? ic.labelledX) : ic.labelledX
            imageRect = NSRect(x: iconOnly ? r.midX - size / 2 : labelledX,
                               y: r.midY - size / 2 + yOffset, width: size, height: size)
            Retro.drawImage(image, in: imageRect)
        }

        // 3. Title.
        let t = style.title
        if t.show && !title.isEmpty {
            let smooth = t.followsSmoothingSetting ? smoothing : true
            if image == nil {
                Retro.drawText(title, in: r, font: t.centeredFont, color: t.color, smoothing: smooth, alignment: .center)
            } else {
                let x = t.layout == .fixed ? t.fixedX : imageRect.maxX + t.iconGap
                let width = t.layout == .fixed ? max(0, r.width - t.fixedX - t.trailingInset)
                                                : max(0, r.maxX - imageRect.maxX - t.trailingInset)
                Retro.drawText(title, in: NSRect(x: x, y: 0, width: width, height: r.height),
                               font: t.font, color: t.color, smoothing: smooth, alignment: .left)
            }
        }

        // 4. Running indicator.
        let ind = style.indicator
        if kind == .task && isRunning {
            switch ind.type {
            case .none:
                break
            case .underline:
                let width = isOn ? (ind.activeFullWidth ? r.width : ind.activeWidth) : ind.runningWidth
                (isOn ? ind.activeColor : ind.runningColor).setFill()
                NSRect(x: r.midX - width / 2, y: r.maxY - ind.bottomInset, width: width, height: ind.height).fill()
            case .pill:
                let width = isOn ? (ind.activeFullWidth ? r.width : ind.activeWidth) : ind.runningWidth
                (isOn ? ind.activeColor : ind.runningColor).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.midX - width / 2, y: r.maxY - ind.bottomInset, width: width, height: ind.height),
                             xRadius: ind.radius, yRadius: ind.radius).fill()
            }
        }

        // 5. Badge.
        drawBadge(in: r, style: style)
    }

    private func drawTrayChevron(in rect: NSRect, thin: Bool) {
        if hovered {
            let radius: CGFloat = theme.kind == .win11 ? 4 : 0
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius).fill()
        }
        let color = theme.trayStyle.chevronStyle.color.color
        if thin {
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let path = NSBezierPath()
            switch symbol {
            case "chevron.down":
                path.move(to: NSPoint(x: center.x - 4, y: center.y - 2))
                path.line(to: NSPoint(x: center.x, y: center.y + 2))
                path.line(to: NSPoint(x: center.x + 4, y: center.y - 2))
            case "chevron.left":
                path.move(to: NSPoint(x: center.x + 2, y: center.y - 4))
                path.line(to: NSPoint(x: center.x - 2, y: center.y))
                path.line(to: NSPoint(x: center.x + 2, y: center.y + 4))
            case "chevron.right":
                path.move(to: NSPoint(x: center.x - 2, y: center.y - 4))
                path.line(to: NSPoint(x: center.x + 2, y: center.y))
                path.line(to: NSPoint(x: center.x - 2, y: center.y + 4))
            default:
                path.move(to: NSPoint(x: center.x - 4, y: center.y + 2))
                path.line(to: NSPoint(x: center.x, y: center.y - 2))
                path.line(to: NSPoint(x: center.x + 4, y: center.y + 2))
            }
            path.lineWidth = 1.25
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        } else {
            let text = symbol == "chevron.down" ? "⌄" : "⌃"
            Retro.drawText(text, in: rect, font: .systemFont(ofSize: 13, weight: .regular),
                           color: color, smoothing: true, alignment: .center)
        }
    }
}
