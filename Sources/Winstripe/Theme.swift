import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Colors for one look. Classic themes use 3D bevels; the others use gradients.
struct Theme {
    var kind: ThemeKind
    var classic: Bool
    var face = NSColor(hex: 0xC0C0C0)
    var highlight = NSColor.white
    var light = NSColor(hex: 0xDFDFDF)
    var shadow = NSColor(hex: 0x808080)
    var darkShadow = NSColor.black
    var barFill: [NSColor]
    var barEdge: NSColor = .clear
    var buttonFill: [NSColor] = []
    var activeButtonFill: [NSColor] = []
    var buttonBorder: NSColor = .clear
    var buttonText: NSColor = .black
    var startFill: [NSColor] = []
    var startText: NSColor = .black
    var trayFill: [NSColor] = []
    var trayBorder: NSColor = .clear
    var trayText: NSColor = .black
    var menuFace = NSColor(hex: 0xC0C0C0)
    var menuText: NSColor = .black
    var menuHighlight = NSColor(hex: 0x000080)
    var bannerFill: [NSColor] = [NSColor(hex: 0x808080)]
    var bannerText = NSColor(hex: 0xC0C0C0)
    var bannerSuffix = "95"
    var cornerRadius: CGFloat = 0
    var inputBadge = NSColor(hex: 0x000080)
    var classicConfig: ClassicTheme? = nil
    var modernButton: ModernButtonStyle? = nil
    var trayStyle = TrayStyle()
    var layoutStyle = LayoutStyle()
    var startStyle = StartButtonStyle()

    @MainActor private static var cache: [ThemeKind: Theme] = [:]
    @MainActor private static var userCache: [String: Theme] = [:]

    @MainActor
    static func make(_ kind: ThemeKind) -> Theme {
        if let cached = cache[kind] { return cached }
        // Cold miss: resolve synchronously (~10ms) instead of caching a Win95-looking
        // fallback forever. Theme switches prewarm off-main so this is rare there.
        let result = ThemeResolutionCache.shared.cached(kind.id)
            ?? (try? ThemeResolutionCache.shared.loadSync(kind.id))
        guard let result else { return fallbackMake(kind) }
        do {
            guard result.succeeded,
                  result.theme.config.id == kind.id else { throw ThemeColorError.invalid }
            let theme = ThemeResolutionCache.shared.cachedTheme(kind.id)
                ?? (try? fromConfig(result.theme, kind: kind))
            guard let theme else { throw ThemeColorError.invalid }
            cache[kind] = theme
            return theme
        } catch {
            assertionFailure("Invalid compiled theme \(kind.id): \(error)")
            let fallback = fallbackMake(kind)
            cache[kind] = fallback
            return fallback
        }
    }

    @MainActor
    static func make(_ id: String) -> Theme {
        if let kind = ThemeKind(themeID: id) { return make(kind) }
        if let cached = userCache[id] { return cached }
        if let theme = ThemeResolutionCache.shared.cachedTheme(id) {
            userCache[id] = theme
            return theme
        }
        let result = ThemeResolutionCache.shared.cached(id)
            ?? (try? ThemeResolutionCache.shared.loadSync(id))
        guard let result else { return make(.win95) }
        let kind = result.theme.config.family == .modern ? ThemeKind.win11 : ThemeKind.win95
        do {
            let theme = try fromConfig(result.theme, kind: kind)
            userCache[id] = theme
            return theme
        } catch {
            let fallback = make(.win95)
            userCache[id] = fallback
            return fallback
        }
    }

    @MainActor
    static func make(_ settings: TaskbarSettings) -> Theme { make(settings.activeThemeID) }

    /// Converts a background-loaded resolved configuration into the main-actor Theme cache.
    /// JSON parsing and inheritance expansion happen in ThemeLoader off the main actor; this
    /// method only performs the AppKit color/style construction needed by the view layer.
    @MainActor
    static func preload(_ id: String, result: ThemeLoadResult) {
        let canonical = ThemeLoader.canonicalID(id)
        let kind = ThemeKind(themeID: canonical) ?? (result.theme.config.family == .modern ? .win11 : .win95)
        let theme = ThemeResolutionCache.shared.cachedTheme(id)
            ?? (try? fromConfig(result.theme, kind: kind))
        guard let theme else { return }
        if let builtIn = ThemeKind(themeID: canonical), result.succeeded,
           result.theme.config.id == builtIn.id {
            cache[builtIn] = theme
        } else {
            userCache[canonical] = theme
        }
    }

