import Foundation
import Darwin

struct ThemeDiagnostic: Sendable {
    enum Severity: String, Sendable { case warning, error }
    let severity: Severity
    let path: String
    let message: String
    var description: String { "\(severity.rawValue): \(path): \(message)" }
}

struct ThemeLoadResult {
    let theme: ResolvedTheme
    let diagnostics: [ThemeDiagnostic]
    var succeeded: Bool { !diagnostics.contains { $0.severity == .error } }
}

private struct ThemeLoadError: Error, CustomStringConvertible {
    let path: String
    let description: String
}

/// No application, settings store, views, or windows are needed to load a theme.
final class ThemeLoader {
    #if DEBUG
    static var debugThemeDirectory: URL?
    #endif
    private var diagnostics: [ThemeDiagnostic] = []
    private var imageAssetRoots: [String: URL] = [:]
    private let decoder = JSONDecoder()
    private static let builtinJSONCache = BuiltinThemeJSONCache()
    private static let builtinResolvedJSONCache = BuiltinThemeJSONCache()
    private static let geometryChoices: [String: Set<String>] = [
        "xPlacement": ["fixed", "flow", "center", "trailing"],
        "yPlacement": ["fixed", "flow", "center", "trailing"],
        "widthMode": ["fixed", "bounds", "remaining"],
        "heightMode": ["fixed", "bounds", "remaining"]
    ]
    private static let allowedTrayItems: Set<String> = ["chevron", "inputLanguage", "actionCenter", "clock", "showDesktop"]
    private static let materialTypes: Set<String> = ["none", "solid", "gradient", "pattern", "acrylic", "aeroGlass", "aeroButton", "image"]
    private static let materialParameters: [String: Set<String>] = [
        "pattern": ["checker2x2"], "variant": ["vista", "win7"], "hotTrack": ["iconAverage", "none"]
    ]
    private static let allowedColorFields: Set<String> = ["light", "dark", "color", "white", "alpha"]
    private static let drawerParameterKeys: Set<String> = [
        "file", "states", "width", "height", "size", "fit", "slice", "tint", "variant", "hotTrack",
        "glyphRect", "labelGap", "labelTrailingInset", "flagVisualWidth", "labelObliqueness", "radius", "angle", "gradient", "diameter",
        "square", "pitch", "originFromCenter", "cornerRadius", "gapFraction", "minGap", "color",
        "roundOrigin", "classicFlag", "aeroFlag", "orb", "plate", "hoverGradient", "pressedGradient",
        "pillLeftRadius", "pillRightRadius", "pillHighlightHeight", "pillShadowHeight", "pillHighlight",
        "pillShadow", "labelShadow", "labelShadowOffset"
    ]
    private static let stateParameterKeys: Set<String> = ["normal", "hover", "pressed"]
    private static let materialParameterKeys: Set<String> = [
        "params", "type", "color", "alpha", "stops", "angle", "pattern", "colors", "inset", "appearance",
        "nsMaterial", "snapshotFallback", "variant", "tint", "hotTrack", "file", "slice", "taskbarFill"
    ]
    private static let stateStyleKeys: Set<String> = [
        "fill", "bevel", "border", "radius", "inset", "contentOffset", "boldTitle", "iconOffsetY", "inherit", "when", "rect"
    ]
    private static let allowedKeysCache = BuiltinAllowedKeysCache()

    func loadForID(_ id: String, userDirectory: URL = ThemePaths.userThemesDirectory) throws -> ThemeLoadResult {
        let canonical = Self.canonicalID(id)
        if BuiltinThemes.json[canonical] != nil { return load(canonical) }
        guard let record = UserThemeCatalog.record(id: canonical, directory: userDirectory) else {
            throw ThemeLoadError(path: "$.id", description: "unknown theme \(id)")
        }
        return load(record.url.path, user: true)
    }

    static func canonicalID(_ id: String) -> String {
        switch id {
        case "winXP": return "winxp"
        case "winME": return "winme"
        case "win2k": return "win2000"
        default: return id
        }
    }

