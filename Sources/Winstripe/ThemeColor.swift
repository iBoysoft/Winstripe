import AppKit

indirect enum ThemeColor: Sendable {
    case hex(UInt32, Double)
    case white(Double, Double)
    case system(String)
    case setting(String)
    case dynamic(light: ThemeColor, dark: ThemeColor)
    case alpha(ThemeColor, Double)

    static let systemNames: Set<String> = [
        "labelColor", "secondaryLabelColor", "tertiaryLabelColor", "quaternaryLabelColor", "quinaryLabelColor",
        "textColor", "textBackgroundColor", "selectedTextColor", "selectedTextBackgroundColor",
        "unemphasizedSelectedTextColor", "unemphasizedSelectedTextBackgroundColor",
        "controlColor", "controlBackgroundColor", "controlTextColor", "disabledControlTextColor",
        "selectedControlColor", "selectedControlTextColor", "alternateSelectedControlTextColor",
        "windowBackgroundColor", "windowFrameTextColor", "underPageBackgroundColor",
        "separatorColor", "gridColor", "keyboardFocusIndicatorColor", "controlAccentColor",
        "linkColor", "findHighlightColor", "highlightColor", "shadowColor", "placeholderTextColor",
        "selectedMenuItemTextColor", "headerTextColor", "selectedContentBackgroundColor",
        "unemphasizedSelectedContentBackgroundColor", "scrubberTexturedBackgroundColor", "textInsertionPointColor",
        "systemFillColor", "secondarySystemFillColor", "tertiarySystemFillColor",
        "quaternarySystemFillColor", "quinarySystemFillColor",
        "controlHighlightColor", "controlLightHighlightColor", "controlShadowColor", "controlDarkShadowColor",
        "scrollBarColor", "knobColor", "selectedKnobColor", "windowFrameColor", "selectedMenuItemColor",
        "headerColor", "secondarySelectedControlColor", "alternateSelectedControlColor",
        "systemRed", "systemGreen", "systemBlue", "systemOrange", "systemYellow", "systemBrown",
        "systemPink", "systemPurple", "systemGray", "systemTeal", "systemIndigo", "systemMint", "systemCyan",
        "black", "white", "gray", "darkGray", "lightGray", "clear", "red", "green", "blue",
        "cyan", "yellow", "magenta", "orange", "purple", "brown"
    ]

    private static func systemSelector(_ name: String) -> String? {
        let short = name.hasSuffix("Color") ? String(name.dropLast(5)) : name
        guard systemNames.contains(name) || systemNames.contains(short) else { return nil }
        let selector = name.hasSuffix("Color") ? name : name + "Color"
        return NSColor.responds(to: NSSelectorFromString(selector)) ? selector : nil
    }

    static func parse(_ value: ThemeJSON, palette: [String: ThemeJSON], visited: Set<String> = []) throws -> ThemeColor {
        if let object = value.object {
            let color: ThemeColor
            if let white = object["white"]?.number {
                guard (0...1).contains(white) else { throw ThemeColorError.invalid }
                color = .white(white, 1)
            } else if let light = object["light"], let dark = object["dark"] {
                color = .dynamic(light: try parse(light, palette: palette, visited: visited),
                                 dark: try parse(dark, palette: palette, visited: visited))
            } else if let wrapped = object["color"] {
                color = try parse(wrapped, palette: palette, visited: visited)
            } else { throw ThemeColorError.invalid }
            if let alpha = object["alpha"] {
                guard let n = alpha.number, (0...1).contains(n) else { throw ThemeColorError.invalid }
                return .alpha(color, n)
            }
            return color
        }
        guard let text = value.string else { throw ThemeColorError.invalid }
        if text.hasPrefix("@") {
            let key = String(text.dropFirst())
            guard !visited.contains(key), let source = palette[key] else { throw ThemeColorError.invalid }
            return try parse(source, palette: palette, visited: visited.union([key]))
        }
        if text.hasPrefix("system:") {
            let key = String(text.dropFirst(7))
            guard systemSelector(key) != nil else { throw ThemeColorError.invalid }
            return .system(key)
        }
        if text == "setting:win8StartColor" { return .setting("win8StartColor") }
        guard text.hasPrefix("#"), [7, 9].contains(text.count),
              text.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let hex = UInt32(text.dropFirst(), radix: 16) else { throw ThemeColorError.invalid }
        let rgb = text.count == 9 ? hex >> 8 : hex
        return .hex(rgb, text.count == 9 ? Double(hex & 255) / 255 : 1)
    }

    func resolve(settings: TaskbarSettings) -> NSColor {
        switch self {
        case .hex(let hex, let alpha):
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: CGFloat(alpha))
        case .white(let white, let alpha): return NSColor(white: CGFloat(white), alpha: CGFloat(alpha))
        case .system(let name):
            // Only validated, zero-argument NSColor class selectors reach this point.
            guard let selector = Self.systemSelector(name) else { return .labelColor }
            return NSColor.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? NSColor ?? .labelColor
        case .setting:
            let n = settings.win8StartColor
            return NSColor(srgbRed: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255,
                           blue: Double(n & 255) / 255, alpha: 1)
        case .alpha(let color, let alpha):
            if case .alpha(let inner, let previous) = color {
                return ThemeColor.alpha(inner, previous * alpha).resolve(settings: settings)
            }
            if case .dynamic(let light, let dark) = color {
                return ThemeColor.dynamic(light: .alpha(light, alpha), dark: .alpha(dark, alpha)).resolve(settings: settings)
            }
            if case .hex(let hex, let previous) = color {
                return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                               green: CGFloat((hex >> 8) & 255) / 255,
                               blue: CGFloat(hex & 255) / 255, alpha: CGFloat(previous * alpha))
            }
            if case .white(let white, let previous) = color { return NSColor(white: CGFloat(white), alpha: CGFloat(previous * alpha)) }
            let base = color.resolve(settings: settings)
            return base.withAlphaComponent(base.alphaComponent * alpha)
        case .dynamic(let light, let dark):
            let l = light.resolve(settings: settings), d = dark.resolve(settings: settings)
            return NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
            })
        }
    }
}

enum ThemeColorError: Error { case invalid }
