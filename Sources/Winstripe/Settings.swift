import AppKit

enum ThemeKind: String, CaseIterable, Identifiable {
    case win95 = "Windows 95"
    case win98 = "Windows 98"
    case winME = "Windows ME"
    case win2000 = "Windows 2000"
    case winXP = "Windows XP"
    case vista = "Windows Vista"
    case win7 = "Windows 7"
    case win8 = "Windows 8"
    case win10 = "Windows 10"
    case win11 = "Windows 11"
    var id: String {
        switch self {
        case .win95: return "win95"
        case .win98: return "win98"
        case .winME: return "winme"
        case .win2000: return "win2000"
        case .winXP: return "winxp"
        case .vista: return "vista"
        case .win7: return "win7"
        case .win8: return "win8"
        case .win10: return "win10"
        case .win11: return "win11"
        }
    }

    init?(themeID: String) {
        let canonical: String
        switch themeID {
        case "winXP": canonical = "winxp"
        case "winME": canonical = "winme"
        case "win2k": canonical = "win2000"
        default: canonical = themeID
        }
        guard let kind = Self.allCases.first(where: { $0.id == canonical }) else { return nil }
        self = kind
    }

    var defaultStartMenu: StartMenuStyle {
        switch self {
        case .win95: return .win95
        case .win98: return .win98
        case .winME: return .winME
        case .win2000: return .win2000
        case .winXP: return .xp
        case .vista: return .vista
        case .win7: return .win7
        case .win8: return .win8
        case .win10: return .win10
        case .win11: return .win11
        }
    }
}

enum StartMenuStyle: String, CaseIterable {
    case win95, win98, winME, win2000, xp, vista, win7, win8, win10, win11

    /// Read-time migration only; serialization always emits the canonical raw value.
    init?(rawValue: String) {
        switch rawValue {
        case "classicXP": self = .xp; return
        case "classicME": self = .winME; return
        case "classic2000": self = .win2000; return
        default: break
        }
        guard let style = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = style
    }

    var displayName: String {
        switch self {
        case .win95: return "Windows 95"
        case .win98: return "Windows 98"
        case .winME: return "Windows ME"
        case .win2000: return "Windows 2000"
        case .xp: return "Windows XP"
        case .vista: return "Windows Vista"
        case .win7: return "Windows 7"
        case .win8: return "Windows 8"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }

    var isAero: Bool { self == .vista || self == .win7 }
    var isFullScreen: Bool { self == .win8 }
    var supportsStartPins: Bool {
        [.xp, .win8, .win10, .win11].contains(self)
    }
    var classicThemeKind: ThemeKind? {
        switch self {
        case .win95: return .win95
        case .win98: return .win98
        case .winME: return .winME
        case .win2000: return .win2000
        default: return nil
        }
    }
}

enum TaskbarAlignment: String, CaseIterable, Identifiable {
    case center = "Center"
    case left = "Left"
    var id: String { rawValue }
}

enum TaskbarGrouping: String, CaseIterable, Identifiable {
    case alwaysCombine
    case combineWhenFull
    case neverCombine
    var id: String { rawValue }

    private static let themeDefaults: [ThemeKind: TaskbarGrouping] = Dictionary(firstWins: ThemeKind.allCases.map {
        ($0, TaskbarGrouping(rawValue: ThemeLoader().load($0.id).theme.config.layout.groupingDefault) ?? .neverCombine)
    })
    static func defaultFor(_ theme: ThemeKind) -> TaskbarGrouping {
        themeDefaults[theme] ?? .neverCombine
    }
}

enum TaskbarEdge: String, CaseIterable, Identifiable {
    case bottom, top, left, right
    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }
    var titleKey: String { rawValue.capitalized }
}

enum Language: String, CaseIterable, Identifiable {
    case system = "System"
    case english = "English"
    case chinese = "简体中文"
    case traditionalChinese = "繁體中文"
    case french = "Français"
    case spanish = "Español"
    case portuguese = "Português (Brasil)"
    case japanese = "日本語"
    case korean = "한국어"
    case german = "Deutsch"
    var id: String { rawValue }

    /// The lproj / AppleLanguages identifier for a concrete language.
    var localeIdentifier: String {
        switch self {
        case .system, .english: return "en"
        case .chinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .french: return "fr"
        case .spanish: return "es"
        case .portuguese: return "pt-BR"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .german: return "de"
        }
    }

    /// Shown in the picker in the language's own name; "System" is localized.
    var nativeName: String { rawValue }

    var resolvedLanguage: Language {
        guard self == .system else { return self }
        return Language.bestMatch(for: Locale.preferredLanguages)
    }