    func load(_ source: String, user: Bool = false, allowBuiltInID: Bool = false) -> ThemeLoadResult {
        diagnostics = []
        imageAssetRoots = [:]
        do {
            let url = user ? themeURL(source) : overrideURL(source)
            let inherited = try expand(source, url: url, stack: [])
            if user && !allowBuiltInID, let id = inherited["id"]?.string, BuiltinThemes.json[Self.canonicalID(id)] != nil {
                throw ThemeLoadError(path: "$.id", description: "user theme id \(id) duplicates a built-in theme")
            }
            let family = inherited["family"]?.string ?? "classic"
            guard ["classic", "modern"].contains(family) else {
                throw ThemeLoadError(path: "$.family", description: "expected classic or modern")
            }
            let defaults = try builtin(family == "modern" ? "win11" : "win95", compiledOnly: true)
            var merged = ThemeJSON.merge(defaults, inherited).strippingComments()
            merged = try sanitize(merged, path: [], defaults: defaults, root: merged, assetRoot: url?.deletingLastPathComponent())
            merged = try resolveInheritance(merged)
            let resolved = try resolve(merged, assetRoot: url?.deletingLastPathComponent(), imageAssetRoots: imageAssetRoots)
            log()
            return ThemeLoadResult(theme: resolved, diagnostics: diagnostics)
        } catch {
            let path: String
            if let failure = error as? ThemeLoadError { path = failure.path }
            else if let failure = error as? DecodingError {
                switch failure {
                case .keyNotFound(let key, let c): path = jsonPath(c.codingPath.map(\.stringValue) + [key.stringValue])
                case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): path = jsonPath(c.codingPath.map(\.stringValue))
                @unknown default: path = "$"
                }
            } else { path = "$" }
            diagnostics.append(.init(severity: .error, path: path, message: "\(error); using built-in win95"))
            log()
            // These compiled defaults are checked by check-themes.sh; this path never reads user data.
            do {
                let fallback = try resolveInheritance(builtin("win95", compiledOnly: true).strippingComments())
                return ThemeLoadResult(theme: try resolve(fallback), diagnostics: diagnostics)
            } catch {
                fatalError("Invalid compiled win95 theme: \(error)")
            }
        }
    }

    private func overrideURL(_ source: String) -> URL? {
        #if DEBUG
        if let directory = Self.debugThemeDirectory {
            let url = directory.appendingPathComponent(Self.canonicalID(source) + ".json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        #endif
        return nil
    }

    private func themeURL(_ source: String) -> URL {
        let url = URL(fileURLWithPath: source).standardizedFileURL
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            return url.appendingPathComponent("theme.json")
        }
        return url
    }

    private func builtin(_ id: String, compiledOnly: Bool = false) throws -> ThemeJSON {
        let canonical = Self.canonicalID(id)
        guard let text = AppResources.builtinThemeJSON(canonical) else {
            throw ThemeLoadError(path: "$.extends", description: "unknown built-in theme \(id)")
        }
        #if DEBUG
        if !compiledOnly, let directory = Self.debugThemeDirectory {
            let url = directory.appendingPathComponent(canonical + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                return try decodeBuiltin(data)
            }
        }
        #endif
        return try Self.builtinJSONCache.value(for: canonical) { try decodeBuiltin(Data(text.utf8)) }
    }

    private func decodeBuiltin(_ data: Data) throws -> ThemeJSON {
        var scanner = DuplicateJSONScanner(data: data)
        try scanner.scan()
        return try decodeOnLargeStack(ThemeJSON.self, from: data)
    }

    /// All theme JSON decoding hops to the 8 MB decode thread unless the caller already has a large stack.
    private func decodeOnLargeStack<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = self.decoder
        return try ThemeDecodeThread.run { try decoder.decode(type, from: data) }
    }

    static func clearBuiltinJSONCacheForBenchmark() {
        builtinJSONCache.removeAll()
        builtinResolvedJSONCache.removeAll()
        allowedKeysCache.removeAll()
    }

    static func resolvedBuiltinJSON(_ id: String) -> ThemeJSON {
        let canonical = canonicalID(id)
        return builtinResolvedJSONCache.value(for: canonical) {
            ThemeLoader().load(canonical).theme.json
        }
    }

    private func expand(_ source: String, url: URL?, stack: Set<String>) throws -> ThemeJSON {
        let documentURL = url ?? overrideURL(source)
        let identity = documentURL?.resolvingSymlinksInPath().path ?? Self.canonicalID(source)
        guard !stack.contains(identity) else { throw ThemeLoadError(path: "$.extends", description: "inheritance cycle at \(source)") }
        var value = try documentURL.map {
            let data = try Data(contentsOf: $0)
            var scanner = DuplicateJSONScanner(data: data)
            try scanner.scan()
            return try decodeOnLargeStack(ThemeJSON.self, from: data)
        } ?? builtin(source)
        guard let object = value.object else { throw ThemeLoadError(path: "$", description: "expected JSON object") }
        guard object["$schema"]?.string == "winstripe-theme/1" else {
            throw ThemeLoadError(path: "$.$schema", description: "expected winstripe-theme/1")
        }
        guard let id = object["id"]?.string, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThemeLoadError(path: "$.id", description: "missing or invalid id")
        }
        var canonical = object
        canonical["id"] = ThemeJSON.string(Self.canonicalID(id))
        value = .object(canonical)
        value = migrateDeprecatedBlocks(value)
        guard let migratedObject = value.object else { throw ThemeLoadError(path: "$", description: "expected JSON object") }
        canonical = migratedObject
        if let parentValue = object["extends"] {
            guard let parent = parentValue.string else { throw ThemeLoadError(path: "$.extends", description: "expected theme id or relative path") }
            let base: ThemeJSON
            if BuiltinThemes.json[Self.canonicalID(parent)] != nil {
                base = try expand(Self.canonicalID(parent), url: nil, stack: stack.union([identity]))
            } else if let documentURL {
                let directory = documentURL.deletingLastPathComponent()
                let candidate = directory.appendingPathComponent(parent)
                let parentURL = FileManager.default.fileExists(atPath: candidate.path)
                    ? themeURL(candidate.path)
                    : themeURL(directory.appendingPathComponent(parent + ".json").path)
                base = try expand(parent, url: parentURL, stack: stack.union([identity]))
            } else {
                throw ThemeLoadError(path: "$.extends", description: "unknown theme \(parent)")
            }
            value = ThemeJSON.merge(base, value)
        }
        // Keep each asset relative to the file that declared it, including inherited states.
        if let params = object["startButton"]?["drawerParams"]?.object,
           let folder = documentURL?.deletingLastPathComponent() {
            if params["file"] != nil { imageAssetRoots["file"] = folder }
            for state in ["normal", "hover", "pressed"] where params["states"]?[state] != nil {
                imageAssetRoots["states." + state] = folder
            }
        }
        return value
    }

    private func migrateDeprecatedBlocks(_ value: ThemeJSON) -> ThemeJSON {
        guard var object = value.object else { return value }
        var changed = false
        func has(_ root: ThemeJSON, _ path: [String]) -> Bool {
            guard let value = root.at(path) else { return false }
            return value != .null
        }
        func setting(_ root: ThemeJSON, _ path: [String], _ value: ThemeJSON) -> ThemeJSON {
            guard let first = path.first else { return value }
            guard var object = root.object else { return root }
            if path.count == 1 {
                if object[first] == nil || object[first] == .null { object[first] = value }
            } else {
                object[first] = setting(object[first] ?? .object([:]), Array(path.dropFirst()), value)
            }
            return .object(object)
        }
        if let source = object["legacyTheme"]?.object {
            var migrated = ThemeJSON.object(object)
            for key in ["face", "highlight", "light", "shadow", "darkShadow", "inputBadge"] {
                if let field = source[key], !has(migrated, ["palette", key]) {
                    migrated = setting(migrated, ["palette", key], field)
                }
            }
            if let field = source["barFill"], !has(migrated, ["bar", "material", "color"]) &&
                !has(migrated, ["bar", "material", "stops"]) && !has(migrated, ["bar", "material", "tint"]) {
                migrated = setting(migrated, ["bar", "material", "taskbarFill"], field)
            }
            if let field = source["barEdge"], !has(migrated, ["bar", "edge"]) {
                migrated = setting(migrated, ["bar", "edgeColor"], field)
            }
            if let field = source["buttonFill"], !has(migrated, ["buttons", "task", "normal", "fill"]) {
                migrated = setting(migrated, ["buttons", "task", "normalFill"], field)
            }
            if let field = source["activeButtonFill"], !has(migrated, ["buttons", "task", "active", "fill"]) {
                migrated = setting(migrated, ["buttons", "task", "activeFill"], field)
            }
            if let field = source["buttonBorder"], !has(migrated, ["buttons", "task", "normal", "border"]) {
                migrated = setting(migrated, ["buttons", "task", "borderColor"], field)
            }
            if let field = source["buttonText"], !has(migrated, ["buttons", "task", "title", "color"]) {
                migrated = setting(migrated, ["buttons", "task", "textColor"], field)
            }
            if let field = source["startFill"], !has(migrated, ["startButton", "drawerParams", "gradient"]) {
                migrated = setting(migrated, ["startButton", "fill"], field)
            }
            if let field = source["startText"], !has(migrated, ["startButton", "label", "color"]) {
                migrated = setting(migrated, ["startButton", "textColor"], field)
            }
            if let field = source["trayFill"], !has(migrated, ["tray", "container", "fill", "color"]) &&
                !has(migrated, ["tray", "container", "fill", "stops"]) {
                migrated = setting(migrated, ["tray", "container", "fill", "taskbarFill"], field)
            }
            if let field = source["trayBorder"], !has(migrated, ["tray", "container", "leadingBorder"]) {
                migrated = setting(migrated, ["tray", "container", "leadingBorder"], field)
            }
            if let field = source["trayText"], !has(migrated, ["tray", "textColor"]) && !has(migrated, ["tray", "clock", "color"]) {
                migrated = setting(migrated, ["tray", "textColor"], field)
            }
            if let field = source["inputBadge"], !has(migrated, ["palette", "inputBadge"]) &&
                !has(migrated, ["tray", "inputLanguage", "fill"]) {
                migrated = setting(migrated, ["palette", "inputBadge"], field)
            }
            if let radius = source["cornerRadius"], !has(migrated, ["metrics", "cornerRadius"]) {
                migrated = setting(migrated, ["metrics", "cornerRadius"], radius)
            }
            object = migrated.object ?? object
            object.removeValue(forKey: "legacyTheme")
            changed = true
        }
        if let source = object["legacyMenu"]?.object {
            var startMenu = object["startMenu"]?.object ?? [:]
            if startMenu["colors"] == nil {
                startMenu["colors"] = .object([
                    "face": source["menuFace"] ?? .string("#C0C0C0"),
                    "text": source["menuText"] ?? .string("#000000"),
                    "highlight": source["menuHighlight"] ?? .string("#000080")
                ])
            }
            if startMenu["banner"] == nil {
                startMenu["banner"] = .object([
                    "fill": source["bannerFill"] ?? .array([.string("#808080")]),
                    "text": source["bannerText"] ?? .string("#C0C0C0"),
                    "suffix": source["bannerSuffix"] ?? .string("95")
                ])
            }
            object["startMenu"] = .object(startMenu)
            object.removeValue(forKey: "legacyMenu")
            changed = true
        }
        if changed { warn([], "deprecated theme color blocks migrated to their natural fields") }
        return .object(object)
    }

    private func jsonPath(_ path: [String]) -> String {
        path.reduce("$") { $0 + (Int($1) == nil ? ".\($1)" : "[\($1)]") }
    }

    private func warn(_ path: [String], _ message: String) {
        diagnostics.append(.init(severity: .warning, path: jsonPath(path), message: message))
    }

    private func defaultValue(_ path: [String], defaults: ThemeJSON, color: Bool = false) -> ThemeJSON {
        if let value = defaults.at(path) { return value }
        if color { return defaults["palette"]?["text"] ?? .string("#000000") }
        if path.last == "fill" || path.last == "material" { return defaults["bar"]?["material"] ?? .object(["type": .string("none")]) }
        return .null
    }

    private static let choices: [String: Set<String>] = [
        "layout.engine": ["linear", "aero", "win8"],
        "layout.pins": ["superbar", "quickLaunch"],
        "layout.labelMode": ["never", "always", "byGrouping"],
        "layout.overflow": ["shrinkThenHide", "shrinkLabelsThenHide"],
        "layout.linear.taskWidth": ["equalShare", "measured"],
        "layout.linear.rounding": ["none", "floorAfterCap"],
        "layout.linear.quickPlacement": ["none", "separate", "group"],
        "layout.linear.trayWidth": ["preferred", "clamped", "remaining"],
        "layout.linear.buttonCross": ["fixed", "bounds", "center"],
        "layout.linear.startCross": ["fixed", "bounds", "center"],
        "layout.vertical.startWidth": ["fixed", "bounds"],
        "layout.vertical.taskWidth": ["fixed", "bounds"],
        "layout.vertical.traySizing": ["button", "preferred", "fixed"],
        "layout.aero.orbAnchor": ["fixed", "outer"],
        "tray.layout": ["linear", "aero", "win8"],
        "tray.smoothing": ["always", "setting"],
        "tray.clock.measure": ["clockText", "maxClockDate"],
        "tray.vertical.trigger": ["heightOver", "verticalLayout"],
        "tray.chevron.style": ["text", "symbol", "aeroTriangle"],
        "tray.inputLanguage.style": ["badge", "text"],
        "tray.actionCenter.style": ["speechBubble", "flag"],
        "tray.showDesktop.style": ["classicButton", "hairline", "aeroStrip", "none"],
        "layout.groupingDefault": ["alwaysCombine", "combineWhenFull", "neverCombine"],
        "fonts.smoothing": ["userSetting", "forcedOn"],
        "startButton.drawer": ["win95Flag", "xpPill", "vistaOrb", "win7Orb", "win8Logo", "win10Logo", "win11Logo", "image"],
        "startButton.drawerParams.fit": ["contain", "cover", "stretch"],
        "startButton.previewWallpaper": ["none", "vista", "win7"],
        "startMenu.default": ["classic95", "classic98", "classicME", "classic2000", "classicXP", "win95", "win98", "winME", "win2000", "xp", "vista", "win7", "win8", "win10", "win11"],
        "previews.style": ["classicTitleList", "aeroGlass", "flatDark", "win11Acrylic"],
        "buttons.task.fillRule.normalWhen": ["never", "task", "runningTask", "runningTitledTask"],
        "buttons.task.fillRule.normalState": ["normal", "normalLabelled"],
        "buttons.task.icon.symbolSource": ["sfPlain", "sfPalette", "win8Glyph"],
        "buttons.task.title.layout": ["afterImage", "fixed"],
        "buttons.task.title.smoothing": ["always", "setting"]
    ]

    private func isColor(_ value: ThemeJSON, path: [String]) -> Bool {
        let key = path.last ?? ""
        if ["edgeColor", "borderColor", "textColor"].contains(key) { return true }
        if path.count > 1, Int(key) != nil,
           ["taskbarFill", "normalFill", "activeFill"].contains(path[path.count - 2]) { return true }
        if path == ["startButton", "fill"] { return false }
        if path.starts(with: ["startButton", "fill"]) { return true }
        if path.starts(with: ["startMenu", "colors"]) { return path.count == 3 }
        if path.starts(with: ["startMenu", "banner"]) {
            if path.count == 2 { return false }
            if path.count == 3 { return key != "fill" && key != "suffix" }
            return true
        }
        if path.count == 4 && path.starts(with: ["startButton", "drawerParams", "plate"]) && ["hover", "pressed", "open"].contains(key) { return true }
        if path.starts(with: ["startButton", "drawerParams"]) {
            if ["red", "green", "blue", "yellow", "outline", "glowColor", "glowEnd", "glowFill", "hoverColor", "highlightColor", "pressedColor", "borderColor"].contains(key) { return true }
            if path.count > 1 && path[path.count - 2] == "sheenColors" { return true }
        }
        if path.first == "palette" && path.count == 2 { return true }
        if ["color", "textColor", "lineColor", "topLeft", "bottomRight", "tint", "leadingBorder", "symbolColor", "edgeOuterColor", "edgeInnerColor", "separatorDark", "separatorLight"].contains(key) { return true }
        if key == "fill", path == ["buttons", "badge", "fill"] || path == ["tray", "inputLanguage", "fill"] || path == ["tray", "appIcon", "fill"] || path == ["previews", "params", "fill"] { return true }
        if path.contains("snapshotFallback") { return true }
        if path.count > 1 && ["colors", "gradient", "stops"].contains(path[path.count - 2]), value.object?["color"] == nil { return true }
        return false
    }

    private func sanitize(_ value: ThemeJSON, path: [String], defaults: ThemeJSON, root: ThemeJSON, assetRoot: URL?) throws -> ThemeJSON {
        let key = path.joined(separator: ".")
        if path.first == "tray", let field = path.last {
            if let allowed = Self.geometryChoices[field], !allowed.contains(value.string ?? "") {
                warn(path, "unknown geometry value; using family default")
                return defaultValue(path, defaults: defaults)
            }
        }
        if let allowed = Self.choices[key], !allowed.contains(value.string ?? "") {
            warn(path, "unknown value; using family default")
            return defaultValue(path, defaults: defaults)
        }
        if key == "tray.items", case .array(let items) = value {
            if items.contains(where: { !Self.allowedTrayItems.contains($0.string ?? "") }) {
                warn(path, "unknown tray item; using family default")
                return defaultValue(path, defaults: defaults)
            }
        }
        if value == .null, path.first == "tray" { return value }
        if isColor(value, path: path) {
            do {
                _ = try ThemeColor.parse(value, palette: root["palette"]?.object ?? [:])
                if let object = value.object {
                    for field in object.keys.sorted() where !Self.allowedColorFields.contains(field) && !field.hasPrefix("_") {
                        warn(path + [field], "unknown field ignored")
                    }
                    return .object(object.filter { Self.allowedColorFields.contains($0.key) })
                }
                return value
            } catch {
                warn(path, "invalid color; using family default")
                return defaultValue(path, defaults: defaults, color: true)
            }
        }
        if ["metrics.barThickness", "metrics.buttonGap", "startButton.overflow.outer"].contains(key), let n = value.number {
            let limit = key == "metrics.barThickness" ? 80 : key == "metrics.buttonGap" ? 16 : (root["metrics"]?["barThickness"]?.number ?? 30).clamped(20, 80) / 2
            let minimum: Double = key == "metrics.barThickness" ? 20 : 0
            let clamped = n.clamped(minimum, limit)
            if n != clamped { warn(path, "clamped \(n) to \(clamped)") }
            return .number(clamped)
        }
        if key == "layout.fixedItems", case .array(let items) = value {
            if items.contains(where: { !["win10Search", "win10TaskView", "vistaShowDesktop"].contains($0.string ?? "") }) {
                warn(path, "unknown fixed item; using family default")
                return defaultValue(path, defaults: defaults)
            }
        }
        if case .object(var object) = value {
            if let type = object["type"]?.string, ["material", "fill"].contains(path.last ?? "") {
                if !Self.materialTypes.contains(type) {
                    warn(path + ["type"], "unknown material; using family default")
                    return defaultValue(path, defaults: defaults)
                }
                if type == "image", !validAsset(object["file"], root: assetRoot) {
                    warn(path + ["file"], "image unavailable or forbidden; using family default")
                    return defaultValue(path, defaults: defaults)
                }
                let required: [String]
                switch type {
                case "solid": required = ["color"]
                case "gradient": required = ["stops"]
                case "pattern": required = ["pattern", "colors"]
                case "acrylic": required = ["snapshotFallback"]
                case "aeroGlass": required = ["variant", "tint"]
                default: required = []
                }
                if let missing = required.first(where: { object[$0] == nil || object[$0] == .null }) {
                    throw ThemeLoadError(path: jsonPath(path + [missing]), description: "missing required material parameter")
                }
                for parameter in Self.materialParameters.keys.sorted() {
                    if let field = object[parameter], !Self.materialParameters[parameter, default: []].contains(field.string ?? "") {
                        warn(path + [parameter], "unknown material parameter; using family default")
                        return defaultValue(path, defaults: defaults)
                    }
                }
                if let alpha = object["alpha"], alpha.number.map({ (0...1).contains($0) }) != true {
                    warn(path + ["alpha"], "invalid material alpha; using family default")
                    return defaultValue(path, defaults: defaults)
                }
                if type == "gradient", case .array(let stops) = object["stops"], stops.count < 2 {
                    warn(path + ["stops"], "gradient needs at least two stops; using family default")
                    return defaultValue(path, defaults: defaults)
                }
                if type == "pattern", case .array(let colors) = object["colors"], colors.count != 2 {
                    warn(path + ["colors"], "checker2x2 needs two colors; using family default")
                    return defaultValue(path, defaults: defaults)
                }
                if type == "gradient", object["angle"] == nil { object["angle"] = .number(90) }
            }
            if key == "startButton", object["drawer"]?.string == "image" {
                var params = object["drawerParams"]?.object ?? [:]
                var states = params["states"]?.object ?? [:]
                if !validAsset(states["normal"] ?? params["file"], root: imageAssetRoots[states["normal"] == nil ? "file" : "states.normal"] ?? assetRoot) {
                    warn(path + ["drawer"], "image unavailable or forbidden; using family default")
                    object["drawer"] = defaults["startButton"]?["drawer"]
                    object["drawerParams"] = defaults["startButton"]?["drawerParams"]
                } else {
                    for state in ["hover", "pressed"] {
                        if let file = states[state], !validAsset(file, root: imageAssetRoots["states." + state] ?? assetRoot) {
                            warn(path + ["drawerParams", "states", state], "image unavailable or forbidden; using normal image")
                            states.removeValue(forKey: state)
                        }
                    }
                    params["states"] = .object(states)
                    object["drawerParams"] = .object(params)
                }
            }
            let allowed = allowedKeys(path, value: .object(object))
            for field in object.keys.sorted() {
                if field.hasPrefix("_") { object.removeValue(forKey: field); continue }
                if !allowed.contains(field) {
                    warn(path + [field], "unknown field ignored")
                    object.removeValue(forKey: field)
                } else if let child = object[field] {
                    object[field] = try sanitize(child, path: path + [field], defaults: defaults, root: root, assetRoot: assetRoot)
                }
            }
            return .object(object)
        }
        if case .array(let values) = value {
            return .array(try values.enumerated().map { try sanitize($0.element, path: path + [String($0.offset)], defaults: defaults, root: root, assetRoot: assetRoot) })
        }
        return value
    }

    private func validAsset(_ value: ThemeJSON?, root: URL?) -> Bool {
        ThemeImageAsset.load(value, root: root) != nil
    }

    /// The two complete examples supply the detailed numeric geometry vocabulary.
    /// Supplemental keys cover the other material types and prose-only structures.
    private func allowedKeys(_ path: [String], value: ThemeJSON) -> Set<String> {
        let normalized = path.map { Int($0) == nil ? $0 : "*" }
        let key = normalized.joined(separator: ".")
        // Start drawer names and state files have a fixed vocabulary.
        // Nested artwork and other strategy parameter objects remain extensible.
        if key == "startButton.drawerParams" {
            return Self.drawerParameterKeys
        }
        if key == "startButton.drawerParams.states" { return Self.stateParameterKeys }
        if path.contains("params") || path.contains("drawerParams") ||
            path.starts(with: ["layout", "vertical"]) || path.starts(with: ["layout", "fixedItemParams"]) ||
            key == "fonts" {
            return Set(value.object?.keys.map { $0 } ?? [])
        }
        if key == "palette" || key == "fonts" || key == "buttons.bevels" || key == "tray.vertical.rows" {
            return Set(value.object?.keys.map { $0 } ?? [])
        }
        var keys = Self.allowedKeysCache.value(for: key) { [self] in
            var baselineKeys: Set<String> = []
            func collect(_ node: ThemeJSON, _ remaining: ArraySlice<String>) {
                guard let first = remaining.first else {
                    baselineKeys.formUnion(node.object?.keys.map { $0 } ?? [])
                    return
                }
                if first == "*", case .array(let items) = node {
                    for item in items { collect(item, remaining.dropFirst()) }
                } else if let child = node[first] { collect(child, remaining.dropFirst()) }
            }
            for id in ["win95", "win11"] {
                if let baseline = try? builtin(id, compiledOnly: true) { collect(baseline, normalized[...]) }
            }
            return baselineKeys
        }
        let last = path.last ?? ""
        if path.isEmpty { keys.insert("extends") }
        if key == "bar" { keys.insert("edgeColor") }
        if key == "bar.material" { keys.insert("taskbarFill") }
        if key == "startMenu" { keys.formUnion(["colors", "banner"]) }
        if key == "startMenu.colors" { keys.formUnion(["face", "text", "highlight"]) }
        if key == "startMenu.banner" { keys.formUnion(["fill", "text", "suffix"]) }
        if key == "buttons.task" { keys.formUnion(["normalFill", "activeFill", "borderColor", "textColor"]) }
        if key == "startButton" { keys.formUnion(["fill", "textColor"]) }
        if key == "layout" { keys.formUnion(["fixedItemParams", "linear", "aero", "compact"]) }
        if key == "layout.linear" { keys.formUnion(["taskWidth", "rounding", "subtractGaps", "quickPlacement", "trayWidth", "buttonCross", "startCross", "startX", "startY", "startHeight", "startHeightInset", "startAdvanceGap", "taskY", "taskHeight", "taskHeightInset", "iconWidth", "pinnedIconWidth", "labelGap", "quickSeparator", "taskSeparator", "trayY", "trayHeight", "trayHeightInset", "trayTrailing", "trayGap", "hideGap", "availableTrailing", "edgeMin", "groupTrayGap", "leading", "quickTrailing"]) }
        if key == "layout.aero" { keys.formUnion(["taskHeight", "verticalTaskHeight", "orbSize", "orbX", "orbY", "orbAnchor", "orbVerticalY", "orbWidthInset", "contentLeading", "trayVerticalReserve", "afterOrbGap", "quickSize", "quickPitch", "quickHideGap", "quickSeparatorGap", "quickSeparatorGapVertical", "taskWidthInset", "iconWidth", "limitPinnedWidth", "combinedWidth", "labelledWidth", "minWidth", "fitGap", "taskGap", "taskGapVertical"]) }
        if key == "layout.compact" { keys.formUnion(["size", "smallSize", "taskWidth", "startGap", "trayReserve", "hideGap", "gap"]) }
        if key == "layout.grouping" { keys.insert("reservedSpaceVertical") }
        if key == "metrics" { keys.formUnion(["params", "verticalBarWidthWhenCombined", "buttonSize", "buttonHeight", "contentInset", "startToContentGap", "quickLaunch", "separator"]) }
        if key == "metrics.taskButton" { keys.formUnion(["minWidth", "maxWidth", "iconSize", "labelled"]) }
        if key == "metrics.separator" { keys.formUnion(["style", "advance", "unlockedStyle"]) }
        if key == "previews" { keys.insert("params") }
        if key == "previews.params" { keys.formUnion(["cornerRadius", "fill", "color", "fillAlpha"]) }
        if key == "startButton" { keys.insert("previewWallpaper") }
        if key == "startButton.overflow" { keys.formUnion(["outer", "panelMargin", "enabled", "panelWidth", "panelHeight", "panelInset", "previewExtraHeight", "menuPadding"]) }
        if (path.first == "fonts" && path.count == 2) || ["font", "boldFont", "measureFont", "centeredFont"].contains(last) {
            keys.formUnion(["ref", "family", "size", "fallback", "weight"])
        }
        if ["material", "fill"].contains(last), value["type"] != nil {
            keys.formUnion(Self.materialParameterKeys)
        }
        if last == "snapshotFallback" { keys.formUnion(["light", "dark"]) }
        if ["normal", "normalLabelled", "hover", "pressed", "active", "open"].contains(last) {
            keys.formUnion(Self.stateStyleKeys)
        }
        if last == "border" || last == "leadingSeparator" || path.contains("leadingSeparator") { keys.formUnion(["color", "width"]) }
        if path.contains("bevels") { keys.formUnion(["topLeft", "bottomRight"]) }
        if key == "buttons" { keys.formUnion(["pinned", "plain"]) }
        if key == "buttons" { keys.insert("desktopStrip") }
        if key == "buttons.quickLaunch" { keys.insert("tintTemplateSymbols") }
        if key == "buttons.desktopStrip" { keys.formUnion(["normalAlpha", "hoverAlpha", "lowerAlpha", "edgeAlpha"]) }
        if key == "buttons.task.fillRule" { keys.formUnion(["activeTriggers", "normalWhen", "normalState"]) }
        if key == "buttons.task.icon" {
            keys.formUnion(["iconOnly", "smallIconUsesPlain", "clampInset", "centerWhenTitled",
                            "symbolSource", "symbolColor", "symbolSize", "symbolLabelledX"])
        }
        if key == "buttons.task.runningIndicator" { keys.formUnion(["height", "bottomInset", "radius"]) }
        if ["task", "quickLaunch", "pinned", "plain"].contains(last), path.first == "buttons" {
            keys.formUnion(["normal", "hover", "pressed", "active", "normalLabelled", "inherit", "size", "iconSize", "paintNormalWhen", "runningIndicator", "title", "iconOffsetY", "iconOffsetYLabelled", "iconLeadingLabelled"])
        }
        if key == "tray" { keys.formUnion(["smoothing", "minWidth", "widthClamp", "actionCenter", "vertical", "win8", "textColor", "appIcon"]) }
        if key == "tray.container" { keys.formUnion(["leadingBorder", "leadingSeparator", "leadingLines"]) }
        if key == "tray.container.leadingLines.*" { keys.formUnion(["x", "y", "width", "insetY", "color", "alpha"]) }
        if key == "tray.vertical" {
            keys.formUnion(["supported", "trigger", "threshold", "base", "trailing", "contentBase", "rows", "dropOrder",
                            "stacked", "buttonRows", "minRow", "rowCount", "actionRow", "desktopReserve"])
        }
        if key == "tray.vertical.rows.*" { keys.formUnion(["name", "height", "always", "preferred"]) }
        if key == "tray.actionCenter" {
            keys.formUnion(["style", "width", "advance", "drawAdvance", "rightReserve", "symbol", "toggles",
                            "offsetsBounds", "offsetsBoundsVertical", "color", "frame", "frameVertical"])
        }
        if key == "tray.chevron" {
            keys.formUnion(["width", "drawAdvance", "drawsText", "paintWhenHidden", "titleCollapsed", "titleExpanded",
                            "symbolCollapsed", "symbolExpanded", "font", "fontVertical", "color", "frameVertical", "drawRect"])
        }
        if key == "tray.inputLanguage" {
            keys.formUnion(["fixedText", "fixedTextHorizontal", "fixedTextVertical", "maxChars", "width", "drawAdvance", "ignoresCollapse",
                            "fontVertical", "rect", "rectVertical"])
        }
        if key == "tray.appIcon" {
            keys.formUnion(["width", "advance", "drawAdvance", "verticalAdvance", "iconSize", "gap", "fill", "bevel", "rect", "rectVertical"])
        }
        if key == "tray.clock" {
            keys.formUnion(["measure", "measureFont", "measureDateFont", "measureFallback", "ceil", "minWidth", "extraWidth",
                            "rect", "rectVertical", "verticalHalves"])
        }
        if key == "tray.showDesktop" { keys.formUnion(["width", "frameVertical", "line", "lineVertical"]) }
        if key == "tray.clock.lines.*" { keys.formUnion(["offsetY", "height", "font", "fontVertical", "halves", "fullHeight"]) }
        if key == "tray.win8" {
            keys.formUnion(["leading", "horizontalInset", "verticalInset", "trailing", "inputWidth", "inputHeight",
                            "actionWidth", "actionHeight", "clockHeight", "clockVerticalHeight", "desktop"])
        }
        if path.first == "tray", ["frame", "frameVertical", "drawRect", "rect", "rectVertical", "line", "lineVertical"].contains(last) {
            keys.formUnion(["x", "y", "width", "height", "insetX", "insetY", "minWidth", "minHeight", "xPlacement", "yPlacement",
                            "widthMode", "heightMode", "floorY", "centerUsesMidY", "clampWidth", "clampHeight", "widthWhenVisible", "heightWhenVisible",
                            "color", "alpha"])
        }
        if path.first == "tray", ["fontVertical", "measureDateFont"].contains(last) {
            keys.formUnion(["family", "size", "weight", "fallback", "ref"])
        }
        if key == "buttons.task.title" { keys.insert("boldWhenActive") }
        if key == "buttons.task.runningIndicator.running" || key == "buttons.task.runningIndicator.active" {
            keys.formUnion(["width", "color", "fullWidth", "inset"])
        }
        if path.contains("stops"), Int(last) != nil { keys.formUnion(["color", "location"]) }
        return keys
    }

    private func resolveInheritance(_ root: ThemeJSON) throws -> ThemeJSON {
        func visit(_ value: ThemeJSON, path: [String], stack: Set<String>) throws -> ThemeJSON {
            let identity = path.joined(separator: ".")
            guard !stack.contains(identity) else { throw ThemeLoadError(path: jsonPath(path), description: "state inheritance cycle") }
            if var object = value.object {
                if let inherit = object["inherit"] {
                    guard let ref = inherit.string else { throw ThemeLoadError(path: jsonPath(path + ["inherit"]), description: "expected state reference") }
                    let target = ref.contains(".") ? ref.split(separator: ".").map(String.init) : Array(path.dropLast()) + [ref]
                    guard let base = root.at(target) else { throw ThemeLoadError(path: jsonPath(path), description: "unknown state reference \(ref)") }
                    object.removeValue(forKey: "inherit")
                    let resolved = try visit(base, path: target, stack: stack.union([identity]))
                    // A StateStyle reference is an alternative to an inline style. Do
                    // not let lower-layer inline defaults override the referenced state.
                    object = (isStatePath(path) ? resolved : ThemeJSON.merge(resolved, .object(object))).object ?? object
                }
                for field in object.keys.sorted() {
                    guard let fieldValue = object[field] else { continue }
                    object[field] = try visit(fieldValue, path: path + [field], stack: stack.union([identity]))
                }
                return .object(object)
            }
            if case .array(let items) = value {
                return .array(try items.enumerated().map { try visit($0.element, path: path + [String($0.offset)], stack: stack.union([identity])) })
            }
            return value
        }
        return try visit(root, path: [], stack: [])
    }

    private func resolve(_ json: ThemeJSON, assetRoot: URL? = nil, imageAssetRoots: [String: URL] = [:]) throws -> ResolvedTheme {
        let encoder = JSONEncoder()
        let config = try decodeOnLargeStack(ThemeConfig.self, from: encoder.encode(json))
        var colors: [String: ThemeColor] = [:]
        var fonts: [String: ThemeFontDescriptor] = [:]
        var materials: [String: ThemeMaterial] = [:]
        var states: [String: ThemeStateStyle] = [:]
        func visit(_ value: ThemeJSON, _ path: [String]) throws {
            let key = path.joined(separator: ".")
            if value == .null, path.first == "tray" { return }
            if isStatePath(path) {
                states[key] = try decodeValue(ThemeStateStyle.self, value: value, path: path)
            }
            if isColor(value, path: path) {
                colors[key] = try ThemeColor.parse(value, palette: config.palette)
                return
            }
            if let object = value.object {
                if path.first == "fonts", path.count == 2, path.last != "smoothing" {
                    fonts[key] = try decodeValue(ThemeFontDescriptor.self, value: value, path: path)
                }
                if let ref = object["ref"]?.string {
                    guard let source = json["fonts"]?[ref] else { throw ThemeLoadError(path: jsonPath(path), description: "unknown font \(ref)") }
                    fonts[key] = try decodeValue(ThemeFontDescriptor.self, value: source, path: path)
                } else if ["font", "boldFont", "measureFont", "measureDateFont", "fontVertical", "centeredFont"].contains(path.last ?? "") {
                    fonts[key] = try decodeValue(ThemeFontDescriptor.self, value: value, path: path)
                }
                if object["type"] != nil, ["fill", "material"].contains(path.last ?? "") {
                    materials[key] = try decodeValue(ThemeMaterial.self, value: value, path: path)
                }
                if let bevel = object["bevel"]?.string, json["buttons"]?["bevels"]?[bevel] == nil {
                    throw ThemeLoadError(path: jsonPath(path + ["bevel"]), description: "unknown bevel \(bevel)")
                }
                for field in object.keys.sorted() {
                    guard let fieldValue = object[field] else { continue }
                    try visit(fieldValue, path + [field])
                }
            } else if case .array(let items) = value {
                for (index, item) in items.enumerated() { try visit(item, path + [String(index)]) }
            }
        }
        try visit(json, [])
        var bevels: [String: [ResolvedThemeBevelLayer]] = [:]
        for (name, value) in json["buttons"]?["bevels"]?.object ?? [:] {
            let layers = try decodeValue([ThemeBevelLayer].self, value: value, path: ["buttons", "bevels", name])
            bevels[name] = try layers.map {
                ResolvedThemeBevelLayer(topLeft: try ThemeColor.parse($0.topLeft, palette: config.palette),
                                       bottomRight: try ThemeColor.parse($0.bottomRight, palette: config.palette))
            }
        }
        return ResolvedTheme(assetRoot: assetRoot, imageAssetRoots: imageAssetRoots, config: config, json: json, colors: colors, fonts: fonts, materials: materials, states: states, bevels: bevels)
    }

    private func decodeValue<T: Decodable>(_ type: T.Type, value: ThemeJSON, path: [String]) throws -> T {
        do { return try decodeOnLargeStack(type, from: JSONEncoder().encode(value)) }
        catch let error as DecodingError {
            let suffix: [String]
            switch error {
            case .keyNotFound(let key, let context):
                suffix = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue } + [key.stringValue]
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                suffix = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            @unknown default: suffix = []
            }
            throw ThemeLoadError(path: jsonPath(path + suffix), description: "\(error)")
        }
    }

    private func isStatePath(_ path: [String]) -> Bool {
        if path == ["tray", "hover"] { return true }
        guard path.count == 3, ["normal", "normalLabelled", "hover", "pressed", "active", "open"].contains(path[2]) else { return false }
        return (path[0] == "buttons" && ["task", "quickLaunch", "pinned", "plain"].contains(path[1])) ||
            path[0...1] == ["startButton", "states"]
    }

    private func log() {
        guard !diagnostics.isEmpty else { return }
        let text = diagnostics.map(\.description).joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: "/tmp/winstripe-theme.log")
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)) } catch {}
    }
}

