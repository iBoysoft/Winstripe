import AppKit

/// Load-time, non-optional Start artwork and overflow geometry. Drawers never read JSON.
/// Paint keeps its parsed colour expression so dynamic colours receive alpha at draw time.
struct StartButtonStyle {
    struct Paint {
        let value: ThemeColor
        var alpha: CGFloat = 1
        var appliesAlpha = false
        @MainActor var color: NSColor {
            let base = value.resolve(settings: TaskbarSettings())
            return appliesAlpha ? base.withAlphaComponent(alpha) : base
        }
    }
    enum Fit: String { case contain, cover, stretch }
    enum Images {
        case none
        case loaded(normal: NSImage, hover: NSImage, pressed: NSImage)
    }
    struct Overflow {
        let outer, panelMargin, panelWidth, panelHeight, panelInset, previewExtraHeight, menuPadding: CGFloat
        let enabled: Bool
        var panelSize: NSSize { NSSize(width: panelWidth, height: panelHeight) }
    }
    struct Plate {
        let enabled: Bool
        let inset, radius: CGFloat
        let hover, pressed, open: Paint
    }
    struct Label {
        let visible: Bool
        let key: String
        let font: NSFont
        let color: Paint
    }
    struct State {
        let fill: Paint
        let inset: CGFloat
        let offset: NSPoint
        let border: Paint
        let borderWidth: CGFloat
        let hasBorder: Bool
        let bevel: [(Paint, Paint)]
    }
    struct ClassicFlag {
        let red: Paint
        let green: Paint
        let blue: Paint
        let yellow: Paint
        let outline: Paint
        let xFraction: CGFloat
        let widthFraction: CGFloat
        let yFraction: CGFloat
        let heightFraction: CGFloat
        let waveFrequency: CGFloat
        let wavePhase: CGFloat
        let waveAmplitude: CGFloat
        let shear: CGFloat
        let outlineLeft: CGFloat
        let outlineRight: CGFloat
        let outlineTop: CGFloat
        let outlineBottom: CGFloat
        let gap: CGFloat
        let trailStart: CGFloat
        let trailSizes: [CGFloat]
        let trailGap: CGFloat
        let trailTop: CGFloat
        let trailBottom: CGFloat
        fileprivate init(_ r: Reader, _ prefix: String) {
            red = r.paint(prefix + ".red", .string("#F03C14"))
            green = r.paint(prefix + ".green", .string("#3CB43C"))
            blue = r.paint(prefix + ".blue", .string("#1E64DC"))
            yellow = r.paint(prefix + ".yellow", .string("#F5C814"))
            outline = r.paint(prefix + ".outline", .string("system:black"))
            xFraction = r.n(prefix + ".xFraction", 0.34)
            widthFraction = r.n(prefix + ".widthFraction", 0.66)
            yFraction = r.n(prefix + ".yFraction", 0.06)
            heightFraction = r.n(prefix + ".heightFraction", 0.86)
            waveFrequency = r.n(prefix + ".waveFrequency", 1.6)
            wavePhase = r.n(prefix + ".wavePhase", 0.4)
            waveAmplitude = r.n(prefix + ".waveAmplitude", 0.09)
            shear = r.n(prefix + ".shear", 0.12)
            outlineLeft = r.n(prefix + ".outlineLeft", -0.06)
            outlineRight = r.n(prefix + ".outlineRight", 1.06)
            outlineTop = r.n(prefix + ".outlineTop", -0.08)
            outlineBottom = r.n(prefix + ".outlineBottom", 1.08)
            gap = r.n(prefix + ".gap", 0.05)
            trailStart = r.n(prefix + ".trailStart", 0.06)
            trailSizes = r.numbers(prefix + ".trailSizes", [0.1, 0.08, 0.06])
            trailGap = r.n(prefix + ".trailGap", 0.05)
            trailTop = r.n(prefix + ".trailTop", 0.18)
            trailBottom = r.n(prefix + ".trailBottom", 0.66)
        }
    }

