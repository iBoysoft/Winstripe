import Foundation

indirect enum ThemeJSON: Codable, Equatable, Sendable {
    case object([String: ThemeJSON]), array([ThemeJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: ThemeJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([ThemeJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var object: [String: ThemeJSON]? { if case .object(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    subscript(_ key: String) -> ThemeJSON? { object?[key] }

    static func merge(_ base: ThemeJSON, _ child: ThemeJSON) -> ThemeJSON {
        guard var a = base.object, let b = child.object else { return child }
        for (key, value) in b { a[key] = a[key].map { merge($0, value) } ?? value }
        return .object(a)
    }

    func at(_ path: [String]) -> ThemeJSON? {
        guard let first = path.first else { return self }
        return self[first]?.at(Array(path.dropFirst()))
    }

    func strippingComments() -> ThemeJSON {
        switch self {
        case .object(let v): return .object(v.filter { !$0.key.hasPrefix("_") }.mapValues { $0.strippingComments() })
        case .array(let v): return .array(v.map { $0.strippingComments() })
        default: return self
        }
    }
}

enum ThemeFamily: String, Codable, Sendable { case classic, modern }

final class ThemeConfig: Codable, Sendable {
    let schema: String
    let id: String
    let name: [String: String]
    let version: Int
    let extends: String?
    let family: ThemeFamily
    let metrics: ThemeMetrics
    let palette: [String: ThemeJSON]
    let bar: ThemeBar
    let buttons: ThemeButtons
    let layout: ThemeLayout
    let tray: ThemeTray
    let fonts: [String: ThemeJSON]
    let startButton: ThemeStartButton
    let startMenu: ThemeStartMenu
    let previews: ThemePreviews

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case id, name, version, extends, family, metrics, palette, bar, buttons, layout, tray, fonts, startButton, startMenu, previews
    }
}

final class ThemeMetrics: Codable, Sendable {
    let params: [String: ThemeJSON]?
    let barThickness: Double
    let verticalBarWidth: Double
    let buttonGap: Double
    let buttonHeight: Double?
    let buttonSize: Double?
    let cornerRadius: Double
    let verticalBarWidthWhenCombined: Double?
    let contentInset: ThemeInsets?
    let startToContentGap: Double?
    let taskButton: ThemeTaskButtonMetrics
    let quickLaunch: ThemeQuickLaunchMetrics?
    let separator: ThemeSeparatorMetrics?
    let trayInset: ThemeTrayInset?
    let groupInsets: ThemeGroupInsets?
    let trayReserve: Double?
}

struct ThemeInsets: Codable, Sendable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double
}

final class ThemeTaskButtonMetrics: Codable, Sendable {
    let minWidth: Double?
    let maxWidth: Double?
    let iconSize: Double
    let iconSizeLabelled: Double?
    let iconSizePlain: Double?
    let iconInset: Double?
    let iconTextGap: Double?
    let textTrailingInset: Double?
    let labelled: ThemeLabelledMetrics?
}

final class ThemeLabelledMetrics: Codable, Sendable {
    let minWidth: Double
    let maxWidth: Double
    let measureFont: ThemeJSON
    let padding: ThemeLabelledPadding
    let titleTrailingInset: Double?
    let shrinkMin: Double
}

struct ThemeLabelledPadding: Codable, Sendable {
    let leading: Double
    let iconGap: Double
    let trailing: Double
}

struct ThemeQuickLaunchMetrics: Codable, Sendable {
    let buttonSize: Double
    let pitch: Double
    let iconSize: Double
    let trailingGap: Double?
}

struct ThemeSeparatorMetrics: Codable, Sendable {
    let style: String
    let advance: Double
    let unlockedStyle: String?
    let insetY: Double?
    let showTaskSeparatorWhen: String?
}

struct ThemeTrayInset: Codable, Sendable {
    let trailing: Double
    let gapBeforeTray: Double
    let hideTaskIfWithin: Double
}

struct ThemeGroupInsets: Codable, Sendable {
    let leading: Double
    let edgeMin: Double
    let trayGap: Double
    let availableTrailing: Double
}

final class ThemeBar: Codable, Sendable {
    let material: ThemeMaterial
    let edge: [String: [ThemeBorder]]
    let edgeColor: ThemeJSON?
}

final class ThemeMaterial: Codable, Sendable {
    let params: [String: ThemeJSON]?
    let type: String
    let color: ThemeJSON?
    let alpha: Double?
    let stops: [ThemeJSON]?
    let angle: Double?
    let pattern: String?
    let colors: [ThemeJSON]?
    let inset: Double?
    let appearance: String?
    let nsMaterial: String?
    let snapshotFallback: ThemeJSON?
    let variant: String?
    let tint: ThemeJSON?
    let hotTrack: String?
    let file: String?
    let slice: [Double]?
    let taskbarFill: [ThemeJSON]?
}

struct ThemeBorder: Codable, Sendable {
    let color: ThemeJSON
    let width: Double
}

final class ThemeStateStyle: Codable, Sendable {
    let fill: ThemeMaterial
    let bevel: String?
    let border: ThemeBorder?
    let radius: Double?
    let inset: Double?
    let contentOffset: [Double]?
    let boldTitle: Bool?
    let iconOffsetY: Double?
    let when: String?
    let rect: [String: ThemeJSON]?
}

final class ThemeButtons: Codable, Sendable {
    let task: ThemeButtonStyle
    let quickLaunch: ThemeButtonStyle
    let pinned: ThemeButtonStyle?
    let plain: ThemeButtonStyle?
    let bevels: [String: [ThemeBevelLayer]]?
    let badge: ThemeBadge
}

final class ThemeButtonStyle: Codable, Sendable {
    let normal: ThemeStateStyle
    let normalLabelled: ThemeStateStyle?
    let hover: ThemeStateStyle?
    let pressed: ThemeStateStyle?
    let active: ThemeStateStyle?
    let open: ThemeStateStyle?
    let iconSize: Double?
    let size: Double?
    let paintNormalWhen: String?
    let iconOffsetY: Double?
    let iconOffsetYLabelled: Double?
    let iconLeadingLabelled: Double?
    let runningIndicator: ThemeIndicator?
    let title: ThemeTitle?
    let normalFill: [ThemeJSON]?
    let activeFill: [ThemeJSON]?
    let borderColor: ThemeJSON?
    let textColor: ThemeJSON?
}

final class ThemeIndicator: Codable, Sendable {
    let type: String
    let position: String?
    let bottomInset: Double?
    let height: Double?
    let radius: Double?
    let running: ThemeIndicatorState?
    let active: ThemeIndicatorState?
    let pinnedNotRunning: ThemeJSON?
}

struct ThemeIndicatorState: Codable, Sendable {
    let width: Double?
    let color: ThemeJSON
    let fullWidth: Bool?
    let inset: Double?
}

final class ThemeTitle: Codable, Sendable {
    let font: ThemeJSON
    let boldFont: ThemeJSON?
    let color: ThemeJSON
    let alignment: String
    let boldWhenActive: Bool?
    let iconGap: Double?
    let trailingInset: Double?
}

struct ThemeBadge: Codable, Sendable {
    let shape: String
    let size: [Double]?
    let height: Double?
    let minWidth: Double?
    let textPadding: Double?
    let radius: Double?
    let anchor: ThemeJSON
    let offset: [Double]?
    let fill: ThemeJSON
    let font: ThemeJSON
    let textColor: ThemeJSON
    let showsText: Bool
}

struct ThemeBevelLayer: Codable, Sendable {
    let topLeft: ThemeJSON
    let bottomRight: ThemeJSON
}

struct ResolvedThemeBevelLayer: Sendable {
    let topLeft: ThemeColor
    let bottomRight: ThemeColor
}

final class ThemeLayout: Codable, Sendable {
    let linear: [String: ThemeJSON]?
    let aero: [String: ThemeJSON]?
    let compact: [String: ThemeJSON]?
    let fixedItemParams: [String: ThemeJSON]?
    let engine: String
    let pins: String
    let labelMode: String
    let groupingDefault: String
    let overflow: String
    let fixedItems: [String]
    let vertical: [String: ThemeJSON]
    let alignment: String
    let alignmentOptions: [String]
    let grouping: ThemeGroupingMetrics
    let classicOneButtonPerAppWidth: Bool?
    let startInGroup: Bool?
}

struct ThemeGroupingMetrics: Codable, Sendable {
    let fitMinWidth: Double
    let reservedSpaceVertical: Double?
    let reservedSpace: Double
}

final class ThemeTray: Codable, Sendable {
    let layout: String
    let container: ThemeTrayContainer
    let baseWidth: Double
    let items: [String]
    let clock: [String: ThemeJSON]
    let textColor: ThemeJSON?
    let minWidth: Double?
    let widthClamp: [Double]?
    let contentLeading: Double?
    let hover: ThemeStateStyle?
    let chevron: [String: ThemeJSON]?
    let inputLanguage: [String: ThemeJSON]?
    let appIcon: [String: ThemeJSON]?
    let actionCenter: [String: ThemeJSON]?
    let showDesktop: [String: ThemeJSON]?
    let vertical: [String: ThemeJSON]?
}

struct ThemeTrayContainer: Codable, Sendable {
    let fill: ThemeMaterial
    let bevel: String?
    let leadingBorder: ThemeJSON?
    let leadingSeparator: [ThemeBorder]?
}

final class ThemeStartButton: Codable, Sendable {
    let position: [String: Double]?
    let drawer: String
    let previewWallpaper: String?
    let drawerParams: [String: ThemeJSON]
    let label: ThemeJSON?
    let size: [String: ThemeJSON]
    let overflow: ThemeOverflow
    let states: [String: ThemeStateStyle]
    let fill: [ThemeJSON]?
    let textColor: ThemeJSON?
}

struct ThemeOverflow: Codable, Sendable {
    let outer: Double
    let panelMargin: Double?
    let enabled: Bool?
    let panelWidth: Double?
    let panelHeight: Double?
    let panelInset: Double?
    let previewExtraHeight: Double?
    let menuPadding: Double?
}

final class ThemeStartMenu: Codable, Sendable {
    let `default`: String
    let colors: ThemeStartMenuColors
    let banner: ThemeStartMenuBanner

    init(default: String, colors: ThemeStartMenuColors = ThemeStartMenuColors(face: .string("#C0C0C0"), text: .string("#000000"), highlight: .string("#000080")), banner: ThemeStartMenuBanner = ThemeStartMenuBanner(fill: [.string("#808080")], text: .string("#C0C0C0"), suffix: "95")) {
        self.default = `default`
        self.colors = colors
        self.banner = banner
    }
    var style: StartMenuStyle {
        switch `default` {
        case "classic95": return .win95
        case "classic98": return .win98
        case "classicME": return .winME
        case "classic2000": return .win2000
        default: return StartMenuStyle(rawValue: `default`) ?? .win95
        }
    }
}

struct ThemeStartMenuColors: Codable, Sendable {
    let face: ThemeJSON
    let text: ThemeJSON
    let highlight: ThemeJSON
}

struct ThemeStartMenuBanner: Codable, Sendable {
    let fill: [ThemeJSON]
    let text: ThemeJSON
    let suffix: String
}

final class ThemePreviews: Codable, Sendable {
    let style: String
    let params: [String: ThemeJSON]?
}

struct ThemeFontDescriptor: Codable, Sendable {
    let family: String
    let size: Double
    let fallback: String?
    let weight: String?
}

struct ResolvedTheme {
    let assetRoot: URL?
    let imageAssetRoots: [String: URL]
    let config: ThemeConfig
    let json: ThemeJSON
    let colors: [String: ThemeColor]
    let fonts: [String: ThemeFontDescriptor]
    let materials: [String: ThemeMaterial]
    let states: [String: ThemeStateStyle]
    let bevels: [String: [ResolvedThemeBevelLayer]]
}
