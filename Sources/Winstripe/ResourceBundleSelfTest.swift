import AppKit

/// `--resource-bundle-selftest`: resources must resolve from the app (or, for unbundled dev binaries,
/// from the folder next to the executable), never from the machine-specific build directory.
///
/// Inside a packaged `.app` it also checks the Xcode-style layout: no nested SwiftPM bundle, the lproj
/// folders, `Themes/`, `Assets.car` and `AppIcon.icns` directly in `Contents/Resources`, and the icon keys.
enum ResourceBundleSelfTest {
    /// Every shipped localization folder; pt-BR and pt both serve `Language.portuguese`.
    static let localizations = ["en", "zh-Hans", "zh-Hant", "fr", "es", "pt-BR", "pt", "ja", "ko", "de"]

    static func run() -> Int {
        var results: [(Bool, String)] = []
        func check(_ ok: Bool, _ label: String) { results.append((ok, label)) }
        let main = Bundle.main
        let packaged = main.bundleURL.pathExtension == "app"
        let bundlePath = L.bundle.bundleURL.resolvingSymlinksInPath().path
        let languages = Language.allCases.filter { $0 != .system }

        if packaged {
            let fm = FileManager.default
            let contents = main.bundleURL.appendingPathComponent("Contents")
            let resources = main.resourceURL ?? contents.appendingPathComponent("Resources")
            check(L.bundle === main, "resources resolve from Bundle.main: \(bundlePath)")
            let nested = (fm.enumerator(at: contents, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.lastPathComponent.hasSuffix(".bundle") }
            check(nested.isEmpty, "no nested resource bundle (\(nested.map(\.lastPathComponent).joined(separator: ", ")))")
            check(fm.fileExists(atPath: resources.appendingPathComponent("Assets.car").path), "Assets.car present")
            check(fm.fileExists(atPath: resources.appendingPathComponent("AppIcon.icns").path), "AppIcon.icns present")
            let iconFile = main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
            let iconName = main.object(forInfoDictionaryKey: "CFBundleIconName") as? String
            check(iconFile == "AppIcon" && iconName == "AppIcon", "Info.plist icon keys (\(iconFile ?? "-"), \(iconName ?? "-"))")
            let declared = Set(main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] ?? [])
            check(declared == Set(localizations), "CFBundleLocalizations lists all \(localizations.count) (\(declared.count))")
            let folders = localizations.filter {
                fm.fileExists(atPath: resources.appendingPathComponent("\($0).lproj/Localizable.strings").path)
            }
            check(folders.count == localizations.count, "\(folders.count)/\(localizations.count) lproj folders with Localizable.strings in Contents/Resources")
            let lprojs = languages.filter {
                let bundle = L.lprojBundle(for: $0)
                return bundle?.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == resources.resolvingSymlinksInPath().path
                    && bundle?.url(forResource: "Localizable", withExtension: "strings") != nil
            }
            check(lprojs.count == languages.count, "\(lprojs.count)/\(languages.count) languages resolve to Contents/Resources lproj")
            let icon = NSImage(named: "AppIcon")
            check(icon != nil, "AppIcon loads via NSImage(named:)")
            let snapshotAsset = NSDataAsset(name: AppResources.userAccountSnapshotImage, bundle: main)
            check(snapshotAsset != nil && AppResources.image(named: AppResources.userAccountSnapshotImage)?.size == NSSize(width: 42, height: 42),
                  "user tile loads from Assets.car (data asset, 42x42 pt)")
            let ids = BuiltinThemes.json.keys.sorted()
            let fromBundle = ids.filter { id in
                guard let url = AppResources.bundledThemeURL(id), let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                // The embedded copy is the file minus trailing whitespace (scripts/gen-builtin-themes.sh).
                return trimmingTrailingWhitespace(text) == BuiltinThemes.json[id] && AppResources.builtinThemeJSON(id) == text
            }
            check(fromBundle.count == ids.count, "\(fromBundle.count)/\(ids.count) built-in themes load from Contents/Resources/Themes")
        } else {
            let allowed = [main.resourceURL, main.bundleURL, main.executableURL?.deletingLastPathComponent()]
                .compactMap { $0?.resolvingSymlinksInPath().path }
            check(L.bundle !== main && allowed.contains { bundlePath.hasPrefix($0 + "/") }, "dev resource bundle is local: \(bundlePath)")
            check(AppResources.image(named: AppResources.userAccountSnapshotImage)?.size == NSSize(width: 42, height: 42), "asset catalog user tile loads (42x42 pt)")
        }
        check(L.bundle.url(forResource: "en", withExtension: "lproj") != nil, "localization resources present")
        let german = L.table(for: .german).count
        check(german > 100, "German table loads (\(german) keys)")
        for (ok, label) in results { print("\(ok ? "PASS" : "FAIL") \(label)") }
        return results.allSatisfy(\.0) ? 0 : 1
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }
}
