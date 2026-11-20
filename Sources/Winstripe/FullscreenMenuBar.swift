import AppKit

/// WindowServer tracks the alpha override against its client connection and clears it on
/// disconnect, including SIGKILL. A nonzero Space ID scopes it to that Space's menu bar.
/// Passing -1 releases the override so the system's current visibility policy takes effect.
private struct MenuBarAPI {
    typealias Connection = @convention(c) () -> Int32
    typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SetAlpha = @convention(c) (Int32, UInt64, Float) -> Void

    let connection: Connection
    let copySpaces: CopySpaces
    let setAlpha: SetAlpha

    init?() {
        let loadedImages = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(loadedImages, "SLSMainConnectionID"),
              let spaces = dlsym(loadedImages, "SLSCopyManagedDisplaySpaces"),
              let alpha = dlsym(loadedImages, "SLSSetMenuBarSystemOverrideAlpha") else { return nil }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        copySpaces = unsafeBitCast(spaces, to: CopySpaces.self)
        setAlpha = unsafeBitCast(alpha, to: SetAlpha.self)
    }
}

@MainActor
final class FullscreenMenuBar {
    private static let api = MenuBarAPI()
    static var isSupported: Bool { api != nil }
    private var hiddenSpaces = Set<UInt64>()

    func update(enabled: Bool) {
        guard enabled || !hiddenSpaces.isEmpty, !Prefs.isIsolated, let api = Self.api else { return }
        let connection = api.connection()
        guard connection != 0 else { return }
        var desired = Set<UInt64>()
        if enabled, let spaces = api.copySpaces(connection)?.takeRetainedValue() as? [[String: Any]] {
            // Native fullscreen includes Split View and apps on an unfocused display.
            // A borderless game can also cover an ordinary desktop Space.
            var frames: [String: CGRect] = [:]
            for screen in NSScreen.screens {
                guard let id = DisplayGeometry.displayID(of: screen),
                      let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
                let bounds = CGDisplayBounds(id)
                frames[CFUUIDCreateString(nil, uuid) as String] = bounds
                if id == CGMainDisplayID() { frames["Main"] = bounds }
            }
            var windows: [[String: Any]]?
            desired = Self.fullscreenSpaces(spaces) { display in
                guard let frame = frames[display] else { return false }
                if windows == nil {
                    windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                         kCGNullWindowID) as? [[String: Any]] ?? []
                }
                return FullscreenDetector.frontWindowCovers(screenFrame: frame, info: windows ?? [])
            }
        }
        reconcile(desired) { space, alpha in api.setAlpha(connection, space, alpha) }
    }

    static func fullscreenSpaces(_ displays: [[String: Any]], coveringWindow: (String) -> Bool) -> Set<UInt64> {
        var spaces = Set<UInt64>()
        var visibleSpaces = Set<UInt64>()
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value, id != 0,
                  let type = current["type"] as? Int else { continue }
            if type == 4 {
                spaces.insert(id)
            } else if type == 0, let name = display["Display Identifier"] as? String, coveringWindow(name) {
                spaces.insert(id)
            } else {
                visibleSpaces.insert(id)
            }
        }
        // A shared Space has only one override. Preserve the menu bar if a desktop needs it.
        return spaces.subtracting(visibleSpaces)
    }

    func reconcile(_ desired: Set<UInt64>, setAlpha: (UInt64, Float) -> Void) {
        for id in hiddenSpaces.subtracting(desired) { setAlpha(id, -1) }
        for id in desired.subtracting(hiddenSpaces) { setAlpha(id, 0) }
        hiddenSpaces = desired
    }
}
