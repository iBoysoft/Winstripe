import Foundation

/// Theme JSON decoding runs on threads with a large stack. GCD worker threads have 512 KB stacks,
/// which synthesized Codable initializers for the nested theme model can exceed (crash report
/// 2026-10-17: "Thread stack size exceeded" in ThemeButtons.init(from:) under prewarmBuiltIns()).
/// Work submitted here runs on one serial 8 MB thread; callers already on a large stack (main
/// thread, this worker) run inline.
enum ThemeDecodeThread {
    static let stackSize = 8 << 20
    private static let inlineKey = "Winstripe.ThemeDecodeThread.inline"
    private static let worker = Worker()

    /// True when the current thread may decode themes without hopping.
    static var currentThreadIsSafe: Bool {
        if Thread.isMainThread || Thread.current === worker.thread { return true }
        if Thread.current.threadDictionary[inlineKey] != nil { return true }
        return pthread_get_stacksize_np(pthread_self()) >= 4 << 20
    }

    /// Runs `body` on a large stack and returns its result, blocking the caller if it has to hop.
    static func run<T>(_ body: @escaping () throws -> T) throws -> T {
        if currentThreadIsSafe { return try body() }
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        worker.submit {
            box.result = Result { try body() }
            done.signal()
        }
        done.wait()
        guard let result = box.result else { throw DecodeThreadError.didNotRun }
        return try result.get()
    }

    /// Queues `body` on the decode thread without waiting.
    static func async(_ body: @escaping () -> Void) { worker.submit(body) }

    /// Test hook: decode inline on the current (possibly small) stack to measure stack use.
    static func withInlineDecoding<T>(_ body: () throws -> T) rethrows -> T {
        Thread.current.threadDictionary[inlineKey] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: inlineKey) }
        return try body()
    }

    enum DecodeThreadError: Error { case didNotRun }

    private final class Box<T>: @unchecked Sendable { var result: Result<T, Error>? }

    private final class Worker: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [() -> Void] = []
        private let available = DispatchSemaphore(value: 0)
        private(set) var thread: Thread?

        init() {
            let t = Thread { [unowned self] in self.loop() }
            t.stackSize = ThemeDecodeThread.stackSize
            t.name = "Winstripe.ThemeDecode"
            t.qualityOfService = .userInitiated
            thread = t
            t.start()
        }

        func submit(_ job: @escaping () -> Void) {
            lock.lock()
            jobs.append(job)
            lock.unlock()
            available.signal()
        }

        private func loop() {
            while true {
                available.wait()
                lock.lock()
                let job = jobs.isEmpty ? nil : jobs.removeFirst()
                lock.unlock()
                if let job { autoreleasepool { job() } }
            }
        }
    }
}
