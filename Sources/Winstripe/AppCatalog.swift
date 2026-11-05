import AppKit
import CoreServices

/// One file or folder found under an application root. Everything a Start menu list needs from the
/// disk is read once by the background scan and kept here.
struct AppCatalogEntry: Equatable {
    let url: URL
    /// `FileManager.displayName`, which can still end in ".app" when Finder shows extensions.
    let displayName: String
    let bundleID: String?
    let resolvedPath: String
    let isApp: Bool
    let isDirectory: Bool
    let isPackage: Bool
    /// When the app's Info.plist last changed, so an updated app gets its icon drawn again.
    let modified: Date?

    var nameWithoutSuffix: String { displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName }
    var nameWithoutExtension: String { displayName.replacingOccurrences(of: ".app", with: "") }
}

struct AppCatalogRoots: Equatable {
    var applications: URL
    var system: URL
    var user: URL

    var all: [URL] { [applications, system, user] }

    static var standard: AppCatalogRoots {
        AppCatalogRoots(applications: URL(fileURLWithPath: "/Applications"),
                        system: URL(fileURLWithPath: "/System/Applications"),
                        user: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"))
    }
}

struct AppCatalogSnapshot: Equatable {
    /// The children of every scanned directory, by directory path, sorted by file name.
    var listings: [String: [AppCatalogEntry]] = [:]
    /// Apps outside the roots that were asked for by path, such as a pin or a default browser.
    var extras: [String: AppCatalogEntry] = [:]
    /// The app that opens each address in `AppCatalog.handlerAddresses`.
    var defaultHandlers: [String: URL] = [:]
    var byPath: [String: AppCatalogEntry] = [:]

    func entries(in directory: URL) -> [AppCatalogEntry] { listings[directory.path] ?? [] }

    /// Apps directly inside the application folders and their Utilities folders.
    func flatApps(roots: AppCatalogRoots) -> [AppCatalogEntry] {
        [roots.applications, roots.applications.appendingPathComponent("Utilities"),
         roots.system, roots.system.appendingPathComponent("Utilities"), roots.user]
            .flatMap { entries(in: $0).filter(\.isApp) }
    }

    /// Apps at any depth under the roots; never looks inside a package.
    func deepApps(roots: AppCatalogRoots) -> [AppCatalogEntry] {
        func walk(_ directory: URL) -> [AppCatalogEntry] {
            entries(in: directory).flatMap { entry -> [AppCatalogEntry] in
                if entry.isApp { return [entry] }
                return entry.isDirectory && !entry.isPackage ? walk(entry.url) : []
            }
        }
        return roots.all.flatMap(walk)
    }
}

/// Counts where the slow work ran, for `--app-catalog-selftest`.
final class AppCatalogProbe: @unchecked Sendable {
    static let shared = AppCatalogProbe()
    private let lock = NSLock()
    private var values = (scans: 0, scansOnMain: 0, iconLoads: 0, iconLoadsOnMain: 0)

    func recordScan() {
        lock.lock(); defer { lock.unlock() }
        values.scans += 1
        if Thread.isMainThread { values.scansOnMain += 1 }
    }

    func recordIconLoad() {
        lock.lock(); defer { lock.unlock() }
        values.iconLoads += 1
        if Thread.isMainThread { values.iconLoadsOnMain += 1 }
    }

    var current: (scans: Int, scansOnMain: Int, iconLoads: Int, iconLoadsOnMain: Int) {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Bundle IDs from the last scan, so `PinnedApp(url:)`, which every list calls per row, need not read
/// each Info.plist on the main thread. A URL the scan has not seen is still read once from its bundle.
final class AppBundleIDIndex: @unchecked Sendable {
    static let shared = AppBundleIDIndex()
    private let lock = NSLock()
    private var ids: [String: String?] = [:]

    func replace(_ ids: [String: String?]) {
        lock.lock(); defer { lock.unlock() }
        self.ids = ids
    }

    func bundleID(for url: URL) -> String? {
        let path = url.path
        lock.lock()
        let known = ids[path]
        lock.unlock()
        if let known { return known }
        return Bundle(url: url)?.bundleIdentifier
    }
}

/// Reads the application folders. Only ever runs on the catalog's background queue.
enum AppCatalogScanner {
    static func scan(roots: AppCatalogRoots, extraPaths: Set<String>, addresses: [String]) -> AppCatalogSnapshot {
        AppCatalogProbe.shared.recordScan()
        var snapshot = AppCatalogSnapshot()
        for root in roots.all { walk(root, depth: 0, into: &snapshot) }
        for address in addresses {
            guard let resource = URL(string: address),
                  let handler = NSWorkspace.shared.urlForApplication(toOpen: resource) else { continue }
            snapshot.defaultHandlers[address] = handler
        }
        var known = Set(snapshot.listings.values.joined().map(\.url.path))
        let extraURLs: [URL] = snapshot.defaultHandlers.values.map { URL(fileURLWithPath: $0.path) }
            + extraPaths.map { URL(fileURLWithPath: $0) }
        for url in extraURLs where known.insert(url.path).inserted {
            snapshot.extras[url.path] = entry(for: url, isDirectory: true, isPackage: true)
        }
        for entry in snapshot.listings.values.joined() { snapshot.byPath[entry.url.path] = entry }
        for (path, entry) in snapshot.extras { snapshot.byPath[path] = entry }
        return snapshot
    }

    /// Symbolic links count as files here, so a link back up the tree cannot loop. Apps that are links,
    /// such as Safari on recent macOS releases, are still listed by their extension.
    private static func walk(_ directory: URL, depth: Int, into snapshot: inout AppCatalogSnapshot) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return }
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let entries = sorted.map { url -> AppCatalogEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            // Listings may resolve a linked root, as /var to /private/var. Keep paths under the root as asked for.
            return entry(for: directory.appendingPathComponent(url.lastPathComponent, isDirectory: isDirectory),
                         isDirectory: isDirectory, isPackage: values?.isPackage == true)
        }
        snapshot.listings[directory.path] = entries
        // The Programs menu opens the first two levels of a folder even if it is a package; other lists stop there.
        for entry in entries where entry.isDirectory && !entry.isApp && (!entry.isPackage || depth < 2) {
            walk(entry.url, depth: depth + 1, into: &snapshot)
        }
    }