    /// Builds a resolved AppKit theme on the worker that loaded its JSON.
    static func build(_ id: String, result: ThemeLoadResult) -> Theme? {
        let canonical = ThemeLoader.canonicalID(id)
        let kind = ThemeKind(themeID: canonical) ?? (result.theme.config.family == .modern ? .win11 : .win95)
        return try? fromConfig(result.theme, kind: kind)
    }

    @MainActor
    static func clearCachesForBenchmark() {
        cache.removeAll(keepingCapacity: false)
        userCache.removeAll(keepingCapacity: false)
    }

    private struct CompatibilityColors {
        let classic: Bool
        let face, highlight, light, shadow, darkShadow: ThemeColor
        let barFill: [ThemeColor]
        let barEdge: ThemeColor
        let buttonFill, activeButtonFill: [ThemeColor]
        let buttonBorder, buttonText: ThemeColor
        let startFill: [ThemeColor]
        let startText: ThemeColor
        let trayFill: [ThemeColor]
        let trayBorder, trayText, inputBadge: ThemeColor
    }

    private static func compatibilityColors(_ resolved: ResolvedTheme) throws -> CompatibilityColors {
        let json = resolved.json
        func node(_ path: String) -> ThemeJSON? { json.at(path.split(separator: ".").map(String.init)) }
        func color(_ value: ThemeJSON?) throws -> ThemeColor {
            guard let value else { throw ThemeColorError.invalid }
            return try ThemeColor.parse(value, palette: resolved.config.palette)
        }
        func colors(_ value: ThemeJSON?) throws -> [ThemeColor] {
            guard case .array(let values)? = value else { return [] }
            return try values.map { try color($0) }
        }
        func stops(_ path: String) throws -> [ThemeColor] {
            try colors(node(path))
        }
        let palette = resolved.config.palette
        func paletteColor(_ name: String) throws -> ThemeColor {
            try color(palette[name])
        }
        let barMaterial = resolved.config.bar.material
        let barFill: [ThemeColor]
        if let explicit = barMaterial.taskbarFill {
            barFill = try colors(.array(explicit))
        } else {
            switch barMaterial.type {
            case "gradient": barFill = try stops("bar.material.stops")
            case "solid": barFill = [try color(node("bar.material.color"))]
            case "aeroGlass": barFill = [try color(node("bar.material.tint"))]
            default: barFill = []
            }
        }
        let barEdge: ThemeColor
        if barMaterial.type == "gradient", let line = resolved.config.bar.edge.values.flatMap({ $0 }).first {
            barEdge = try color(line.color)
        } else if barMaterial.variant == "vista", let value = resolved.config.bar.edgeColor {
            barEdge = try color(value)
        } else if barMaterial.type == "aeroGlass", let value = node("bar.material.params.edgeInnerColor") {
            barEdge = try color(value)
        } else if let value = resolved.config.bar.edgeColor {
            barEdge = try color(value)
        } else if let line = resolved.config.bar.edge.values.flatMap({ $0 }).first {
            barEdge = try color(line.color)
        } else if let value = node("bar.material.params.edgeInnerColor") {
            barEdge = try color(value)
        } else {
            barEdge = try color(.string("system:clear"))
        }
        let buttonFill = try resolved.config.buttons.task.normalFill.map { try colors(.array($0)) }
            ?? stops("buttons.task.normal.fill.stops")
        let activeButtonFill = try resolved.config.buttons.task.activeFill.map { try colors(.array($0)) }
            ?? stops("buttons.task.active.fill.stops")
        let buttonBorder = try color(resolved.config.buttons.task.borderColor
            ?? node("buttons.task.normal.border.color")
            ?? .string("system:clear"))
        let buttonText = try color(resolved.config.buttons.task.textColor ?? node("buttons.task.title.color") ?? palette["text"])
        let startFill = try resolved.config.startButton.fill.map { try colors(.array($0)) }
            ?? colors(node("startButton.drawerParams.gradient"))
        let startText = try color(resolved.config.startButton.textColor
            ?? node("startButton.label.color")
            ?? palette["text"])
        let trayFill: [ThemeColor]
        if let explicit = resolved.config.tray.container.fill.taskbarFill {
            trayFill = try colors(.array(explicit))
        } else if resolved.config.tray.container.fill.type == "gradient" {
            trayFill = try stops("tray.container.fill.stops")
        } else {
            trayFill = []
        }
        let trayBorder = try color(resolved.config.tray.container.leadingBorder ?? .string("system:clear"))
        let trayText = try color(resolved.config.tray.textColor ?? node("tray.clock.color") ?? palette["text"])
        let inputValue = node("tray.inputLanguage.fill")
        let inputBadge = try color(inputValue?.string == "system:clear" ? palette["inputBadge"] : (inputValue ?? palette["inputBadge"]))
        return CompatibilityColors(
            classic: resolved.config.family == .classic,
            face: try paletteColor("face"), highlight: try paletteColor("highlight"),
            light: try paletteColor("light"), shadow: try paletteColor("shadow"),
            darkShadow: try paletteColor("darkShadow"), barFill: barFill, barEdge: barEdge,
            buttonFill: buttonFill, activeButtonFill: activeButtonFill, buttonBorder: buttonBorder,
            buttonText: buttonText, startFill: startFill, startText: startText,
            trayFill: trayFill, trayBorder: trayBorder, trayText: trayText, inputBadge: inputBadge)
    }