    struct AeroFlag {
        let colors: [Paint]
        let rotation: CGFloat
        let shear: CGFloat
        let waveAmplitude: CGFloat
        let waveFrequency: CGFloat
        let tilt: CGFloat
        let edgeWave: CGFloat
        let left: [CGFloat]
        let right: [CGFloat]
        let top: [CGFloat]
        let bottom: [CGFloat]
        let glowColor: Paint
        let glowRadius: CGFloat
        let glowFill: Paint
        let highlight: CGFloat
        let highlightColor: Paint
        fileprivate init(_ r: Reader, _ prefix: String) {
            colors = r.paints(prefix + ".colors", [.string("#F65314"), .string("#7CBB00"), .string("#00A1F1"), .string("#FFBB00")])
            rotation = r.n(prefix + ".rotation", -8)
            shear = r.n(prefix + ".shear", 0.1)
            waveAmplitude = r.n(prefix + ".waveAmplitude", 0.09)
            waveFrequency = r.n(prefix + ".waveFrequency", 2)
            tilt = r.n(prefix + ".tilt", 0.06)
            edgeWave = r.n(prefix + ".edgeWave", 0.12)
            left = r.numbers(prefix + ".left", [0.03, 0.48])
            right = r.numbers(prefix + ".right", [0.43, 0.97])
            top = r.numbers(prefix + ".top", [0.05, 0.53])
            bottom = r.numbers(prefix + ".bottom", [0.47, 0.95])
            glowColor = r.paint(prefix + ".glowColor", .object(["color": .string("#D8FAFF"), "alpha": .number(0.75)]))
            glowRadius = r.n(prefix + ".glowRadius", 0.18)
            glowFill = r.paint(prefix + ".glowFill", .object(["color": .string("system:white"), "alpha": .number(0.7)]))
            highlight = r.n(prefix + ".highlight", 0.14)
            highlightColor = r.paint(prefix + ".highlightColor", .string("system:white"))
        }
    }

    struct Orb {
        let inset: CGFloat
        let glowColor: Paint
        let glowEnd: Paint
        let glowInset: CGFloat
        let colors: [Paint]
        let hoverBlend: CGFloat
        let hoverColor: Paint
        let radial: Bool
        let radialOffset: CGFloat
        let sheenX: CGFloat
        let sheenY: CGFloat
        let sheenWidthInset: CGFloat
        let sheenHeight: CGFloat
        let sheenColors: [Paint]
        let logoX: CGFloat
        let logoY: CGFloat
        let logoWidth: CGFloat
        let logoHeight: CGFloat
        let pressedColor: Paint
        let borderColor: Paint
        let borderWidth: CGFloat
        fileprivate init(_ r: Reader, _ prefix: String) {
            inset = r.n(prefix + ".inset", 0.5)
            glowColor = r.paint(prefix + ".glowColor", .object(["color": .string("#40C0FF"), "alpha": .number(0.85)]))
            glowEnd = r.paint(prefix + ".glowEnd", .string("system:clear"))
            glowInset = r.n(prefix + ".glowInset", -3)
            colors = r.paints(prefix + ".colors", [.string("#3A3A3A"), .string("#1A1A1A"), .string("system:black")])
            hoverBlend = r.n(prefix + ".hoverBlend", 0.12)
            hoverColor = r.paint(prefix + ".hoverColor", .string("system:white"))
            radial = r.b(prefix + ".radial", false)
            radialOffset = r.n(prefix + ".radialOffset", 0.16)
            sheenX = r.n(prefix + ".sheenX", 3)
            sheenY = r.n(prefix + ".sheenY", 1)
            sheenWidthInset = r.n(prefix + ".sheenWidthInset", 6)
            sheenHeight = r.n(prefix + ".sheenHeight", 0.45)
            sheenColors = r.paints(prefix + ".sheenColors", [.object(["white": .number(1), "alpha": .number(0.55)]), .object(["white": .number(1), "alpha": .number(0.03)])])
            logoX = r.n(prefix + ".logoX", 0.275)
            logoY = r.n(prefix + ".logoY", 0.26)
            logoWidth = r.n(prefix + ".logoWidth", 0.55)
            logoHeight = r.n(prefix + ".logoHeight", 0.45)
            pressedColor = r.paint(prefix + ".pressedColor", .object(["white": .number(0), "alpha": .number(0.3)]))
            borderColor = r.paint(prefix + ".borderColor", .object(["white": .number(1), "alpha": .number(0.4)]))
            borderWidth = r.n(prefix + ".borderWidth", 1)
        }
    }
    let plate: Plate
    let drawer: String
    let label: Label
    let glyphRect: NSRect
    let labelGap, labelTrailingInset, flagVisualWidth, labelObliqueness, radius, angle: CGFloat
    let gradient: [Paint]
    let hoverGradient, pressedGradient: [Paint]
    let pillLeftRadius, pillRightRadius, pillHighlightHeight, pillShadowHeight: CGFloat
    let pillHighlight, pillShadow, labelShadow: Paint
    let labelShadowOffset: NSPoint
    let diameter, size, square, pitch, originFromCenter, cornerRadius, gapFraction, minGap: CGFloat
    let color: Paint
    let roundOrigin: Bool
    let classicFlag: ClassicFlag
    let aeroFlag: AeroFlag
    let orb: Orb
    let overflow: Overflow
    let normal, pressed, open: State
    let images: Images
    let imageSize: NSSize
    let fit: Fit
    let wallpaper: String