    private static func entry(for url: URL, isDirectory: Bool, isPackage: Bool) -> AppCatalogEntry {
        let isApp = url.pathExtension.lowercased() == "app"
        let plist = url.appendingPathComponent("Contents/Info.plist")
        return AppCatalogEntry(url: url,
                               displayName: FileManager.default.displayName(atPath: url.path),
                               bundleID: isApp ? Bundle(url: url)?.bundleIdentifier : nil,
                               resolvedPath: url.resolvingSymlinksInPath().path,
                               isApp: isApp, isDirectory: isDirectory, isPackage: isPackage,
                               modified: isApp ? (try? plist.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil)
    }
}

/// The installed apps, scanned off the main thread and read from memory by every Start menu. Opening a
/// menu only reads `snapshot`; until the first scan ends it is nil and the lists say "Loading…".
@MainActor
final class AppCatalog {
    static let shared = AppCatalog()
    /// Posted on the main thread when a scan found something different. Open lists reload.
    static let didChange = Notification.Name("WinstripeAppCatalogDidChange")
    static let handlerAddresses = ["https://example.com", "mailto:"]
    /// A menu opened this long after the last scan asks for a new one, in case an event was missed.
    private static let staleAfter: TimeInterval = 30

    private(set) var roots = AppCatalogRoots.standard
    private(set) var snapshot: AppCatalogSnapshot?
    private var scanner: (AppCatalogRoots, Set<String>, [String]) -> AppCatalogSnapshot = AppCatalogScanner.scan
    private let queue = DispatchQueue(label: "com.iboysoft.winstripe.app-catalog", qos: .userInitiated)
    private var scanning = false
    private var scanAgain = false
    private var lastScan: Date?
    private var wantedPaths = Set<String>()
    private var watcher: AppDirectoryWatcher?

    /// Offscreen fixtures have their own catalog and never wait for this one.
    var isReady: Bool { SnapshotFixture.isActive || snapshot != nil }

    /// Fills the cache shortly after launch and keeps it current.
    func start() {
        guard !SnapshotFixture.isActive, watcher == nil else { return }
        refresh()
        watch()
    }

    func watch(latency: TimeInterval = 2) {
        watcher = AppDirectoryWatcher(paths: roots.all.map(\.path), latency: latency) {
            DispatchQueue.main.async { MainActor.assumeIsolated { AppCatalog.shared.refresh() } }
        }
    }

    func stopWatching() { watcher = nil }

    func refreshIfStale() {
        guard let lastScan, Date().timeIntervalSince(lastScan) < Self.staleAfter else { return refresh() }
    }

    /// Starts a background scan. Never waits for it.
    func refresh() {
        guard !SnapshotFixture.isActive else { return }
        guard !scanning else { scanAgain = true; return }
        scanning = true
        let roots = roots, wanted = wantedPaths, scanner = scanner, addresses = Self.handlerAddresses
        queue.async {
            let result = autoreleasepool { scanner(roots, wanted, addresses) }
            DispatchQueue.main.async { MainActor.assumeIsolated { AppCatalog.shared.finish(result, roots: roots) } }
        }
    }

