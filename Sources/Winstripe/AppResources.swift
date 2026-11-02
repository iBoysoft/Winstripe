import AppKit

/// Where Winstripe's resources live.
///
/// The packaged app is laid out like an Xcode build: the `.lproj` folders, `Themes/`, `Assets.car` and
/// `AppIcon.icns` sit directly in `Contents/Resources` and are read through `Bundle.main`
/// (`NSLocalizedString`, `NSImage(named:)`). Unbundled dev/test binaries from `swift build` fall back to
/// the SwiftPM resource bundle next to the executable. It is located by hand because SwiftPM's generated
/// `Bundle.module` traps on any Mac where the absolute build directory does not exist.
enum AppResources {
    static let devBundleName = "Winstripe_Winstripe.bundle"
    static let userAccountSnapshotImage = "UserAccountSnapshot"
    static let themesDirectory = "Themes"

    /// `Bundle.main` when it carries the localizations (packaged app), else the dev resource bundle.
    static let bundle: Bundle = {
        let main = Bundle.main
        if main.url(forResource: "en", withExtension: "lproj") != nil { return main }
        var roots = [main.resourceURL, main.bundleURL, main.executableURL?.deletingLastPathComponent()]
        if let exe = main.executableURL?.resolvingSymlinksInPath() { roots.append(exe.deletingLastPathComponent()) }
        for root in roots.compactMap({ $0 }) {
            if let candidate = Bundle(url: root.appendingPathComponent(devBundleName)) { return candidate }
        }
        return main
    }()

    static var usesMainBundle: Bool { bundle === Bundle.main }

    /// Images come from the compiled asset catalog: `NSImage(named:)` for image sets in the app, or an
    /// `NSDataAsset` holding the original PNG bytes. Fixture images whose pixels must stay exact (the
    /// snapshot user tile) are data sets, because actool re-encodes image-set rasters with +/-1 channel
    /// changes. Dev bundles use their own `Assets.car`; builds that copy the catalog uncompiled read the
    /// PNG from the set folder directly.
    static func image(named name: String) -> NSImage? {
        if usesMainBundle, let image = NSImage(named: name) { return image }
        if !usesMainBundle, let image = bundle.image(forResource: name) { return image }
        if let asset = NSDataAsset(name: name, bundle: bundle), let image = NSImage(data: asset.data) { return image }
        guard let catalog = bundle.url(forResource: "Assets", withExtension: "xcassets") else { return nil }
        for kind in ["dataset", "imageset"] {
            let set = catalog.appendingPathComponent(name + "." + kind)
            let files = (try? FileManager.default.contentsOfDirectory(at: set, includingPropertiesForKeys: nil)) ?? []
            if let png = files.filter({ $0.pathExtension == "png" }).sorted(by: { $0.path < $1.path }).first {
                return NSImage(contentsOf: png)
            }
        }
        return nil
    }

    /// The packaged copy of a built-in theme (`Contents/Resources/Themes/<display-name>.json`), if any.
    static func bundledThemeURL(_ id: String) -> URL? {
        guard usesMainBundle else { return nil }
        let stem = bundledThemeStems[id] ?? id
        return Bundle.main.url(forResource: stem, withExtension: "json", subdirectory: themesDirectory)
    }

    /// Built-in IDs remain stable for settings and inheritance; resource filenames use the shorter
    /// names shown in the Themes folder.
    private static let bundledThemeStems: [String: String] = [
        "win95": "95", "win98": "98", "winxp": "xp",
        "winme": "me", "win2000": "2000", "vista": "vista",
        "win7": "7", "win8": "8", "win10": "10", "win11": "11"
    ]

    /// Built-in theme source: the app's bundled JSON, falling back to the copy compiled into the binary
    /// (dev builds, or a damaged bundle). `nil` for ids that are not built in.
    static func builtinThemeJSON(_ id: String) -> String? {
        guard let embedded = BuiltinThemes.json[id] else { return nil }
        if let url = bundledThemeURL(id), let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return embedded
    }
}
