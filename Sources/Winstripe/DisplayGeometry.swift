import AppKit

extension Notification.Name {
    /// Posted on the main queue after CoreGraphics finishes a display reconfiguration
    /// (mode/resolution, scale, arrangement, add/remove).
    static let winstripeDisplaysReconfigured = Notification.Name("WinstripeDisplaysReconfigured")
}

/// A value snapshot of one screen, so geometry decisions can be tested without real displays.
struct ScreenInfo: Equatable {
    var id: CGDirectDisplayID
    var frame: NSRect
    var visibleFrame: NSRect
    var scale: CGFloat
}

@MainActor
enum DisplayGeometry {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func info(_ screen: NSScreen) -> ScreenInfo? {
        displayID(of: screen).map {
            ScreenInfo(id: $0, frame: screen.frame, visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor)
        }
    }

    /// `NSScreen.screens[0]` is the primary (menu-bar) screen.
    static func current() -> [ScreenInfo] { NSScreen.screens.compactMap(info) }

    static func screen(id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// The tracked display if it still exists. Otherwise, when `followPrimary` is set, the primary
    /// screen: headless and virtual displays (and some mode changes) re-enumerate the display under a
    /// new id, and the old id never comes back.
    static func resolve(tracked: CGDirectDisplayID?, screens: [ScreenInfo], followPrimary: Bool) -> ScreenInfo? {
        if let tracked, let match = screens.first(where: { $0.id == tracked }) { return match }
        if tracked != nil && !followPrimary { return nil }
        return screens.first
    }
}

/// Bridges CGDisplayRegisterReconfigurationCallback to a main-queue notification. Registered once.
enum DisplayReconfigurationMonitor {
    private static var registered = false

    @MainActor static func start() {
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // Each display reports twice; the begin phase precedes any geometry change.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .winstripeDisplaysReconfigured, object: nil)
            }
        }, nil)
    }
}