    init() { self.init(ThemeLoader().load("win95").theme) }
    init(_ resolved: ResolvedTheme) {
        let r = Reader(resolved: resolved)
        let p = "startButton.drawerParams"
        let platePath = p + ".plate"
        plate = Plate(enabled: r.b(platePath + ".enabled", resolved.config.family == .modern),
                      inset: r.n(platePath + ".inset", 2), radius: r.n(platePath + ".radius", 4),
                      hover: r.platePaint(platePath + ".hover", 0.07),
                      pressed: r.platePaint(platePath + ".pressed", 0.12),
                      open: r.platePaint(platePath + ".open", 0.07))
        let fallbackDrawer = resolved.config.family == .classic ? "win95Flag" : "win11Logo"
        var selected = resolved.config.startButton.drawer
        let params = resolved.config.startButton.drawerParams
        func image(_ key: String) -> NSImage? {
            let path = key.split(separator: ".").map(String.init)
            let value = ThemeJSON.object(params).at(path)
            return ThemeImageAsset.load(value, root: resolved.imageAssetRoots[key] ?? resolved.assetRoot)
        }
        if selected == "image", let normal = image(params["states"]?["normal"] == nil ? "file" : "states.normal") {
            images = .loaded(normal: normal, hover: image("states.hover") ?? normal, pressed: image("states.pressed") ?? normal)
        } else {
            images = .none
            if selected == "image" { selected = fallbackDrawer }
        }
        drawer = selected
        let labelNode = r.node("startButton.label")
        let descriptor = resolved.fonts["startButton.label.font"]
        let fontSize = CGFloat(descriptor?.size ?? 11)
        var font = NSFont(name: descriptor?.family ?? "Tahoma-Bold", size: fontSize)
            ?? (descriptor?.fallback == "system" ? .systemFont(ofSize: fontSize) : .boldSystemFont(ofSize: fontSize))
        if descriptor?.weight == "boldItalic" {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        label = Label(visible: labelNode != nil && labelNode != .null,
                      key: r.s("startButton.label.key", "Start"), font: font,
                      color: r.paint("startButton.label.color", .string("system:black")))
        glyphRect = NSRect(x: r.n(p + ".glyphRect.x", 5), y: 0,
                           width: r.n(p + ".glyphRect.width", 21), height: r.n(p + ".glyphRect.height", 14))
        labelGap = r.n(p + ".labelGap", 3)
        labelTrailingInset = r.n(p + ".labelTrailingInset", 2)
        flagVisualWidth = r.n(p + ".flagVisualWidth", 0)
        labelObliqueness = r.n(p + ".labelObliqueness", 0)
        radius = r.n(p + ".radius", 8)
        angle = r.n(p + ".angle", 90)
        gradient = r.paints(p + ".gradient", [.string("#32B4F5"), .string("#0078D4")], exactCount: false)
        hoverGradient = r.paints(p + ".hoverGradient", gradient)
        pressedGradient = r.paints(p + ".pressedGradient", gradient)
        pillLeftRadius = r.n(p + ".pillLeftRadius", radius)
        pillRightRadius = r.n(p + ".pillRightRadius", radius)
        pillHighlightHeight = r.n(p + ".pillHighlightHeight", 0)
        pillShadowHeight = r.n(p + ".pillShadowHeight", 0)
        pillHighlight = r.paint(p + ".pillHighlight", .string("system:clear"))
        pillShadow = r.paint(p + ".pillShadow", .string("system:clear"))
        labelShadow = r.paint(p + ".labelShadow", .string("system:clear"))
        labelShadowOffset = NSPoint(x: r.n(p + ".labelShadowOffset.x", 0), y: r.n(p + ".labelShadowOffset.y", 0))
        diameter = r.n(p + ".diameter", 42)
        size = r.n(p + ".size", 20)
        square = r.n(p + ".square", 10)
        pitch = r.n(p + ".pitch", 12)
        originFromCenter = r.n(p + ".originFromCenter", -11)
        cornerRadius = r.n(p + ".cornerRadius", 0)
        gapFraction = r.n(p + ".gapFraction", 0.08)
        minGap = r.n(p + ".minGap", 1)
        color = r.paint(p + ".color", .string("system:white"))
        roundOrigin = r.b(p + ".roundOrigin", false)
        classicFlag = ClassicFlag(r, p + ".classicFlag")
        aeroFlag = AeroFlag(r, p + ".aeroFlag")
        orb = Orb(r, p + ".orb")
        let o = "startButton.overflow"
        let outer = r.n(o + ".outer", 0)
        let margin = r.n(o + ".panelMargin", 0)
        overflow = Overflow(outer: outer, panelMargin: margin,
                            panelWidth: r.n(o + ".panelWidth", diameter + 2 * margin),
                            panelHeight: r.n(o + ".panelHeight", diameter + 2 * margin),
                            panelInset: r.n(o + ".panelInset", margin),
                            previewExtraHeight: r.n(o + ".previewExtraHeight", 0),
                            menuPadding: r.n(o + ".menuPadding", 0),
                            enabled: outer > 0 || r.b(o + ".enabled", false))
        func state(_ name: String) -> State {
            let path = "startButton.states." + name
            let value = resolved.states[path] ?? resolved.states["startButton.states.normal"]
            let offset = value?.contentOffset ?? []
            let layers = resolved.bevels[value?.bevel ?? ""] ?? []
            return State(fill: r.paint(path + ".fill.color", .string("@face")),
                         inset: CGFloat(value?.inset ?? 0),
                         offset: NSPoint(x: offset.first ?? 0, y: offset.last ?? 0),
                         border: r.paint(path + ".border.color", .string("system:clear")),
                         borderWidth: CGFloat(value?.border?.width ?? 0), hasBorder: value?.border != nil,
                         bevel: layers.map { (Paint(value: $0.topLeft), Paint(value: $0.bottomRight)) })
        }
        normal = state("normal"); pressed = state("pressed"); open = state("open")
        imageSize = NSSize(width: r.n(p + ".width", r.n(p + ".size", 40)),
                           height: r.n(p + ".height", r.n(p + ".size", 40)))
        fit = Fit(rawValue: r.s(p + ".fit", "contain")) ?? .contain
        wallpaper = r.s("startButton.previewWallpaper", "none")
    }

    fileprivate struct Reader {
        let resolved: ResolvedTheme
        func node(_ path: String) -> ThemeJSON? {
            var value: ThemeJSON? = resolved.json
            for key in path.split(separator: ".").map(String.init) {
                if case .array(let items)? = value, let index = Int(key), items.indices.contains(index) { value = items[index] }
                else { value = value?[key] }
            }
            return value
        }
        func n(_ path: String, _ fallback: CGFloat) -> CGFloat { CGFloat(node(path)?.number ?? Double(fallback)) }
        func s(_ path: String, _ fallback: String) -> String { node(path)?.string ?? fallback }
        func b(_ path: String, _ fallback: Bool) -> Bool {
            if case .bool(let value)? = node(path) { return value }
            return fallback
        }
        func paint(_ path: String, _ fallback: ThemeJSON) -> Paint {
            let value = (try? ThemeColor.parse(node(path) ?? fallback, palette: resolved.config.palette))
                ?? (try? ThemeColor.parse(fallback, palette: resolved.config.palette)) ?? .system("clear")
            return Paint(value: value)
        }
        func platePaint(_ path: String, _ alpha: CGFloat) -> Paint {
            // A plate's separate alpha replaces the base alpha, matching the original
            // modern renderer even when labelColor itself has a non-unit alpha.
            if node(path)?["color"] != nil {
                return Paint(value: paint(path + ".color", .string("system:labelColor")).value,
                             alpha: n(path + ".alpha", alpha), appliesAlpha: true)
            }
            if node(path) != nil { return paint(path, .string("system:clear")) }
            return Paint(value: .system("labelColor"), alpha: alpha, appliesAlpha: true)
        }
        func paints(_ path: String, _ fallback: [ThemeJSON], exactCount: Bool = true) -> [Paint] {
            guard case .array(let items)? = node(path), (exactCount ? items.count == fallback.count : items.count >= 2) else {
                return fallback.map { Paint(value: (try? ThemeColor.parse($0, palette: resolved.config.palette)) ?? .system("clear")) }
            }
            return items.enumerated().map { index, _ in paint(path + ".\(index)", fallback[min(index, fallback.count - 1)]) }
        }
        func paints(_ path: String, _ fallback: [Paint]) -> [Paint] {
            guard case .array(let items)? = node(path), items.count >= 2 else { return fallback }
            return items.indices.map { paint(path + ".\($0)", .string("system:clear")) }
        }
        func numbers(_ path: String, _ fallback: [CGFloat]) -> [CGFloat] {
            guard case .array(let items)? = node(path), items.count == fallback.count else { return fallback }
            return zip(items, fallback).map { CGFloat($0.0.number ?? Double($0.1)) }
        }
    }
}

/// Both validation and rendering use this decoder, including path containment and format checks.
/// NSImage is decoded while loading; no file I/O happens in a drawer.
enum ThemeImageAsset {
    static func load(_ value: ThemeJSON?, root: URL?) -> NSImage? {
        guard let root, let file = value?.string, !file.isEmpty, !file.hasPrefix("/") else { return nil }
        let base = root.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), ["png", "pdf"].contains(url.pathExtension.lowercased()),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 4 * 1024 * 1024,
              let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0,
              image.representations.allSatisfy({ $0.pixelsWide == 0 || ($0.pixelsWide <= 1024 && $0.pixelsHigh <= 1024) }) else { return nil }
        return image
    }
}
