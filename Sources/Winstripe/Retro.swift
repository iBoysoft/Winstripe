import AppKit

/// Drawing helpers. All rects are in flipped (y-down) view coordinates.
enum Retro {
    static func font(bold: Bool = false, size: CGFloat = 11) -> NSFont {
        // Tahoma ships with macOS (Supplemental fonts) and is the closest match to MS Sans Serif.
        if let f = NSFont(name: bold ? "Tahoma-Bold" : "Tahoma", size: size) { return f }
        return bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    }

    static func textSize(_ s: String, font: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    static func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor,
                         smoothing: Bool, alignment: NSTextAlignment = .left, obliqueness: CGFloat = 0) {
        guard !s.isEmpty, rect.width > 2 else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if obliqueness != 0 { attrs[.obliqueness] = obliqueness }
        let h = ceil(textSize(s, font: font).height)
        let r = NSRect(x: rect.minX, y: floor(rect.midY - h / 2), width: rect.width, height: h)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setShouldAntialias(smoothing)
            ctx.setShouldSmoothFonts(smoothing)
        }
        (s as NSString).draw(in: r, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawTextUntruncated(_ s: String, in rect: NSRect, font: NSFont, color: NSColor,
                                    smoothing: Bool, alignment: NSTextAlignment = .left) {
        guard !s.isEmpty else { return }
        let size = textSize(s, font: font)
        let x: CGFloat
        switch alignment {
        case .center: x = rect.midX - size.width / 2
        case .right: x = rect.maxX - size.width
        default: x = rect.minX
        }
        let y = floor(rect.midY - ceil(size.height) / 2)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setShouldAntialias(smoothing)
            ctx.setShouldSmoothFonts(smoothing)
        }
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Bevels

    static func edge(_ r: NSRect, tl: NSColor, br: NSColor) {
        tl.setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width - 1, height: 1).fill()
        NSRect(x: r.minX, y: r.minY, width: 1, height: r.height - 1).fill()
        br.setFill()
        NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
    }

    static func raised(_ r: NSRect, _ t: Theme) {
        edge(r, tl: t.highlight, br: t.darkShadow)
        edge(r.insetBy(dx: 1, dy: 1), tl: t.light, br: t.shadow)
    }

    static func pressed(_ r: NSRect, _ t: Theme) {
        edge(r, tl: t.darkShadow, br: t.highlight)
        edge(r.insetBy(dx: 1, dy: 1), tl: t.shadow, br: t.light)
    }

    static func statusField(_ r: NSRect, _ t: Theme) {
        edge(r, tl: t.shadow, br: t.highlight)
    }

    static func windowFrame(_ r: NSRect, _ t: Theme) {
        edge(r, tl: t.light, br: t.darkShadow)
        edge(r.insetBy(dx: 1, dy: 1), tl: t.highlight, br: t.shadow)
    }

    static func fill(_ r: NSRect, _ colors: [NSColor], radius: CGFloat = 0, vertical: Bool = true) {
        guard !colors.isEmpty else { return }
        let path = radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) : NSBezierPath(rect: r)
        if colors.count >= 2, let g = NSGradient(colors: colors) {
            g.draw(in: path, angle: vertical ? 90 : 0)
        } else {
            colors[0].setFill()
            path.fill()
        }
    }

    /// The classic dithered pattern used on a latched (active) task button.
    static let checker: NSColor = {
        let img = NSImage(size: NSSize(width: 2, height: 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return .clear
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        NSColor(hex: 0xC0C0C0).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        NSRect(x: 1, y: 1, width: 1, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: 2, height: 2)
        img.size = NSSize(width: 2, height: 2)
        img.addRepresentation(rep)
        return NSColor(patternImage: img)
    }()

    // MARK: Start flag (pure vector, no bitmap assets)

    @MainActor
    static func drawFlag(in r: NSRect, style s: StartButtonStyle.ClassicFlag) {
        let red = s.red.color, green = s.green.color
        let blue = s.blue.color, yellow = s.yellow.color
        let fx = r.minX + r.width * s.xFraction, fw = r.width * s.widthFraction
        let fy = r.minY + r.height * s.yFraction, fh = r.height * s.heightFraction

        func pt(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
            let wave = sin(u * .pi * s.waveFrequency + s.wavePhase) * fh * s.waveAmplitude
            return NSPoint(x: fx + u * fw + (0.5 - v) * fw * s.shear, y: fy + v * fh + wave)
        }
        func quad(_ u0: CGFloat, _ u1: CGFloat, _ v0: CGFloat, _ v1: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            let n = 8
            p.move(to: pt(u0, v0))
            for i in 1...n { p.line(to: pt(u0 + (u1 - u0) * CGFloat(i) / CGFloat(n), v0)) }
            p.line(to: pt(u1, v1))
            for i in 1...n { p.line(to: pt(u1 - (u1 - u0) * CGFloat(i) / CGFloat(n), v1)) }
            p.close()
            return p
        }

        s.outline.color.setFill()
        quad(s.outlineLeft, s.outlineRight, s.outlineTop, s.outlineBottom).fill()
        let g = s.gap
        red.setFill(); quad(0, 0.5 - g, 0, 0.5 - g).fill()
        green.setFill(); quad(0.5 + g, 1, 0, 0.5 - g).fill()
        blue.setFill(); quad(0, 0.5 - g, 0.5 + g, 1).fill()
        yellow.setFill(); quad(0.5 + g, 1, 0.5 + g, 1).fill()

        // The little "motion" squares trailing the flag.
        var x = pt(0, 0.5).x - r.width * s.trailStart
        let sizes: [CGFloat] = s.trailSizes.map { $0 * r.width }
        for size in sizes {
            x -= size + r.width * s.trailGap
            red.setFill(); NSRect(x: x, y: pt(0, s.trailTop).y, width: size, height: size).fill()
            blue.setFill(); NSRect(x: x, y: pt(0, s.trailBottom).y, width: size, height: size).fill()
        }
    }

    static func drawTriangleRight(center c: NSPoint, size: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - size / 2, y: c.y - size))
        p.line(to: NSPoint(x: c.x + size / 2, y: c.y))
        p.line(to: NSPoint(x: c.x - size / 2, y: c.y + size))
        p.close()
        color.setFill()
        p.fill()
    }

    static func drawImage(_ img: NSImage, in r: NSRect) {
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