    /// Maps BCP 47 identifiers such as "zh-TW", "zh-Hant-HK", "pt-PT" or "de-CH" to the
    /// first supported language, in preference order; falls back to English.
    static func bestMatch(for preferred: [String]) -> Language {
        for identifier in preferred {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let code = parts.first else { continue }
            let rest = Set(parts.dropFirst())
            switch code {
            case "en": return .english
            case "zh":
                if rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo") {
                    return .traditionalChinese
                }
                return .chinese
            case "fr": return .french
            case "es": return .spanish
            case "pt": return .portuguese
            case "ja": return .japanese
            case "ko": return .korean
            case "de": return .german
            default: continue
            }
        }
        return .english
    }

    var displayNameKey: String { rawValue }
}

/// Every user-facing preference. A value type so the Properties dialog can edit a draft
/// copy while the model commits each edit immediately.
struct TaskbarSettings: Equatable {
    var language: Language = .system
    var resolvedLanguage: Language { language.resolvedLanguage }
    var theme: ThemeKind = .win95
    /// User theme ids are kept separately so the legacy ThemeKind APIs remain source compatible.
    var userThemeID: String?
    var activeThemeID: String { userThemeID ?? theme.id }
    /// nil follows the theme's default pairing; only an explicit choice is saved.
    var startMenuStyleChoice: StartMenuStyle?
    var startMenuStyle: StartMenuStyle { startMenuStyleChoice ?? theme.defaultStartMenu }
    var alignment: TaskbarAlignment = .center
    var edge: TaskbarEdge = .bottom
    var fontSmoothing = true
    var locked = true
    var autoHide = false
    var hideMenuBarInFullscreen = false
    var showBadges = true
    var showQuickLaunch = false
    var quickLaunchPath = ""
    var showWindowPreviews = false
    var showClock = true
    var showInputLanguage = false
    var showDesktopButton = false
    var collapseTrayIcons = false
    var trayApps: [String] = []
    var trayAppsAlwaysShow: [String] = []
    var allDisplays = false
    var debugLogging = false
    var win8StartColor: UInt32 = 0x2D004E
    /// The grouping the user explicitly picked in Properties; nil means "use the theme's default",
    /// so switching themes doesn't carry one theme's automatic default over to another.
    var taskbarGroupingChoice: TaskbarGrouping?
    var taskbarGrouping: TaskbarGrouping {
        get { taskbarGroupingChoice ?? TaskbarGrouping.defaultFor(theme) }
        set { taskbarGroupingChoice = newValue }
    }
}

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    static let didChange = Notification.Name("WinstripeSettingsDidChange")

    private let defaults = Prefs.defaults
    private(set) var current: TaskbarSettings

    private init() {
        current = SettingsStore.load(from: Prefs.defaults)
    }

    func update(_ new: TaskbarSettings) {
        guard !SnapshotFixture.isActive, new != current else { return }
        current = new
        save()
        NotificationCenter.default.post(name: SettingsStore.didChange, object: nil)
    }

    func mutate(_ change: (inout TaskbarSettings) -> Void) {
        var s = current
        change(&s)
        update(s)
    }

    static func load(from d: UserDefaults) -> TaskbarSettings {
        var s = TaskbarSettings()
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        if let v = d.string(forKey: "language"), let l = Language(rawValue: v) { s.language = l }
        if let v = d.string(forKey: "themeID") {
            if let t = ThemeKind(themeID: v) { s.theme = t }
            else if UserThemeCatalog.record(id: v) != nil {
                s.userThemeID = ThemeLoader.canonicalID(v)
                s.theme = UserThemeCatalog.familyKind(id: v)
            }
        } else if let v = d.string(forKey: "theme") {
            if v == "Windows Vista/7" { s.theme = .win7 }
            else if let t = ThemeKind(rawValue: v) { s.theme = t }
        }
        if let v = d.string(forKey: "startMenuStyle") {
            s.startMenuStyleChoice = StartMenuStyle(rawValue: v)
        }
        if let v = d.string(forKey: "alignment"), let a = TaskbarAlignment(rawValue: v) { s.alignment = a }
        if let v = d.string(forKey: "location"), let e = TaskbarEdge(rawValue: v) { s.edge = e }
        s.fontSmoothing = bool("fontSmoothing", s.fontSmoothing)
        s.locked = bool("locked", s.locked)
        s.autoHide = bool("autoHide", s.autoHide)
        s.hideMenuBarInFullscreen = bool("hideMenuBarInFullscreen", s.hideMenuBarInFullscreen)
        s.showBadges = bool("showBadges", s.showBadges)
        s.showQuickLaunch = bool("showQuickLaunch", s.showQuickLaunch)
        s.quickLaunchPath = d.string(forKey: "quickLaunchPath") ?? s.quickLaunchPath
        s.showWindowPreviews = bool("showWindowPreviews", s.showWindowPreviews)
        s.showClock = bool("showClock", s.showClock)
        s.showInputLanguage = bool("showInputLanguage", s.showInputLanguage)
        s.showDesktopButton = bool("showDesktopButton", s.showDesktopButton)
        s.collapseTrayIcons = bool("collapseTrayIcons", s.collapseTrayIcons)
        var seenTrayApps = Set<String>()
        s.trayApps = (d.stringArray(forKey: "trayApps") ?? []).compactMap {
            let path = URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
            return seenTrayApps.insert(path).inserted ? path : nil
        }
        var seenAlwaysShow = Set<String>()
        s.trayAppsAlwaysShow = (d.stringArray(forKey: "trayAppsAlwaysShow") ?? []).compactMap {
            let path = URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
            return seenAlwaysShow.insert(path).inserted ? path : nil
        }
        s.allDisplays = bool("allDisplays", s.allDisplays)
        s.debugLogging = bool("debugLogging", s.debugLogging)
        // Only an explicit choice is honoured. Builds before this fix saved the automatic
        // per-theme default under "taskbarGrouping" without the "taskbarGroupingCustom" flag;
        // those values are ignored so each theme gets its own default again.
        if d.bool(forKey: "taskbarGroupingCustom"),
           let v = d.string(forKey: "taskbarGrouping"), let grouping = TaskbarGrouping(rawValue: v) {
            s.taskbarGroupingChoice = grouping
        } else if s.theme == .win7, d.object(forKey: "win7CombineButtons") != nil, !bool("win7CombineButtons", true) {
            s.taskbarGroupingChoice = .neverCombine
        }
        if let v = d.object(forKey: "win8StartColor") as? NSNumber { s.win8StartColor = v.uint32Value }
        return s
    }

    private func save() {
        Self.save(current, to: defaults)
    }

    static func save(_ s: TaskbarSettings, to d: UserDefaults) {
        d.set(s.language.rawValue, forKey: "language")
        if d === UserDefaults.standard && !Prefs.isIsolated && !SnapshotFixture.isActive {
            if s.language == .system {
                d.removeObject(forKey: "AppleLanguages")
            } else {
                d.set([s.language.localeIdentifier], forKey: "AppleLanguages")
            }
        }
        d.set(s.activeThemeID, forKey: "themeID")
        if s.userThemeID == nil { d.set(s.theme.rawValue, forKey: "theme") }
        else { d.removeObject(forKey: "theme") }
        if let choice = s.startMenuStyleChoice {
            d.set(choice.rawValue, forKey: "startMenuStyle")
        } else {
            d.removeObject(forKey: "startMenuStyle")
        }
        d.set(s.alignment.rawValue, forKey: "alignment")
        d.set(s.edge.rawValue, forKey: "location")
        d.set(s.fontSmoothing, forKey: "fontSmoothing")
        d.set(s.locked, forKey: "locked")
        d.set(s.autoHide, forKey: "autoHide")
        d.set(s.hideMenuBarInFullscreen, forKey: "hideMenuBarInFullscreen")
        d.set(s.showBadges, forKey: "showBadges")
        d.set(s.showQuickLaunch, forKey: "showQuickLaunch")
        d.set(s.quickLaunchPath, forKey: "quickLaunchPath")
        d.set(s.showWindowPreviews, forKey: "showWindowPreviews")
        d.set(s.showClock, forKey: "showClock")
        d.set(s.showInputLanguage, forKey: "showInputLanguage")
        d.set(s.showDesktopButton, forKey: "showDesktopButton")
        d.set(s.collapseTrayIcons, forKey: "collapseTrayIcons")
        d.set(s.trayApps, forKey: "trayApps")
        d.set(s.trayAppsAlwaysShow, forKey: "trayAppsAlwaysShow")
        d.set(s.allDisplays, forKey: "allDisplays")
        d.set(s.debugLogging, forKey: "debugLogging")
        if let choice = s.taskbarGroupingChoice {
            d.set(choice.rawValue, forKey: "taskbarGrouping")
            d.set(true, forKey: "taskbarGroupingCustom")
        } else {
            d.removeObject(forKey: "taskbarGrouping")
            d.removeObject(forKey: "taskbarGroupingCustom")
        }
        d.set(NSNumber(value: s.win8StartColor), forKey: "win8StartColor")
    }
}

@MainActor
func debugLog(_ message: @autoclosure () -> String) {
    if SettingsStore.shared.current.debugLogging {
        NSLog("[Winstripe] %@", message())
    }
}
