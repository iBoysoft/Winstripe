import Foundation
import AppKit
import Darwin
import ImageIO

enum ThemePaths {
    static var userDirectoryOverride: URL?

    static var defaultUserThemesDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("Winstripe/Themes", isDirectory: true)
    }

    static var userThemesDirectory: URL {
        if let userDirectoryOverride { return userDirectoryOverride }
        return defaultUserThemesDirectory
    }

    static var allowsOffscreenWrites: Bool {
        guard let override = userDirectoryOverride else { return false }
        return !isDefaultUserThemesPath(override)
    }

    static func isDefaultUserThemesPath(_ url: URL) -> Bool {
        let root = defaultUserThemesDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

struct UserThemeRecord: Sendable, Identifiable {
    let id: String
    let name: [String: String]
    let url: URL
    let isFolder: Bool
    var displayName: String { name["en"] ?? name["zh-Hans"] ?? id }
}

enum UserThemeCatalog {
    static func records(directory: URL = ThemePaths.userThemesDirectory) -> ([UserThemeRecord], [String]) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return ([], [])
        }
        var records: [UserThemeRecord] = []
        var errors: [String] = []
        var seen = Set<String>()
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isFolder = isDirectory && url.pathExtension.lowercased() == "rdtheme"
            let isJSON = !isDirectory && url.pathExtension.lowercased() == "json"
            guard isFolder || isJSON else { continue }
            let document = isFolder ? url.appendingPathComponent("theme.json") : url
            guard let data = try? Data(contentsOf: document),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String, !id.isEmpty else {
                errors.append("\(url.lastPathComponent): missing or invalid id")
                continue
            }
            let canonical = ThemeLoader.canonicalID(id)
            if BuiltinThemes.json[canonical] != nil {
                errors.append("\(url.lastPathComponent): id \(canonical) duplicates a built-in theme")
                continue
            }
            if !seen.insert(canonical).inserted {
                errors.append("\(url.lastPathComponent): duplicate user theme id \(canonical)")
                continue
            }
            let name = json["name"] as? [String: String] ?? ["en": canonical]
            records.append(UserThemeRecord(id: canonical, name: name, url: url, isFolder: isFolder))
        }
        return (records, errors)
    }

    static func record(id: String, directory: URL = ThemePaths.userThemesDirectory) -> UserThemeRecord? {
        records(directory: directory).0.first { $0.id == ThemeLoader.canonicalID(id) }
    }

    /// The built-in theme a user theme ultimately extends (follows `extends`
    /// through other user themes). Cached per id + file modification date, so an
    /// edited/re-imported theme re-resolves. nil when no built-in base is found.
    private final class BaseKindCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (stamp: Date?, kind: ThemeKind?)] = [:]
    }
    private static let baseKindCache = BaseKindCache()

    private static func themeFile(_ record: UserThemeRecord) -> URL {
        record.isFolder ? record.url.appendingPathComponent("theme.json") : record.url
    }

    static func baseKind(id: String, directory: URL = ThemePaths.userThemesDirectory) -> ThemeKind? {
        if let kind = ThemeKind(themeID: id) { return kind }
        guard let record = record(id: id, directory: directory) else { return nil }
        let file = themeFile(record)
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let cacheKey = directory.path + "|" + id
        baseKindCache.lock.lock()
        let cached = baseKindCache.entries[cacheKey]
        baseKindCache.lock.unlock()
        if let cached, cached.stamp == stamp { return cached.kind }
        var resolved: ThemeKind?
        var current = id
        var seen: Set<String> = []
        while seen.insert(current).inserted {
            if let kind = ThemeKind(themeID: current) { resolved = kind; break }
            guard let next = Self.record(id: current, directory: directory),
                  let data = try? Data(contentsOf: themeFile(next)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parent = object["extends"] as? String else { break }
            current = ThemeLoader.canonicalID(parent)
        }
        baseKindCache.lock.lock()
        baseKindCache.entries[cacheKey] = (stamp, resolved)
        baseKindCache.lock.unlock()
        return resolved
    }

    static func familyKind(id: String, directory: URL = ThemePaths.userThemesDirectory) -> ThemeKind {
        // Prefer the real built-in base (extends chain); family is only a fallback.
        if let base = baseKind(id: id, directory: directory) { return base }
        guard let record = record(id: id, directory: directory),
              let data = try? Data(contentsOf: record.isFolder ? record.url.appendingPathComponent("theme.json") : record.url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let family = object["family"] as? String else { return .win95 }
        return family == "modern" ? .win11 : .win95
    }
}

enum ThemeImportError: Error, CustomStringConvertible, LocalizedError {
    case unsupported
    case invalid(String)
    case duplicate(String)
    var description: String {
        switch self {
        case .unsupported: return "unsupported theme format"
        case .invalid(let reason): return reason
        case .duplicate(let id): return "theme id \(id) already exists"
        }
    }
    var errorDescription: String? { description }
}

enum ThemeImportExport {
    static func importTheme(_ source: URL, into directory: URL = ThemePaths.userThemesDirectory,
                            allowCopy: Bool = false) throws -> UserThemeRecord {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("WinstripeImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let folder: URL
        if source.hasDirectoryPath || source.pathExtension.lowercased() == "rdtheme" && (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folder = source
        } else if source.pathExtension.lowercased() == "json" {
            folder = temp.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".rdtheme", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: folder.appendingPathComponent("theme.json"))
        } else if source.pathExtension.lowercased() == "rdtheme" {
            guard safeZipEntries(source) else { throw ThemeImportError.invalid("unsafe archive path") }
            let extraction = temp.appendingPathComponent("archive", isDirectory: true)
            try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
            try run("/usr/bin/unzip", ["-q", "-o", source.path, "-d", extraction.path])
            if let entries = fm.enumerator(at: extraction, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let item as URL in entries where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw ThemeImportError.invalid("archive contains a symlink")
                }
            }
            let direct = extraction.appendingPathComponent("theme.json")
            if fm.fileExists(atPath: direct.path) { folder = extraction }
            else if let child = try? fm.contentsOfDirectory(at: extraction, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).first(where: { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) && fm.fileExists(atPath: $0.appendingPathComponent("theme.json").path) }) {
                folder = child
            } else { throw ThemeImportError.invalid("theme.json is missing") }
        } else { throw ThemeImportError.unsupported }
        let json = folder.appendingPathComponent("theme.json")
        guard fm.fileExists(atPath: json.path) else { throw ThemeImportError.invalid("theme.json is missing") }
        let loader = ThemeLoader()
        var originalID: String?
        var validationURL = json
        if let data = try? Data(contentsOf: json) {
            let any = try JSONSerialization.jsonObject(with: data)
            if var object = any as? [String: Any], let candidateID = object["id"] as? String,
               BuiltinThemes.json[ThemeLoader.canonicalID(candidateID)] != nil {
                originalID = ThemeLoader.canonicalID(candidateID)
                object["id"] = "__import_validation_\(UUID().uuidString)"
                validationURL = temp.appendingPathComponent("validation.json")
                try JSONSerialization.data(withJSONObject: object, options: []).write(to: validationURL)
            }
        }
        let result = loader.load(validationURL.path, user: true, allowBuiltInID: true)
        guard result.succeeded else { throw ThemeImportError.invalid(result.diagnostics.map(\.description).joined(separator: "\n")) }
        try validateAssets(in: folder)
        let id = originalID ?? result.theme.config.id
        let (existing, catalogErrors) = UserThemeCatalog.records(directory: directory)
        if BuiltinThemes.json[id] != nil || existing.contains(where: { $0.id == id }) {
            guard allowCopy else { throw ThemeImportError.duplicate(id) }
        }
        let finalID = (BuiltinThemes.json[id] != nil || existing.contains(where: { $0.id == id })) ? uniqueCopyID(id, existing: existing) : id
        let destination = directory.appendingPathComponent(finalID + ".rdtheme", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: folder, to: destination)
        if finalID != id {
            let destinationJSON = destination.appendingPathComponent("theme.json")
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: destinationJSON)) as? [String: Any] else {
                throw ThemeImportError.invalid("theme.json is not an object")
            }
            var object = parsed
            object["id"] = finalID
            if var name = object["name"] as? [String: String] {
                for key in name.keys { name[key] = "\(name[key] ?? finalID) (Copy)" }
                object["name"] = name
            } else { object["name"] = ["en": "\(finalID) (Copy)"] }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destinationJSON, options: .atomic)
        }
        _ = catalogErrors
        return UserThemeCatalog.record(id: finalID, directory: directory)
            ?? UserThemeRecord(id: finalID, name: ["en": finalID], url: destination, isFolder: true)
    }

    static func exportTheme(id: String, to output: URL, userDirectory: URL = ThemePaths.userThemesDirectory) throws {
        let loader = ThemeLoader()
        let result = try loader.loadForID(id, userDirectory: userDirectory)
        guard result.succeeded else { throw ThemeImportError.invalid(result.diagnostics.map(\.description).joined(separator: "\n")) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("WinstripeExport-\(UUID().uuidString).rdtheme", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result.theme.json).write(to: temp.appendingPathComponent("theme.json"))
        let fm = FileManager.default
        for path in referencedAssetPaths(result.theme.json) {
            let roots = ([result.theme.assetRoot].compactMap { $0 } + Array(result.theme.imageAssetRoots.values))
            guard let sourceRoot = roots.first(where: { fm.fileExists(atPath: $0.appendingPathComponent(path).path) }) else { continue }
            let src = sourceRoot.appendingPathComponent(path).standardizedFileURL
            guard src.path.hasPrefix(sourceRoot.standardizedFileURL.path + "/"), fm.fileExists(atPath: src.path) else { continue }
            let dst = temp.appendingPathComponent(path)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }
        try? fm.removeItem(at: output)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", temp.path, output.path])
        try? fm.removeItem(at: temp)
    }

    private static func uniqueCopyID(_ id: String, existing: [UserThemeRecord]) -> String {
        let used = Set(existing.map(\.id) + BuiltinThemes.json.keys)
        var candidate = "\(id)-copy", n = 2
        while used.contains(candidate) { candidate = "\(id)-copy-\(n)"; n += 1 }
        return candidate
    }

    private static func referencedAssetPaths(_ value: ThemeJSON) -> [String] {
        switch value {
        case .object(let object): return object.flatMap { key, value in key == "file" ? [value.string].compactMap { $0 } : referencedAssetPaths(value) }
        case .array(let values): return values.flatMap(referencedAssetPaths)
        default: return []
        }
    }

    private static func validateAssets(in folder: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in e where ["png", "pdf"].contains(url.pathExtension.lowercased()) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 4 * 1024 * 1024 else { throw ThemeImportError.invalid("image \(url.lastPathComponent) exceeds 4 MB") }
            if url.pathExtension.lowercased() == "png" {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ThemeImportError.invalid("image \(url.lastPathComponent) cannot be decoded")
                }
                let width = image.width
                let height = image.height
                guard width <= 1024 && height <= 1024 else {
                    throw ThemeImportError.invalid("image \(url.lastPathComponent) exceeds 1024 px")
                }
            }
        }
    }

    private static func safeZipEntries(_ url: URL) -> Bool {
        let result = try? process("/usr/bin/unzip", ["-Z1", url.path])
        guard let output = result else { return false }
        return output.split(separator: "\n").allSatisfy { entry in
            let p = String(entry)
            return !p.hasPrefix("/") && !p.split(separator: "/").contains("..")
        }
    }

    @discardableResult private static func run(_ executable: String, _ args: [String]) throws -> String { try process(executable, args) }
    private static func process(_ executable: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 { throw ThemeImportError.invalid(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}

@MainActor
final class ThemeHotReloadCore {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?
    private var watchedRoots: [URL] = []
    private var watchedThemeID: String?
    private var sourceGeneration = 0
    private let directoryContents: (URL) -> [URL]
    private let loadTheme: (String) -> ThemeLoadResult?
    private(set) var lastGood: ThemeLoadResult?
    var onReload: ((ThemeLoadResult) -> Void)?

    init(fileManager: FileManager = .default,
         directoryContents: ((URL) -> [URL])? = nil,
         loadTheme: ((String) -> ThemeLoadResult?)? = nil) {
        self.directoryContents = directoryContents ?? { directory in
            (try? fileManager.contentsOfDirectory(at: directory,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        }
        self.loadTheme = loadTheme ?? { id in try? ThemeLoader().loadForID(id) }
    }

    func watch(directory: URL, themeID: String) {
        watch(directories: [directory], themeID: themeID)
    }

    func watch(directories: [URL], themeID: String) {
        stop()
        watchedRoots = uniqueURLs(directories)
        watchedThemeID = themeID
        installSources()
    }

    private func installSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        sourceGeneration &+= 1
        let generation = sourceGeneration
        let directories = uniqueURLs(watchedRoots + watchedRoots.flatMap(packageDirectories(in:)))
        let newSources = directories.compactMap { directory -> DispatchSourceFileSystemObject? in
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
            source.setCancelHandler { close(fd) }
            return source
        }
        guard !newSources.isEmpty else { return }
        for source in newSources {
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, self.sourceGeneration == generation else { return }
                    self.installSources()
                    self.scheduleReload()
                }
            }
            source.resume()
        }
        sources = newSources
    }

    private func scheduleReload() {
        debounce?.cancel()
        guard let themeID = watchedThemeID else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let result = self.loadTheme(themeID) else { return }
            if result.succeeded { self.lastGood = result }
            self.onReload?(result)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func packageDirectories(in root: URL) -> [URL] {
        let packages = directoryContents(root).filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory && url.pathExtension.lowercased() == "rdtheme"
        }
        return packages.flatMap(recursiveDirectories(in:))
    }

    private func recursiveDirectories(in package: URL) -> [URL] {
        var result: [URL] = []
        var pending = [package]
        var seen = Set<String>()
        while let directory = pending.popLast() {
            let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { continue }
            result.append(directory)
            for child in directoryContents(directory) {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory { pending.append(child) }
            }
        }
        return result
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        watchedRoots.removeAll()
        watchedThemeID = nil
        sourceGeneration &+= 1
        debounce?.cancel()
        debounce = nil
    }
}
