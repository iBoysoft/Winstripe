import AppKit

extension NSImage {
    /// An SF Symbol drawn in `colors`.
    /// macOS 12+: palette rendering (primary, secondary, …), optionally combined with a size/weight
    /// configuration. macOS 11 has no palette or hierarchical rendering, so the monochrome template
    /// is tinted with the last color (the "background" color for two-tone symbols such as
    /// `questionmark.circle.fill`, whose glyph stays see-through).
    func symbolTinted(_ colors: [NSColor], configuration: NSImage.SymbolConfiguration? = nil) -> NSImage? {
        if #available(macOS 12.0, *) {
            let palette = NSImage.SymbolConfiguration(paletteColors: colors)
            return withSymbolConfiguration(configuration.map { $0.applying(palette) } ?? palette)
        }
        let sized = configuration.flatMap { withSymbolConfiguration($0) } ?? self
        guard let color = colors.last else { return sized }
        return sized.tintedTemplate(color)
    }

    /// Fills the image's opaque pixels with `color`; works for template images on every macOS.
    func tintedTemplate(_ color: NSColor) -> NSImage {
        let source = self
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

/// Exercises the macOS 11 fallback (template tint) on any OS: it cannot run otherwise on 12+.
@MainActor
enum SymbolTintSelfTest {
    static func run() -> Int {
        var failures: [String] = []
        guard let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)) else {
            print("FAIL symbol-tint selftest: no symbol"); return 1
        }
        func centerPixel(_ image: NSImage) -> NSColor? {
            let size = NSSize(width: 40, height: 40)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            return rep.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB)
        }
        let tinted = base.tintedTemplate(.systemRed)
        if tinted.isTemplate { failures.append("tinted image is still a template") }
        if let c = centerPixel(tinted) {
            if !(c.redComponent > 0.8 && c.greenComponent < 0.4 && c.blueComponent < 0.4 && c.alphaComponent > 0.9) {
                failures.append("center pixel not red: \(c)")
            }
        } else { failures.append("could not render tinted image") }
        if let corner = centerPixel(NSImage(size: NSSize(width: 1, height: 1))), corner.alphaComponent > 0.01 {
            failures.append("empty image rendered opaque")
        }
        if base.symbolTinted([.white, .systemBlue]) == nil { failures.append("symbolTinted returned nil") }
        if failures.isEmpty { print("PASS symbol-tint selftest"); return 0 }
        failures.forEach { print("FAIL symbol-tint selftest: \($0)") }
        return 1
    }
}
