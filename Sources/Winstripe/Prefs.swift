import Foundation

/// The single defaults domain the app reads and writes.
/// Verification modes (any `--*-selftest`, snapshot, dump, bench, theme-tool flag, or
/// `WINSTRIPE_ISOLATED_PREFS=1`) get a throwaway suite `Winstripe.selftest.<pid>` that is
/// removed at exit, so they can never touch the user's real `com.iboysoft.winstripe` domain
/// or its `AppleLanguages`.
enum Prefs {
    static let realDomain = "com.iboysoft.winstripe"

    static let isIsolated: Bool = {
        if ProcessInfo.processInfo.environment["WINSTRIPE_ISOLATED_PREFS"] == "1" { return true }
        let exact: Set<String> = ["--snapshot-dir", "--win8-edit-snapshot", "--win8-anim-frames",
                                  "--validate-theme", "--import-theme", "--export-theme", "--hot-reload-test",
                                  "--list-windows", "--theme-stack-probe"]
        return CommandLine.arguments.dropFirst().contains { arg in
            exact.contains(arg) || arg.hasSuffix("-selftest") || arg.hasPrefix("--bench-")
                || arg.hasPrefix("--dump-") || arg.hasSuffix("-dump") || arg.hasPrefix("--print-")
        }
    }()

    /// An absolute-path suite keeps the backing plist in the temp directory, so even a late
    /// cfprefsd flush can never leave a file in ~/Library/Preferences.
    static let isolatedSuiteName = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("Winstripe.selftest.\(ProcessInfo.processInfo.processIdentifier)")

    static let defaults: UserDefaults = {
        guard isIsolated else { return .standard }
        guard let suite = UserDefaults(suiteName: isolatedSuiteName) else {
            FileHandle.standardError.write(Data("error: cannot create isolated defaults suite\n".utf8))
            exit(70)
        }
        suite.removePersistentDomain(forName: isolatedSuiteName)
        atexit { Prefs.removeIsolatedSuite() }
        return suite
    }()

    static func removeIsolatedSuite() {
        guard isIsolated else { return }
        UserDefaults.standard.removePersistentDomain(forName: isolatedSuiteName)
        CFPreferencesAppSynchronize(isolatedSuiteName as CFString)
        try? FileManager.default.removeItem(atPath: isolatedSuiteName + ".plist")
    }
}

@MainActor
enum PrefsIsolationSelfTest {
    static func run() -> Int {
        func real(_ key: String) -> String {
            CFPreferencesAppSynchronize(Prefs.realDomain as CFString)
            let v = CFPreferencesCopyAppValue(key as CFString, Prefs.realDomain as CFString)
            return v.map { "\($0)" } ?? "<nil>"
        }
        let keys = ["themeID", "theme", "language", "AppleLanguages", "location"]
        let before = keys.map(real)
        guard Prefs.isIsolated, Prefs.defaults !== UserDefaults.standard else {
            print("FAIL prefs isolation selftest: verification mode is not isolated"); return 1
        }
        SettingsStore.shared.mutate {
            $0.theme = $0.theme == .win95 ? .win11 : .win95
            $0.userThemeID = nil
            $0.language = $0.language == .english ? .chinese : .english
            $0.edge = $0.edge == .top ? .bottom : .top
        }
        guard Prefs.defaults.string(forKey: "themeID") != nil else {
            print("FAIL prefs isolation selftest: store did not write to the isolated suite"); return 1
        }
        let after = keys.map(real)
        guard before == after else {
            print("FAIL prefs isolation selftest: real domain changed \(before) -> \(after)"); return 1
        }
        print("PASS prefs isolation selftest (\(Prefs.isolatedSuiteName))")
        return 0
    }
}
