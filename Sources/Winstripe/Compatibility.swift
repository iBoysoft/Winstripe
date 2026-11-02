import Foundation

// Xcode 14.3 ships Swift 5.8, which has no `MainActor.assumeIsolated`. Its callers already run on the main
// thread, so calling the closure directly matches the check-free release behavior of the real one.
#if !compiler(>=5.9)
extension MainActor {
    static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        typealias Nonisolated = () throws -> T
        return try withoutActuallyEscaping(operation) { escapable in
            try unsafeBitCast(escapable, to: Nonisolated.self)()
        }
    }
}
#endif
