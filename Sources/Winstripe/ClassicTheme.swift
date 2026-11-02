import AppKit

/// Immutable paint resources prepared with the resolved configuration, never in draw().
struct ClassicTheme {
    let resolved: ResolvedTheme
    let colors: [String: NSColor]
    let fonts: [String: NSFont]
    let bevels: [String: [(NSColor, NSColor)]]
    let checker: NSColor
    let startWidth: CGFloat
    let startWidthIncludesLabel: Bool

    var config: ThemeConfig { resolved.config }
    func value(_ path: String) -> ThemeJSON? {
        var node: ThemeJSON? = resolved.json
        for part in path.split(separator: ".") {
            if case .array(let items) = node, let index = Int(part), items.indices.contains(index) {
                node = items[index]
            } else { node = node?[String(part)] }
        }
        return node
    }
    // Lookups never crash: a key missing from this theme falls back to the compiled
    // win95 classic defaults, then to a neutral value.
    @MainActor
    func n(_ path: String) -> CGFloat {
        if let number = value(path)?.number { return CGFloat(number) }
        if let number = Self.defaults?.value(path)?.number { return CGFloat(number) }
        return 0
    }
    @MainActor
    func s(_ path: String) -> String { value(path)?.string ?? Self.defaults?.value(path)?.string ?? "" }
    func b(_ path: String) -> Bool { value(path) == .bool(true) }
    @MainActor
    func color(_ path: String) -> NSColor { colors[path] ?? Self.defaults?.colors[path] ?? .black }
    @MainActor
    func font(_ path: String) -> NSFont { fonts[path] ?? Self.defaults?.fonts[path] ?? Retro.font() }

    /// Compiled win95 classic values used for keys a (user) theme omits.
    @MainActor private static var cachedDefaults: ClassicTheme??
    @MainActor static var defaults: ClassicTheme? {
        if let cached = cachedDefaults { return cached }
        let built = try? ClassicTheme(ThemeLoader().load("win95").theme)
        cachedDefaults = .some(built)
        return built
    }

    init(_ resolved: ResolvedTheme) throws {
        self.resolved = resolved
        let width = resolved.config.startButton.size["width"]
        if let number = width?.number {
            startWidth = CGFloat(number)
            startWidthIncludesLabel = false
        } else if let text = width?.string, text.hasPrefix("label+"),
                  let number = Double(text.dropFirst("label+".count)) {
            startWidth = CGFloat(number)
            startWidthIncludesLabel = true
        } else { throw ThemeColorError.invalid }
        let settings = TaskbarSettings()
        colors = resolved.colors.mapValues { $0.resolve(settings: settings) }
        fonts = resolved.fonts.mapValues { descriptor in
            let size = CGFloat(descriptor.size)
            return NSFont(name: descriptor.family, size: size)
                ?? (descriptor.fallback == "systemBold" ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }
        bevels = resolved.bevels.mapValues { layers in
            layers.map { ($0.topLeft.resolve(settings: settings), $0.bottomRight.resolve(settings: settings)) }
        }
        let material = resolved.config.buttons.task.active?.fill
        let patternColors = (material?.colors ?? []).compactMap {
            try? ThemeColor.parse($0, palette: resolved.config.palette).resolve(settings: settings)
        }
        checker = Self.checker(patternColors)
    }

    private static func checker(_ colors: [NSColor]) -> NSColor {
        guard colors.count == 2 else { return .clear }
        let img = NSImage(size: NSSize(width: 2, height: 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return .clear
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colors[0].setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        colors[1].setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        NSRect(x: 1, y: 1, width: 1, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: 2, height: 2)
        img.size = NSSize(width: 2, height: 2)
        img.addRepresentation(rep)
        return NSColor(patternImage: img)
    }

    @MainActor
    func bevel(_ name: String, in rect: NSRect) {
        for (index, layer) in (bevels[name] ?? []).enumerated() {
            Retro.edge(index == 0 ? rect : rect.insetBy(dx: CGFloat(index), dy: CGFloat(index)), tl: layer.0, br: layer.1)
        }
    }

    @MainActor
    func fill(_ rect: NSRect, material: ThemeMaterial, path: String, radius: CGFloat = 0,
              reverse: Bool = false, vertical: Bool? = nil) {
        if material.type == "solid" {
            color(path + ".color").setFill()
            rect.fill()
        } else if material.type == "gradient" {
            let colors = (material.stops ?? []).enumerated().map { index, stop in
                color(path + ".stops.\(index)" + (stop["color"] == nil ? "" : ".color"))
            }
            let angle = CGFloat(material.angle ?? 0) - (vertical == false ? 90 : 0)
            gradient(rect, colors: reverse ? Array(colors.reversed()) : colors, radius: radius, angle: angle)
        }
    }

    @MainActor
    func gradient(_ rect: NSRect, colors: [NSColor], radius: CGFloat, angle: CGFloat) {
        guard !colors.isEmpty else { return }
        let path = radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(rect: rect)
        if colors.count >= 2, let gradient = NSGradient(colors: colors) {
            gradient.draw(in: path, angle: angle)
        } else {
            colors[0].setFill()
            path.fill()
        }
    }
}