    private func finish(_ result: AppCatalogSnapshot, roots scannedRoots: AppCatalogRoots) {
        scanning = false
        lastScan = Date()
        defer {
            if scanAgain {
                scanAgain = false
                refresh()
            }
        }
        // Roots changed by the self-test while this scan ran; its result describes the old ones.
        guard scannedRoots == roots else { scanAgain = true; return }
        let previous = snapshot
        guard result != previous else { return }
        snapshot = result
        AppBundleIDIndex.shared.replace(result.byPath.mapValues(\.bundleID))
        for (path, entry) in result.byPath where entry.isApp {
            if let old = previous?.byPath[path], old.modified != entry.modified {
                AppIconCache.shared.reload(entry.url)
            } else {
                AppIconCache.shared.prewarm(entry.url)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func flatApps() -> [AppCatalogEntry] { snapshot?.flatApps(roots: roots) ?? [] }
    func deepApps() -> [AppCatalogEntry] { snapshot?.deepApps(roots: roots) ?? [] }
    func entries(in directory: URL) -> [AppCatalogEntry] { snapshot?.entries(in: directory) ?? [] }
    func defaultHandler(for address: String) -> URL? { snapshot?.defaultHandlers[address] }

    /// The entry of a known path. An unknown one is added by the next scan, which then reports a change.
    func entry(for url: URL) -> AppCatalogEntry? {
        if let entry = snapshot?.byPath[url.path] { return entry }
        if !SnapshotFixture.isActive, wantedPaths.insert(url.path).inserted { refresh() }
        return nil
    }

    func nameWithoutExtension(of url: URL) -> String {
        entry(for: url)?.nameWithoutExtension ?? url.lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// What `resolvingSymlinksInPath` gave when the scan ran, without touching the disk again.
    func resolvedPath(of url: URL) -> String { snapshot?.byPath[url.path]?.resolvedPath ?? url.path }

    /// `--app-catalog-selftest` points the catalog at its own folders and a scanner it can slow down.
    func configureForTesting(roots: AppCatalogRoots,
                             scanner: ((AppCatalogRoots, Set<String>, [String]) -> AppCatalogSnapshot)? = nil) {
        self.roots = roots
        self.scanner = scanner ?? AppCatalogScanner.scan
        snapshot = nil
        wantedPaths = []
        lastScan = nil
        AppBundleIDIndex.shared.replace([:])
    }

    var isScanning: Bool { scanning }
}

/// Rows draw icons up to 20pt, tiles up to 48pt; both at up to 2x.
private let smallIconPixels = 40
private let largeIconPixels = 96

/// Small icons drawn off the main thread. `icon(for:)` returns at once: the same image object every
/// time, which shows a placeholder until its bitmaps arrive and then draws them.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    /// Posted after new bitmaps arrive, at most once per `postDelay`. Open menus redraw.
    static let didUpdate = Notification.Name("WinstripeAppIconsDidUpdate")
    private static let postDelay: TimeInterval = 0.05

    private final class Bitmaps: @unchecked Sendable {
        var small: CGImage?
        var large: CGImage?
    }

    private var bitmaps: [String: Bitmaps] = [:]
    private var images: [String: NSImage] = [:]
    private var updatePending = false
    private let queue = DispatchQueue(label: "com.iboysoft.winstripe.app-icons", qos: .utility)

    func icon(for url: URL) -> NSImage {
        let path = url.path
        if let image = images[path] { return image }
        let target = Bitmaps()
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            Self.draw(target, in: rect)
            return true
        }
        // The drawing changes when the bitmaps arrive, so it must not be cached.
        image.cacheMode = .never
        images[path] = image
        bitmaps[path] = target
        load(path, into: target)
        return image
    }

    /// Queues the icon so that it is ready before a menu first shows it.
    func prewarm(_ url: URL) { _ = icon(for: url) }

    /// The app changed on disk: draw its icon again, into the images already handed out.
    func reload(_ url: URL) {
        if let target = bitmaps[url.path] { load(url.path, into: target) } else { prewarm(url) }
    }

    /// True once every icon asked for so far has its bitmaps.
    var isSettled: Bool { bitmaps.values.allSatisfy { $0.small != nil } }

    private func load(_ path: String, into target: Bitmaps) {
        queue.async {
            let result = Bitmaps()
            autoreleasepool {
                AppCatalogProbe.shared.recordIconLoad()
                let icon = NSWorkspace.shared.icon(forFile: path)
                result.small = Self.render(icon, pixels: smallIconPixels)
                result.large = Self.render(icon, pixels: largeIconPixels)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    target.small = result.small
                    target.large = result.large
                    AppIconCache.shared.scheduleUpdate()
                }
            }
        }
    }

    private func scheduleUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postDelay) {
            MainActor.assumeIsolated {
                AppIconCache.shared.updatePending = false
                NotificationCenter.default.post(name: Self.didUpdate, object: nil)
            }
        }
    }

    private nonisolated static func render(_ icon: NSImage, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private nonisolated static func draw(_ target: Bitmaps, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = abs(context.ctm.a) * rect.width
        guard let bitmap = scale <= CGFloat(smallIconPixels) ? target.small ?? target.large : target.large ?? target.small else {
            NSImage(systemSymbolName: "app", accessibilityDescription: nil)?
                .draw(in: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1), from: .zero, operation: .sourceOver, fraction: 0.35)
            return
        }
        context.interpolationQuality = .high
        context.draw(bitmap, in: rect)
    }
}

/// Reports changes under the application folders. Runs for the life of the app.
final class AppDirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.iboysoft.winstripe.app-watcher", qos: .utility)

    init(paths: [String], latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppDirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
