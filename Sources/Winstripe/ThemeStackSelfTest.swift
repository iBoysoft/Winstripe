import Foundation

/// Theme decoding must survive small stacks. GCD workers get 512 KB; the 2026-10-17 crash was the
/// built-in prewarm overflowing one while decoding ThemeConfig. A stack overflow kills the process,
/// so any failure here is a crash or a non-zero exit.
enum ThemeStackSelfTest {
    static let workerStack = 512 * 1024

    static func themeIDs() -> [String] {
        ThemeKind.allCases.map(\.id) + UserThemeCatalog.records().0.map(\.id)
    }

    /// `--theme-stack-selftest`
    static func run() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let ids = themeIDs()

        // 1. Every theme decodes inline (no hop) on a 512 KB thread.
        let inline = runOnThread(stackSize: workerStack) {
            ThemeDecodeThread.withInlineDecoding { loadAll(ids) }
        }
        check(inline, "\(ids.count) themes decode inline on a 512 KB thread")

        // 2. Small-stack callers hop to the 8 MB decode thread.
        let hopped = runOnThread(stackSize: 128 * 1024) {
            !ThemeDecodeThread.currentThreadIsSafe && ((try? ThemeDecodeThread.run {
                pthread_get_stacksize_np(pthread_self()) >= ThemeDecodeThread.stackSize
            }) ?? false) && loadAll(ids)
        }
        check(hopped, "128 KB caller decodes all themes via the 8 MB decode thread")

        // 3. The cache path from a GCD utility worker (the crashing path).
        let gcd = DispatchSemaphore(value: 0)
        let gcdBox = ResultBox()
        DispatchQueue.global(qos: .utility).async {
            let cache = ThemeResolutionCache.shared
            gcdBox.value = ids.allSatisfy { (try? cache.loadSync($0)) != nil }
            gcd.signal()
        }
        gcd.wait()
        check(gcdBox.value, "ThemeResolutionCache.loadSync on a GCD utility worker")

        // 4. Hostile nesting is rejected by depth, not by overflowing the stack.
        let deep = runOnThread(stackSize: workerStack) {
            ThemeDecodeThread.withInlineDecoding { rejectsDeepNesting() }
        }
        check(deep, "10000-level nested user theme rejected on a 512 KB thread")

        print("theme-stack-selftest failures=\(failures)")
        return failures == 0 ? 0 : 1
    }

    /// `--theme-stack-probe KB`: load every theme once, inline, on a KB-sized thread.
    static func probe(kilobytes: Int) -> Int {
        let ids = themeIDs()
        let ok = runOnThread(stackSize: kilobytes * 1024) {
            ThemeDecodeThread.withInlineDecoding { loadAll(ids) }
        }
        print("probe \(kilobytes)KB themes=\(ids.count) ok=\(ok)")
        return ok ? 0 : 1
    }

    private static func loadAll(_ ids: [String]) -> Bool {
        ids.allSatisfy { id in
            guard let result = try? ThemeLoader().loadForID(id, userDirectory: ThemePaths.userThemesDirectory) else { return false }
            return result.succeeded
        }
    }

    private static func rejectsDeepNesting() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-stack-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("deep.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "{\"$schema\":\"winstripe-theme/1\",\"id\":\"deep\",\"x\":" + String(repeating: "[", count: 10000)
            + String(repeating: "]", count: 10000) + "}"
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? Data(body.utf8).write(to: file)) != nil else { return false }
        return !ThemeLoader().load(file.path, user: true).succeeded
    }

    static func runOnThread(stackSize: Int, _ body: @escaping @Sendable () -> Bool) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let thread = Thread { box.value = body(); done.signal() }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable { var value = false }
}