private final class BuiltinThemeJSONCache {
    private let lock = NSLock()
    private var values: [String: ThemeJSON] = [:]

    func value(for key: String, loader: () throws -> ThemeJSON) rethrows -> ThemeJSON {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = try loader()
        values[key] = value
        return value
    }

    func removeAll() {
        lock.lock()
        values.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

private final class BuiltinAllowedKeysCache {
    private let lock = NSLock()
    private var values: [String: Set<String>] = [:]

    func value(for key: String, loader: () -> Set<String>) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = loader()
        values[key] = value
        return value
    }

    func removeAll() {
        lock.lock()
        values.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

private extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double { min(max(self, lower), upper) }
}

private struct DuplicateJSONScanner {
    /// Every theme document passes this scanner before it is decoded, so this bound also caps the
    /// recursion depth of ThemeJSON decoding, merging and lookup.
    static let maxDepth = 64
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(data: Data) { bytes = Array(data) + [0] }

    mutating func scan() throws {
        try value()
        skipSpace()
        guard bytes[index] == 0 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
    }

    mutating private func value() throws {
        skipSpace()
        if bytes[index] == 123 || bytes[index] == 91 {
            guard depth < Self.maxDepth else {
                throw ThemeLoadError(path: "$", description: "JSON nested deeper than \(Self.maxDepth) levels")
            }
            depth += 1
            defer { depth -= 1 }
            if bytes[index] == 123 { try object() } else { try array() }
            return
        }
        switch bytes[index] {
        case 123: try object()
        case 91: try array()
        case 34: _ = try string()
        case 45, 48...57: number()
        case 116: literal("true")
        case 102: literal("false")
        case 110: literal("null")
        default: throw ThemeLoadError(path: "$", description: "invalid JSON")
        }
    }

    mutating private func object() throws {
        index += 1; skipSpace()
        var keys = Set<String>()
        if bytes[index] == 125 { index += 1; return }
        while true {
            guard bytes[index] == 34 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
            let key = try string()
            if !keys.insert(key).inserted {
                throw ThemeLoadError(path: "$", description: "duplicate key \(key)")
            }
            skipSpace()
            guard bytes[index] == 58 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
            index += 1
            try value()
            skipSpace()
            if bytes[index] == 125 { index += 1; return }
            guard bytes[index] == 44 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
            index += 1; skipSpace()
        }
    }

    mutating private func array() throws {
        index += 1; skipSpace()
        if bytes[index] == 93 { index += 1; return }
        while true {
            try value(); skipSpace()
            if bytes[index] == 93 { index += 1; return }
            guard bytes[index] == 44 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
            index += 1; skipSpace()
        }
    }

    mutating private func string() throws -> String {
        guard bytes[index] == 34 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
        index += 1
        var result = ""
        while bytes[index] != 34 {
            guard bytes[index] != 0 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
            if bytes[index] == 92 {
                index += 1
                guard bytes[index] != 0 else { throw ThemeLoadError(path: "$", description: "invalid JSON") }
                result.append(Character(UnicodeScalar(bytes[index])))
            } else {
                result.append(Character(UnicodeScalar(bytes[index])))
            }
            index += 1
        }
        index += 1
        return result
    }

    mutating private func number() {
        while bytes[index] == 45 || bytes[index] == 43 || bytes[index] == 46 ||
                (bytes[index] >= 48 && bytes[index] <= 57) ||
                bytes[index] == 69 || bytes[index] == 101 { index += 1 }
    }

    mutating private func literal(_ text: String) {
        index += text.utf8.count
    }

    mutating private func skipSpace() {
        while bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 32 { index += 1 }
    }
}

enum ThemeCLI {
    static func run(arguments: [String]) -> Int32? {
        if arguments.contains("--bench-theme-load") {
            return benchThemeLoad()
        }
        if let index = arguments.firstIndex(of: "--import-theme") {
            guard index + 1 < arguments.count else { emit("error: --import-theme requires a path"); return 1 }
            guard ThemePaths.allowsOffscreenWrites else {
                emit("error: --import-theme requires a non-default --user-themes-dir")
                return 1
            }
            do {
                let record = try ThemeImportExport.importTheme(URL(fileURLWithPath: arguments[index + 1]), allowCopy: true)
                print("IMPORTED \(record.id)")
                return 0
            } catch { emit("error: \(error)"); return 1 }
        }
        if let index = arguments.firstIndex(of: "--export-theme") {
            guard index + 2 < arguments.count else { emit("error: --export-theme requires an id and output path"); return 1 }
            let output = URL(fileURLWithPath: arguments[index + 2])
            guard !ThemePaths.isDefaultUserThemesPath(output) else {
                emit("error: --export-theme output must not be inside the default user themes directory")
                return 1
            }
            do {
                try ThemeImportExport.exportTheme(id: arguments[index + 1], to: output)
                print("EXPORTED \(arguments[index + 1])")
                return 0
            } catch { emit("error: \(error)"); return 1 }
        }
        if let index = arguments.firstIndex(of: "--hot-reload-test") {
            guard index + 1 < arguments.count else { emit("error: --hot-reload-test requires a directory"); return 1 }
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            guard !ThemePaths.isDefaultUserThemesPath(directory) else {
                emit("error: --hot-reload-test directory must not be the default user themes directory")
                return 1
            }
            return hotReloadTest(directory)
        }
        guard let index = arguments.firstIndex(where: { $0 == "--validate-theme" || $0 == "--dump-theme" }) else { return nil }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            emit("error: $: \(arguments[index]) requires a theme id or path")
            return 1
        }
        let source = arguments[index + 1]
        let dump = arguments[index] == "--dump-theme"
        let all = !dump && source == "builtin"
        let sources = all ? BuiltinThemes.json.keys.sorted() : [source]
        var failed = false
        let (_, userErrors) = UserThemeCatalog.records()
        for error in userErrors { emit("error: user themes: \(error)"); failed = true }
        for item in sources {
            let id = ThemeLoader.canonicalID(item)
            let builtin = BuiltinThemes.json[id] != nil
            let isPath = FileManager.default.fileExists(atPath: item)
            let userRecord = UserThemeCatalog.record(id: id)
            if dump && !builtin && !isPath && userRecord == nil {
                emit("error: $.id: unknown theme \(item)")
                return 1
            }
            let result: ThemeLoadResult
            if !builtin && !isPath, let userRecord {
                result = ThemeLoader().load(userRecord.url.path, user: true)
            } else {
                result = ThemeLoader().load(builtin ? id : item, user: !builtin)
            }
            for diagnostic in result.diagnostics { emit(diagnostic.description) }
            failed = failed || !result.succeeded || ((all || arguments.contains("--strict")) && !result.diagnostics.isEmpty)
            if dump {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                do { print(String(decoding: try encoder.encode(result.theme.json), as: UTF8.self)) }
                catch { emit("error: $: \(error)"); failed = true }
            } else if result.succeeded { print("OK \(result.theme.config.id)") }
        }
        return failed ? 1 : 0
    }

    private static func emit(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func benchThemeLoad() -> Int32 {
        var failed = false
        for kind in ThemeKind.allCases {
            ThemeResolutionCache.shared.clearForBenchmark()
            ThemeLoader.clearBuiltinJSONCacheForBenchmark()
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try ThemeResolutionCache.shared.loadSync(kind.id)
            } catch {
                failed = true
                emit("FAIL theme-load \(kind.id): \(error)")
                continue
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("theme-load \(kind.id) cold_ms=\(String(format: "%.3f", elapsed))")
        }
        if !failed { print("PASS bench-theme-load") }
        return failed ? 1 : 0
    }

    private static func hotReloadTest(_ directory: URL) -> Int32 {
        let (records, _) = UserThemeCatalog.records(directory: directory)
        guard let record = records.first else { emit("error: no user theme in directory"); return 1 }
        let source = record.isFolder ? record.url.appendingPathComponent("theme.json") : record.url
        func load() -> ThemeLoadResult? {
            if let current = try? ThemeLoader().loadForID(record.id, userDirectory: directory) { return current }
            return ThemeLoader().load(source.path, user: true)
        }
        var last = load()
        print("resolved=\(last?.theme.config.bar.material.type ?? "solid")")
        if let data = try? Data(contentsOf: source), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["bar"] = ["material": ["type": "gradient", "stops": [["color": "#008080"], ["color": "#004040"]]]]
            try? JSONSerialization.data(withJSONObject: object).write(to: source)
            if let current = load(), current.succeeded { last = current; print("reloaded=\(current.theme.config.bar.material.type)") }
            try? Data("{".utf8).write(to: source)
            if let broken = load(), !broken.succeeded { print("warning=\(broken.diagnostics.map(\.description).joined(separator: " | "))") }
        }
        return 0
    }
}