    private static func fromConfig(_ resolved: ResolvedTheme, kind: ThemeKind) throws -> Theme {
        let m = resolved.config.startMenu
        let p = try compatibilityColors(resolved)
        func color(_ value: ThemeJSON) throws -> NSColor {
            try ThemeColor.parse(value, palette: resolved.config.palette).resolve(settings: TaskbarSettings())
        }
        func resolvedColor(_ value: ThemeColor) -> NSColor { value.resolve(settings: TaskbarSettings()) }
        var t = Theme(kind: kind, classic: p.classic, barFill: p.barFill.map(resolvedColor),
                      trayStyle: TrayStyle(resolved), layoutStyle: LayoutStyle(resolved), startStyle: StartButtonStyle(resolved))
        t.face = resolvedColor(p.face)
        t.highlight = resolvedColor(p.highlight)
        t.light = resolvedColor(p.light)
        t.shadow = resolvedColor(p.shadow)
        t.darkShadow = resolvedColor(p.darkShadow)
        t.barEdge = resolvedColor(p.barEdge)
        t.buttonFill = p.buttonFill.map(resolvedColor)
        t.activeButtonFill = p.activeButtonFill.map(resolvedColor)
        t.buttonBorder = resolvedColor(p.buttonBorder)
        t.buttonText = resolvedColor(p.buttonText)
        t.startFill = p.startFill.map(resolvedColor)
        t.startText = resolvedColor(p.startText)
        t.trayFill = p.trayFill.map(resolvedColor)
        t.trayBorder = resolvedColor(p.trayBorder)
        t.trayText = resolvedColor(p.trayText)
        t.inputBadge = resolvedColor(p.inputBadge)
        t.cornerRadius = CGFloat(resolved.config.metrics.cornerRadius)
        t.menuFace = try color(m.colors.face)
        t.menuText = try color(m.colors.text)
        t.menuHighlight = try color(m.colors.highlight)
        t.bannerFill = try m.banner.fill.map(color)
        t.bannerText = try color(m.banner.text)
        t.bannerSuffix = m.banner.suffix
        if resolved.config.family == .classic {
            t.classicConfig = try ClassicTheme(resolved)
        }
        t.modernButton = ModernButtonStyle.make(resolved)
        return t
    }

