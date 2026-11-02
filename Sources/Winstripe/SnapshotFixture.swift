import AppKit

/// Static inputs for the offscreen verification commands only.
@MainActor
enum SnapshotFixture {
    static var isActive = false
    static var win8LayoutEntries: [Win8LayoutEntry] = []
    static var startMenuStyleOverride: StartMenuStyle?
    static var settings: TaskbarSettings {
        var settings = TaskbarSettings()
        settings.language = .english
        settings.startMenuStyleChoice = startMenuStyleOverride
        return settings
    }
    static let trayAppPaths = [
        "/WinstripeFixtures/Calendar.app",
        "/WinstripeFixtures/Mail.app",
        "/WinstripeFixtures/Notes.app"
    ]
    static let trayBadges: [String: String] = [
        trayAppPaths[0]: "3", trayAppPaths[1]: "120", trayAppPaths[2]: "•"
    ]
    static var userName: String { isActive ? "Winstripe User" : NSFullUserName() }
    static let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    static let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)

    static func activate() {
        isActive = true
        // Offscreen output never depends on the user's collections or installed apps.
        AppCollections.useFixtures()
        win8LayoutEntries = []
        ApplicationCatalog.override = catalog
    }

    static func prepareUserThemes(includeBroken: Bool = true) {
        guard ThemePaths.allowsOffscreenWrites else { return }
        let root = ThemePaths.userThemesDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fm = FileManager.default
        let examples = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/examples")
        for name in ["win95-teal.rdtheme", "win7-image-orb.rdtheme"] {
            let source = examples.appendingPathComponent(name)
            let destination = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: source, to: destination)
        }
        let broken = root.appendingPathComponent("broken.rdtheme", isDirectory: true)
        if includeBroken {
            if !fm.fileExists(atPath: broken.path) {
                try? fm.createDirectory(at: broken, withIntermediateDirectories: true)
                try? Data("{ invalid".utf8).write(to: broken.appendingPathComponent("theme.json"))
            }
        } else if fm.fileExists(atPath: broken.path) {
            try? fm.removeItem(at: broken)
        }
    }

    static func clearUserThemeFixtures() {
        guard ThemePaths.allowsOffscreenWrites else { return }
        let root = ThemePaths.userThemesDirectory
        let fm = FileManager.default
        for name in ["win95-teal.rdtheme", "win7-image-orb.rdtheme", "broken.rdtheme"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static func time(_ language: Language) -> String {
        language.resolvedLanguage == .english ? "8:47 PM" : "20:47"
    }

    static func longDate(_ language: Language) -> String {
        language.resolvedLanguage == .chinese ? "2026年10月9日星期五" : "Friday, October 9, 2026"
    }

    static var catalog: [CatalogApp] {
        [("Calculator", "plus.forwardslash.minus"), ("Calendar", "calendar"), ("Mail", "envelope"),
         ("Maps", "map"), ("Music", "music.note"), ("Notes", "note.text"),
         ("Photos", "photo"), ("Safari", "safari")].map {
            CatalogApp(name: $0.0, symbol: $0.1)
        }
    }

    static var denseWin10Catalog: [CatalogApp] {
        let names = ["Calculator", "Calendar", "Mail", "Maps", "Music", "Notes", "Photos", "Safari",
                     "Clock", "Contacts", "Dictionary", "FaceTime", "GarageBand", "Home", "Keynote",
                     "Messages", "Numbers", "Pages", "Preview", "Reminders", "Shortcuts", "Stocks",
                     "System Settings", "TextEdit", "Tips", "Voice Memos", "Weather", "Xcode"]
        return names.map { CatalogApp(name: $0, symbol: "app") }
    }

    static var denseWin8Catalog: [CatalogApp] {
        [("AirPort Utility", "airport.extreme"), ("Calendar", "calendar"),
         ("Bluetooth", "wave.3.right.circle"), ("App Store", "bag"),
         ("Console", "terminal"), ("Books", "book"),
         ("Apps", "square.grid.2x2"), ("Audio", "waveform"),
         ("Codex++", "chevron.left.forwardslash.chevron.right"),
         ("ChatGPT", "message"), ("Mail", "envelope")].map {
            CatalogApp(name: $0.0, symbol: $0.1)
        }
    }

    static func name(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func icon(for url: URL) -> NSImage {
        let app = catalog.first { $0.name == name(for: url) }
        return app?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: name(for: url))
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    static var sampleApps: [AppEntry] {
        ["Safari", "Notes", "Calendar", "Mail"].enumerated().map { index, name in
            let symbol = ["safari", "note.text", "calendar", "envelope.fill"][index]
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .symbolTinted([.systemBlue], configuration: NSImage.SymbolConfiguration(pointSize: 28, weight: .regular))
            return AppEntry(pid: pid_t(index + 1), name: name, icon: image, badge: nil,
                            windowCount: 1, isHidden: false)
        }
    }

    static var pins: [PinnedApp] {
        [PinnedApp(bundleID: "com.apple.calculator", path: "/System/Applications/Calculator.app"),
         PinnedApp(bundleID: "com.apple.Maps", path: "/System/Applications/Maps.app"),
         PinnedApp(bundleID: "com.apple.Safari", path: "/Applications/Safari.app")]
    }

    static func bitmap(for view: NSView) -> NSBitmapImageRep? {
        guard isActive else { return view.bitmapImageRepForCachingDisplay(in: view.bounds) }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: Int(ceil(view.bounds.width * 2)),
                                  pixelsHigh: Int(ceil(view.bounds.height * 2)),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = view.bounds.size
        if let rep, let bytes = rep.bitmapData {
            bytes.initialize(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        return rep
    }

    static func themeID(_ kind: ThemeKind) -> String {
        switch kind {
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
}

@MainActor
struct CatalogApp {
    let name: String
    let symbol: String
    var url: URL { URL(fileURLWithPath: "/Applications/\(name).app") }
    var icon: NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: name)
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}

@MainActor
enum ApplicationCatalog {
    static var override: [CatalogApp]?
}
