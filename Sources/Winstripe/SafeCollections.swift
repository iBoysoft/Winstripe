import Foundation

extension Dictionary {
    /// Like `init(uniqueKeysWithValues:)` but never traps: on a duplicate key the
    /// first value wins. Runtime data (shared app icons, window ids, tray paths,
    /// tile keys) can legitimately repeat, so app code must not use the trapping form.
    init<S: Sequence>(firstWins pairs: S) where S.Element == (Key, Value) {
        self.init(pairs, uniquingKeysWith: { first, _ in first })
    }
}