    #if DEBUG
    /// Reflection makes newly added stored Theme fields participate automatically.
    @MainActor
    static func checkParity() -> Bool {
        var failures: [String] = []
        for kind in ThemeKind.allCases {
            let result = ThemeLoader().load(kind.id)
            guard result.succeeded, result.diagnostics.isEmpty,
                  let actual = try? fromConfig(result.theme, kind: kind) else {
                failures.append("\(kind.id): config failed")
                continue
            }
            let expected = fallbackMake(kind)
            let left = Array(Mirror(reflecting: actual).children)
            let right = Array(Mirror(reflecting: expected).children)
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: appearanceName) else {
                    failures.append("Missing appearance \(appearanceName)")
                    continue
                }
                appearance.performAsCurrentDrawingAppearance {
                    func equalColor(_ a: NSColor, _ b: NSColor) -> Bool {
                        // Check native construction too, then both requested conversions.
                        for space in [NSColorSpace.sRGB, .deviceRGB] {
                            guard let x = a.usingColorSpace(space), let y = b.usingColorSpace(space) else { return false }
                            if x.redComponent != y.redComponent || x.greenComponent != y.greenComponent ||
                                x.blueComponent != y.blueComponent || x.alphaComponent != y.alphaComponent { return false }
                        }
                        return true
                    }
                    for (a, b) in zip(left, right) {
                        if a.label == "classicConfig" || a.label == "modernButton" || a.label == "trayStyle" || a.label == "layoutStyle" || a.label == "startStyle" { continue }
                        let equal: Bool
                        if let x = a.value as? NSColor, let y = b.value as? NSColor {
                            equal = equalColor(x, y)
                        } else if let x = a.value as? [NSColor], let y = b.value as? [NSColor] {
                            equal = x.count == y.count && zip(x, y).allSatisfy(equalColor)
                        } else if let x = a.value as? Bool, let y = b.value as? Bool { equal = x == y }
                        else if let x = a.value as? CGFloat, let y = b.value as? CGFloat { equal = x == y }
                        else if let x = a.value as? String, let y = b.value as? String { equal = x == y }
                        else if let x = a.value as? ThemeKind, let y = b.value as? ThemeKind { equal = x == y }
                        else { equal = false }
                        if !equal { failures.append("\(kind.id).\(a.label ?? "?") (\(appearanceName.rawValue))") }
                    }
                }
            }
        }
        for failure in failures { FileHandle.standardError.write(Data(("FAIL parity: \(failure)\n").utf8)) }
        if failures.isEmpty { print("PASS exact Theme parity: 10 kinds, aqua/darkAqua, sRGB/deviceRGB") }
        return failures.isEmpty
    }
    #endif

    private static func fallbackMake(_ kind: ThemeKind) -> Theme {
        switch kind {
        case .win95:
            return Theme(kind: kind, classic: true, barFill: [NSColor(hex: 0xC0C0C0)])
        case .win98:
            var t = Theme(kind: kind, classic: true, barFill: [NSColor(hex: 0xC0C0C0)])
            t.bannerFill = [NSColor(hex: 0x1084D0), NSColor(hex: 0x000080)]
            t.bannerText = .white
            t.bannerSuffix = "98"
            return t
        case .winME:
            var t = Theme(kind: kind, classic: true, barFill: [NSColor(hex: 0xD4D0C8)])
            t.face = NSColor(hex: 0xD4D0C8)
            t.light = .white
            t.menuFace = t.face
            t.menuHighlight = NSColor(hex: 0x316AC5)
            t.bannerFill = [NSColor(hex: 0x3A6EA5), NSColor(hex: 0x0B3D91)]
            t.bannerText = .white
            t.bannerSuffix = "ME"
            t.inputBadge = NSColor(hex: 0x316AC5)
            return t
        case .win2000:
            var t = Theme(kind: kind, classic: true, barFill: [NSColor(hex: 0xD4D0C8)])
            t.face = NSColor(hex: 0xD4D0C8)
            t.light = .white
            t.menuFace = t.face
            t.menuHighlight = NSColor(hex: 0x0A246A)
            t.bannerFill = [NSColor(hex: 0x808080), NSColor(hex: 0x000080)]
            t.bannerText = .white
            t.bannerSuffix = "2000"
            t.inputBadge = NSColor(hex: 0x0A246A)
            return t
        case .winXP:
            var t = Theme(kind: kind, classic: true,
                          barFill: [NSColor(hex: 0x3168D5), NSColor(hex: 0x4993E6), NSColor(hex: 0x2157D7), NSColor(hex: 0x2663E0), NSColor(hex: 0x1941A5)])
            t.barEdge = NSColor(hex: 0x5A8FE8)
            t.buttonFill = [NSColor(hex: 0x6CA0F7), NSColor(hex: 0x3C81F3), NSColor(hex: 0x2B6BE0)]
            t.activeButtonFill = [NSColor(hex: 0x1542A8), NSColor(hex: 0x1E52B7), NSColor(hex: 0x245ED4)]
            t.buttonBorder = NSColor(hex: 0x1941A5)
            t.buttonText = .white
            t.startFill = [NSColor(hex: 0x7ED57E), NSColor(hex: 0x3DB43D), NSColor(hex: 0x2A752E), NSColor(hex: 0x144818)]
            t.startText = t.buttonText
            t.trayFill = [NSColor(hex: 0x16ADF0), NSColor(hex: 0x19B9F3), NSColor(hex: 0x118FE9), NSColor(hex: 0x0E9EF0), NSColor(hex: 0x1580D9)]
            t.trayBorder = NSColor(hex: 0x0F3D97)
            t.trayText = .white
            t.menuFace = .white
            t.menuHighlight = NSColor(hex: 0x316AC5)
            t.bannerFill = [NSColor(hex: 0x1868CE), NSColor(hex: 0x0E60CB), NSColor(hex: 0x1164CF), NSColor(hex: 0x0A49B4)]
            t.bannerText = .white
            t.bannerSuffix = "XP"
            t.cornerRadius = 3
            t.inputBadge = NSColor(hex: 0x0F3D97)
            return t
        case .vista, .win7:
            var t = Theme(kind: kind, classic: false,
                          barFill: [kind == .vista ? NSColor(hex: 0x000000, alpha: 0.82) : NSColor(hex: 0x2D4B64, alpha: 0.78)])
            t.barEdge = NSColor(white: 1, alpha: 0.25)
            t.buttonFill = [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0.06)]
            t.activeButtonFill = [NSColor(white: 1, alpha: 0.40), NSColor(white: 1, alpha: 0.16)]
            t.buttonBorder = NSColor(white: 1, alpha: 0.35)
            t.buttonText = .white
            t.startFill = [NSColor(hex: 0x6DB3F2), NSColor(hex: 0x1E69DE), NSColor(hex: 0x0E3F8C)]
            t.startText = t.buttonText
            t.trayText = .white
            t.menuFace = NSColor(hex: 0xF4F7FC)
            t.menuHighlight = NSColor(hex: 0x3399FF)
            t.bannerFill = [NSColor(hex: 0x2B4C73), NSColor(hex: 0x10233A)]
            t.bannerText = .white
            t.bannerSuffix = "7"
            t.cornerRadius = 3
            t.inputBadge = NSColor(hex: 0x1E69DE)
            return t
        case .win11:
            var t = Theme(kind: kind, classic: false, barFill: [])
            t.barEdge = .separatorColor
            t.buttonText = .labelColor
            t.trayText = .labelColor
            t.menuText = .labelColor
            t.menuFace = .windowBackgroundColor
            t.menuHighlight = .controlAccentColor
            t.cornerRadius = 4
            return t
        case .win10:
            let bar = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(hex: 0x101010, alpha: 0.97) : NSColor(hex: 0xEEEEEE, alpha: 0.98)
            }
            let button = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(hex: 0x202020, alpha: 0.45) : NSColor(hex: 0xFFFFFF, alpha: 0.65)
            }
            var t = Theme(kind: kind, classic: false, barFill: [bar])
            t.barEdge = NSColor(hex: 0x2A2A2A, alpha: 0.8)
            t.buttonFill = [button]
            t.activeButtonFill = [NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(hex: 0x343434, alpha: 0.85) : NSColor(hex: 0xD8D8D8, alpha: 0.9)
            }]
            t.buttonText = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
            }
            t.startText = .white
            t.trayText = t.buttonText
            t.menuFace = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(hex: 0x1B1B1B, alpha: 0.98) : NSColor(hex: 0xEEEEEE, alpha: 0.98)
            }
            t.menuText = t.buttonText
            t.menuHighlight = NSColor(hex: 0x0078D7)
            t.inputBadge = NSColor(hex: 0x0078D7)
            return t
        case .win8:
            var t = Theme(kind: kind, classic: false,
                          barFill: [NSColor(hex: 0x087E8B, alpha: 0.88)])
            t.barEdge = NSColor(hex: 0x8DE1E8, alpha: 0.32)
            t.buttonFill = [NSColor(hex: 0xFFFFFF, alpha: 0.10)]
            t.activeButtonFill = [NSColor(hex: 0xFFFFFF, alpha: 0.24)]
            t.buttonText = .white
            t.startText = .white
            t.trayText = .white
            t.menuFace = NSColor(hex: 0x2D004E)
            t.menuText = .white
            t.menuHighlight = NSColor(hex: 0x2672EC)
            t.inputBadge = NSColor(hex: 0x2672EC)
            return t
        }
    }
}
