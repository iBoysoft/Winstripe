import Foundation

/// Shared resolved-theme loading. Theme JSON is immutable after loading, so the
/// resolved result can be shared by validation, taskbar application, previews,
/// and the background prewarmer.
final class ThemeResolutionCache {
    static let shared = ThemeResolutionCache()

    private final class Pending {
        let group = DispatchGroup()
        var result: ThemeLoadResult?
        var theme: Theme?
        var error: Error?
        var callbacks: [(ThemeLoadResult?) -> Void] = []

        init() { group.enter() }
    }

    private let lock = NSLock()
    private var resolved: [String: ThemeLoadResult] = [:]
    private var builtThemes: [String: Theme] = [:]
    private var latest: [String: ThemeLoadResult] = [:]
    private var pending: [String: Pending] = [:]

    private init() {}

    func cached(_ id: String, userDirectory: URL = ThemePaths.userThemesDirectory) -> ThemeLoadResult? {
        lock.lock()
        let result = latest[requestIdentity(ThemeLoader.canonicalID(id), userDirectory: userDirectory)]
        lock.unlock()
        return result
    }

    func cachedTheme(_ id: String, userDirectory: URL = ThemePaths.userThemesDirectory) -> Theme? {
        lock.lock()
        let theme = builtThemes[cacheIdentity(ThemeLoader.canonicalID(id), userDirectory: userDirectory)]
        lock.unlock()
        return theme
    }

    func loadAsync(_ id: String, userDirectory: URL = ThemePaths.userThemesDirectory,
                   completion: @escaping (ThemeLoadResult?) -> Void) {
        let canonical = ThemeLoader.canonicalID(id)
        let requestKey = requestIdentity(canonical, userDirectory: userDirectory)
        lock.lock()
        if let existing = pending[requestKey] {
            existing.callbacks.append(completion)
            lock.unlock()
            return
        }
        let operation = Pending()
        operation.callbacks.append(completion)
        pending[requestKey] = operation
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.perform(id: canonical, userDirectory: userDirectory,
                          requestKey: requestKey, operation: operation)
        }
    }

    func loadSync(_ id: String, userDirectory: URL = ThemePaths.userThemesDirectory) throws -> ThemeLoadResult {
        let canonical = ThemeLoader.canonicalID(id)
        let requestKey = requestIdentity(canonical, userDirectory: userDirectory)
        lock.lock()
        if let existing = pending[requestKey] {
            lock.unlock()
            existing.group.wait()
            if let result = existing.result { return result }
            throw existing.error ?? ThemeResolutionCacheError.failed(canonical)
        }
        let operation = Pending()
        pending[requestKey] = operation
        lock.unlock()

        perform(id: canonical, userDirectory: userDirectory,
                requestKey: requestKey, operation: operation)
        operation.group.wait()
        if let result = operation.result { return result }
        throw operation.error ?? ThemeResolutionCacheError.failed(canonical)
    }

    func prewarmBuiltIns() {
        // Use the dedicated large-stack decoder instead of a Utility GCD worker. A synchronous
        // caller can observe a prewarm operation in `pending` and wait for it; keeping both the
        // producer and decoder on the same User-initiated thread avoids a QoS priority inversion.
        ThemeDecodeThread.async { [weak self] in
            guard let self else { return }
            for kind in ThemeKind.allCases {
                _ = try? self.loadSync(kind.id)
            }
        }
    }

    func clearForBenchmark() {
        lock.lock()
        resolved.removeAll(keepingCapacity: false)
        builtThemes.removeAll(keepingCapacity: false)
        latest.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func accept(_ result: ThemeLoadResult, for id: String,
                userDirectory: URL = ThemePaths.userThemesDirectory) {
        let canonical = ThemeLoader.canonicalID(id)
        let key = cacheIdentity(canonical, userDirectory: userDirectory)
        let theme = Theme.build(canonical, result: result)
        lock.lock()
        resolved[key] = result
        latest[requestIdentity(canonical, userDirectory: userDirectory)] = result
        if let theme { builtThemes[key] = theme }
        lock.unlock()
    }

    private func perform(id: String, userDirectory: URL, requestKey: String, operation: Pending) {
        let key = cacheIdentity(id, userDirectory: userDirectory)
        lock.lock()
        let cachedResult = resolved[key]
        let cachedTheme = builtThemes[key]
        lock.unlock()
        if let result = cachedResult {
            let theme = cachedTheme ?? Theme.build(id, result: result)
            finish(operation, requestKey: requestKey, result: result, theme: theme, error: nil, cacheKey: key)
            return
        }

        do {
            let result = try ThemeLoader().loadForID(id, userDirectory: userDirectory)
            let theme = Theme.build(id, result: result)
            finish(operation, requestKey: requestKey, result: result, theme: theme, error: nil, cacheKey: key)
        } catch {
            finish(operation, requestKey: requestKey, result: nil, theme: nil, error: error)
        }
    }

    private func finish(_ operation: Pending, requestKey: String,
                        result: ThemeLoadResult?, theme: Theme?, error: Error?, cacheKey: String? = nil) {
        lock.lock()
        operation.result = result
        operation.theme = theme
        operation.error = error
        if let cacheKey, let result {
            resolved[cacheKey] = result
            latest[requestKey] = result
            if let theme { builtThemes[cacheKey] = theme }
        }
        let callbacks = operation.callbacks
        operation.callbacks.removeAll(keepingCapacity: false)
        if pending[requestKey] === operation { pending.removeValue(forKey: requestKey) }
        lock.unlock()
        operation.group.leave()
        for callback in callbacks { callback(result) }
    }

    private func requestIdentity(_ id: String, userDirectory: URL) -> String {
        "request|\(id)|\(userDirectory.standardizedFileURL.path)|\(debugDirectoryToken())"
    }

    private func cacheIdentity(_ id: String, userDirectory: URL) -> String {
        let request = requestIdentity(id, userDirectory: userDirectory)
        if BuiltinThemes.json[id] != nil {
            #if DEBUG
            if let directory = ThemeLoader.debugThemeDirectory {
                let candidate = directory.appendingPathComponent(id + ".json")
                return request + "|" + fileToken(candidate)
            }
            #endif
            return request + "|builtin"
        }
        guard let record = UserThemeCatalog.record(id: id, directory: userDirectory) else {
            return request + "|missing"
        }
        let document = record.isFolder ? record.url.appendingPathComponent("theme.json") : record.url
        return request + "|" + fileToken(document)
    }

    private func fileToken(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.standardizedFileURL.path)|\(date)|\(size)"
    }

    private func debugDirectoryToken() -> String {
        #if DEBUG
        return ThemeLoader.debugThemeDirectory?.standardizedFileURL.path ?? ""
        #else
        return ""
        #endif
    }
}

private enum ThemeResolutionCacheError: Error {
    case failed(String)
}
