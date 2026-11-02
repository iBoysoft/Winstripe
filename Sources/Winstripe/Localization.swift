import Foundation

/// Bundle-backed localization with a resolved language override for live switching.
enum L {
    private static let supportedLocales: [Language: String] = Dictionary(
        firstWins: Language.allCases.filter { $0 != .system }.map { ($0, $0.localeIdentifier) })
    private static let tableLock = NSLock()
    private static var tableCache: [String: [String: String]] = [:]
    private static var lprojCache: [String: Bundle] = [:]

    /// Resource bundle holding the lproj folders: `Bundle.main` in the packaged app (see `AppResources`).
    static var bundle: Bundle { AppResources.bundle }

    static func t(_ key: String, _ lang: Language) -> String {
        let resolved = lang.resolvedLanguage
        let english = table(for: .english)[key] ?? key
        if let targetValue = table(for: resolved)[key] {
            if let targetBundle = lprojBundle(for: resolved) {
                return NSLocalizedString(key, tableName: nil, bundle: targetBundle, value: targetValue, comment: "")
            }
            return targetValue
        }
        if resolved != .english, let englishBundle = lprojBundle(for: .english) {
            return NSLocalizedString(key, tableName: nil, bundle: englishBundle, value: english, comment: "")
        }
        return key
    }

    static func table(for language: Language) -> [String: String] {
        let locale = supportedLocales[language.resolvedLanguage] ?? "en"
        tableLock.lock()
        if let cached = tableCache[locale] {
            tableLock.unlock()
            return cached
        }
        tableLock.unlock()
        guard let bundle = lprojBundle(for: language.resolvedLanguage),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: String] else {
            tableLock.lock()
            tableCache[locale] = [:]
            tableLock.unlock()
            return [:]
        }
        tableLock.lock()
        tableCache[locale] = values
        tableLock.unlock()
        return values
    }

    private static func lprojIgnoringCase(_ locale: String, in root: Bundle) -> Bundle? {
        let wanted = (locale + ".lproj").lowercased()
        let dirs = [root.resourceURL, root.bundleURL].compactMap { $0 }
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if let match = items.first(where: { $0.lastPathComponent.lowercased() == wanted }), let b = Bundle(url: match) {
                return b
            }
        }
        return nil
    }

    static func lprojBundle(for language: Language) -> Bundle? {
        let locale = supportedLocales[language.resolvedLanguage] ?? "en"
        tableLock.lock()
        if let cached = lprojCache[locale] {
            tableLock.unlock()
            return cached
        }
        tableLock.unlock()

        var roots: [Bundle] = [bundle]
        if Bundle.main.bundleURL != bundle.bundleURL {
            roots.append(Bundle.main)
        }
        var found: Bundle?
        for root in roots {
            if let url = root.url(forResource: locale, withExtension: "lproj"), let candidate = Bundle(url: url) {
                found = candidate
                break
            }
        }
        if found == nil {
            // Packaging can lower-case lproj names (pt-br.lproj); bundle lookup is case-sensitive.
            found = roots.lazy.compactMap { lprojIgnoringCase(locale, in: $0) }.first
        }
        if let found {
            tableLock.lock()
            lprojCache[locale] = found
            tableLock.unlock()
        }
        return found
    }

    static func runSelfTest() -> Int {
        let languages = Language.allCases.filter { $0 != .system }
        let en = table(for: .english)
        var failures: [String] = []
        if en.isEmpty { failures.append("unable to load en table") }
        var keys = Set(en.keys)
        let tables = languages.map { ($0, table(for: $0)) }
        for (_, values) in tables { keys.formUnion(values.keys) }
        for (language, values) in tables {
            let code = language.localeIdentifier
            if values.isEmpty { failures.append("\(code): unable to load table"); continue }
            if lprojBundle(for: language) == nil { failures.append("\(code): missing lproj bundle") }
            for key in keys.sorted() {
                guard let value = values[key] else { failures.append("\(code): missing key \(key)"); continue }
                if value.isEmpty { failures.append("\(code): empty value \(key)") }
                if let enValue = en[key], formatSpecifiers(enValue) != formatSpecifiers(value) {
                    failures.append("\(code): format mismatch \(key): en=\(formatSpecifiers(enValue)) \(code)=\(formatSpecifiers(value))")
                }
            }
            if language != .english, t("Taskbar", language) == en["Taskbar"] {
                failures.append("\(code): lookup returned the English value")
            }
        }
        let resolution: [([String], Language)] = [
            (["zh-TW"], .traditionalChinese), (["zh-Hant-HK"], .traditionalChinese), (["zh-HK"], .traditionalChinese),
            (["zh-Hans-CN"], .chinese), (["zh-CN"], .chinese), (["pt-PT"], .portuguese), (["pt-BR"], .portuguese),
            (["fr-CA"], .french), (["es-419"], .spanish), (["ja-JP"], .japanese), (["ko-KR"], .korean),
            (["de-CH"], .german), (["en-GB"], .english), (["it-IT", "de-DE"], .german), (["it-IT"], .english), ([], .english),
        ]
        for (preferred, expected) in resolution where Language.bestMatch(for: preferred) != expected {
            failures.append("resolution \(preferred) -> \(Language.bestMatch(for: preferred)) expected \(expected)")
        }
        if failures.isEmpty {
            print("PASS l10n selftest (\(keys.count) keys x \(languages.count) languages, \(resolution.count) resolution cases)")
            return 0
        }
        for failure in failures { fputs("FAIL l10n selftest: \(failure)\n", stderr) }
        return 1
    }

    private static func formatSpecifiers(_ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "%(?:[0-9]+\\$)?[-+#0-9. ]*(?:lld|@|d)", options: []) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, options: [], range: range).compactMap {
            guard let matchRange = Range($0.range, in: value) else { return nil }
            return String(value[matchRange])
        }
    }
}
