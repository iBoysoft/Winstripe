import AppKit

/// The only Start artwork dispatch: the configured name selects a registered drawer.
@MainActor
enum StartButtonDrawer {
    struct Context {
        let rect: NSRect
        let style: StartButtonStyle
        let title: String
        let smoothing, hovered, pressed, isOn: Bool
        var sunk: Bool { pressed || isOn }
    }
    struct Drawer {
        let drawsSurface: Bool
        let draw: (Context) -> Void
    }
    static let registry: [String: Drawer] = [
        "win95Flag": Drawer(drawsSurface: true, draw: { classic($0, pill: false) }),
        "xpPill": Drawer(drawsSurface: true, draw: xpPill),
        "vistaOrb": Drawer(drawsSurface: false, draw: orb),
        "win7Orb": Drawer(drawsSurface: false, draw: orb),
        "win8Logo": Drawer(drawsSurface: false, draw: win8),
        "win10Logo": Drawer(drawsSurface: false, draw: win10),
        "win11Logo": Drawer(drawsSurface: false, draw: win11),
        "image": Drawer(drawsSurface: false, draw: image)
    ]

    private static func classic(_ c: Context, pill: Bool) {
        let r = c.rect, s = c.style
        // Classic hover intentionally uses normal. Open uses the configured open state.
        let state = c.sunk ? (c.pressed ? s.pressed : s.open) : s.normal
        if !pill {
            state.fill.color.setFill()
            r.fill()
            for (index, layer) in state.bevel.enumerated() {
                Retro.edge(index == 0 ? r : r.insetBy(dx: CGFloat(index), dy: CGFloat(index)),
                           tl: layer.0.color, br: layer.1.color)
            }
        } else {
            let rect = r.insetBy(dx: state.inset, dy: state.inset)
            let colors = s.gradient.map { $0.color }
            let path = s.radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: s.radius, yRadius: s.radius) : NSBezierPath(rect: rect)
            NSGradient(colors: c.sunk ? Array(colors.reversed()) : colors)?.draw(in: path, angle: s.angle)
            if state.hasBorder {
                state.border.color.setStroke()
                let border = NSBezierPath(roundedRect: rect, xRadius: s.radius, yRadius: s.radius)
                border.lineWidth = state.borderWidth
                border.stroke()
            }
        }
        let content = r.offsetBy(dx: state.offset.x, dy: state.offset.y)
        let flag = NSRect(x: content.minX + s.glyphRect.minX, y: floor(content.midY - s.glyphRect.height / 2),
                          width: s.glyphRect.width, height: s.glyphRect.height)
        Retro.drawFlag(in: flag, style: s.classicFlag)
        if s.label.visible {
            let x = flag.maxX + s.labelGap
            Retro.drawText(c.title, in: NSRect(x: x, y: content.minY, width: content.maxX - x - s.labelTrailingInset, height: content.height),
                           font: s.label.font, color: s.label.color.color, smoothing: c.smoothing)
        }
    }

    private static func xpPill(_ c: Context) {
        let r = c.rect, s = c.style
        let state = c.sunk ? (c.pressed ? s.pressed : s.open) : s.normal
        let rect = r.insetBy(dx: state.inset, dy: state.inset)
        let left = min(s.pillLeftRadius, rect.height / 2)
        let right = min(s.pillRightRadius, rect.height / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + left, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - right, y: rect.minY))
        path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + right),
                   controlPoint1: NSPoint(x: rect.maxX - right * 0.45, y: rect.minY),
                   controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + right * 0.45))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - right))
        path.curve(to: NSPoint(x: rect.maxX - right, y: rect.maxY),
                   controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - right * 0.45),
                   controlPoint2: NSPoint(x: rect.maxX - right * 0.45, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + left, y: rect.maxY))
        if left > 0 {
            path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - left),
                       controlPoint1: NSPoint(x: rect.minX + left * 0.45, y: rect.maxY),
                       controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - left * 0.45))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + left))
            path.curve(to: NSPoint(x: rect.minX + left, y: rect.minY),
                       controlPoint1: NSPoint(x: rect.minX, y: rect.minY + left * 0.45),
                       controlPoint2: NSPoint(x: rect.minX + left * 0.45, y: rect.minY))
        } else {
            path.close()
        }
        let colors = c.sunk ? s.pressedGradient : (c.hovered ? s.hoverGradient : s.gradient)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: colors.map { $0.color })?.draw(in: path, angle: s.angle)
        if s.pillHighlightHeight > 0 {
            s.pillHighlight.color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: s.pillHighlightHeight).fill()
        }
        if s.pillShadowHeight > 0 {
            s.pillShadow.color.setFill()
            NSRect(x: rect.minX, y: rect.maxY - s.pillShadowHeight, width: rect.width, height: s.pillShadowHeight).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if state.hasBorder {
            state.border.color.setStroke()
            let border = NSBezierPath()
            border.append(path)
            border.lineWidth = state.borderWidth
            border.stroke()
        }
        let content = r.offsetBy(dx: state.offset.x, dy: state.offset.y)
        let flag = NSRect(x: content.minX + s.glyphRect.minX, y: floor(content.midY - s.glyphRect.height / 2),
                          width: s.glyphRect.width, height: s.glyphRect.height)
        Retro.drawFlag(in: flag, style: s.classicFlag)
        if s.label.visible {
            let visualWidth = s.flagVisualWidth > 0 ? s.flagVisualWidth : flag.width
            let x = flag.minX + visualWidth + s.labelGap
            let textRect = NSRect(x: x, y: content.minY, width: content.maxX - x - s.labelTrailingInset, height: content.height)
            let title = c.title.lowercased()
            let hasItalic = s.label.font.fontDescriptor.symbolicTraits.contains(.italic)
            // CJK fallback fonts commonly have no italic face. Apply the same
            // synthetic slant used by XP for those glyphs so localized labels
            // retain the visual treatment of the Latin "Start" label.
            let containsCJK = title.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
                default: return false
                }
            }
            let obliqueness = (hasItalic && !containsCJK) ? 0 : s.labelObliqueness
            Retro.drawText(title, in: textRect.offsetBy(dx: s.labelShadowOffset.x, dy: s.labelShadowOffset.y),
                           font: s.label.font, color: s.labelShadow.color, smoothing: c.smoothing, obliqueness: obliqueness)
            Retro.drawText(title, in: textRect, font: s.label.font, color: s.label.color.color, smoothing: c.smoothing,
                           obliqueness: obliqueness)
        }
    }

    private static func orb(_ c: Context) {
        let r = c.rect, s = c.style
        let size = min(s.diameter, min(r.width, r.height))
        AeroDrawing.orb(in: NSRect(x: r.midX - size / 2, y: r.midY - size / 2, width: size, height: size),
                        style: s.orb, flagStyle: s.aeroFlag, hovered: c.hovered, pressed: c.sunk)
    }
    private static func win8(_ c: Context) {
        let r = c.rect, s = c.style
        Win8Drawing.logo(in: NSRect(x: r.midX - s.size / 2, y: r.midY - s.size / 2, width: s.size, height: s.size),
                         color: s.color.color, gapFraction: s.gapFraction, minGap: s.minGap, cornerRadius: s.cornerRadius)
    }
    private static func win10(_ c: Context) {
        let r = c.rect, s = c.style
        let x = r.midX - s.size / 2, y = r.midY - s.size / 2
        Win10Drawing.logo(in: NSRect(x: s.roundOrigin ? x.rounded() : x, y: s.roundOrigin ? y.rounded() : y,
                                    width: s.size, height: s.size), color: s.color.color)
    }
    private static func win11(_ c: Context) {
        let r = c.rect, s = c.style
        let origin = NSPoint(x: r.midX + s.originFromCenter, y: r.midY + s.originFromCenter)
        // Keep the two-colour initializer used by the original logo.
        let gradient = s.gradient.count == 2
            ? NSGradient(starting: s.gradient[0].color, ending: s.gradient[1].color)
            : NSGradient(colors: s.gradient.map { $0.color })
        for row in 0..<2 {
            for column in 0..<2 {
                let rect = NSRect(x: origin.x + CGFloat(column) * s.pitch, y: origin.y + CGFloat(row) * s.pitch,
                                  width: s.square, height: s.square)
                let path = s.cornerRadius == 0 ? NSBezierPath(rect: rect)
                    : NSBezierPath(roundedRect: rect, xRadius: s.cornerRadius, yRadius: s.cornerRadius)
                gradient?.draw(in: path, angle: s.angle)
            }
        }
    }
    private static func image(_ c: Context) {
        guard case .loaded(let normal, let hover, let pressed) = c.style.images else { return }
        let image = c.sunk ? pressed : (c.hovered ? hover : normal)
        let size = c.style.imageSize
        let box = NSRect(x: c.rect.midX - size.width / 2, y: c.rect.midY - size.height / 2, width: size.width, height: size.height)
        var destination = box
        if c.style.fit != .stretch {
            let x = size.width / image.size.width, y = size.height / image.size.height
            let scale = c.style.fit == .cover ? max(x, y) : min(x, y)
            destination.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            destination.origin = NSPoint(x: box.midX - destination.width / 2, y: box.midY - destination.height / 2)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: box).addClip()
        Retro.drawImage(image, in: destination)
        NSGraphicsContext.restoreGraphicsState()
    }
}
