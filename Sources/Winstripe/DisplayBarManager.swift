import AppKit

/// Owns one taskbar per display. When "Show taskbar on all displays" is off, the single bar
/// follows the display containing the active app's focused window. With it on, every display
/// keeps its own bar.
@MainActor
final class DisplayBarManager {
    typealias Factory = @MainActor (_ displayID: CGDirectDisplayID?, _ primary: Bool) -> TaskbarController

    private let screens: @MainActor () -> [ScreenInfo]
    private let factory: Factory
    private(set) var controllers: [TaskbarController] = []
    private var activeTracker: ActiveDisplayTracker?
    private var allDisplaysMode = false
    var trackerForTesting: ActiveDisplayTracker?

    init(screens: @escaping @MainActor () -> [ScreenInfo] = { DisplayGeometry.current() }, factory: @escaping Factory) {
        self.screens = screens
        self.factory = factory
    }

    var primary: TaskbarController? { controllers.first }

    /// Display ids covered by a bar, primary first.
    var coveredDisplayIDs: [CGDirectDisplayID] { controllers.compactMap(\.displayID) }

    func reconcile(allDisplays: Bool) {
        allDisplaysMode = allDisplays
        if allDisplays {
            stopActiveTracker()
        }
        let ids = screens().map(\.id)
        if controllers.isEmpty {
            controllers.append(factory(ids.first, true))
        }
        guard let primary = controllers.first else { return }
        primary.followsPrimaryScreen = true
        // Resolve the primary first so it claims its display before any secondary does.
        var covered = Set<CGDirectDisplayID>()
        if let id = primary.targetScreenInfo()?.id { covered.insert(id) }

        var kept: [TaskbarController] = [primary]
        var orphans: [TaskbarController] = []
        for c in controllers.dropFirst() {
            if allDisplays, let id = c.displayID, ids.contains(id), !covered.contains(id) {
                covered.insert(id)
                kept.append(c)
            } else {
                orphans.append(c)
            }
        }
        if allDisplays {
            for id in ids where !covered.contains(id) {
                covered.insert(id)
                if let reuse = orphans.popLast() {
                    reuse.retarget(to: id)
                    kept.append(reuse)
                } else {
                    kept.append(factory(id, false))
                }
            }
        }
        orphans.forEach { $0.stop() }
        controllers = kept
        if allDisplays {
            controllers.forEach { $0.onTransientUIChanged = nil }
        } else {
            startActiveTracker()
        }
    }

    func stopAll() {
        stopActiveTracker()
        controllers.forEach { $0.stop() }
        controllers.removeAll()
    }

    private func startActiveTracker() {
        guard !allDisplaysMode, let primary else { return }
        if let activeTracker = trackerForTesting {
            self.activeTracker = activeTracker
            primary.onTransientUIChanged = { [weak activeTracker] in activeTracker?.transientUIChanged() }
            activeTracker.start()
            return
        }
        if activeTracker == nil {
            let tracker = ActiveDisplayTracker(
                screens: screens,
                focusedWindow: { ActiveDisplayWindowResolver.focusedWindow() },
                isBarMenuOpen: { [weak self] in
                    guard let self else { return false }
                    for controller in self.controllers where controller.isBarMenuOpen { return true }
                    return false
                },
                retarget: { [weak self] id in
                    guard let self, !self.allDisplaysMode, self.controllers.count == 1,
                          self.primary?.displayID != id else { return }
                    self.primary?.retarget(to: id)
                })
            activeTracker = tracker
        }
        primary.onTransientUIChanged = { [weak self] in self?.activeTracker?.transientUIChanged() }
        activeTracker?.start()
    }

    private func stopActiveTracker() {
        activeTracker?.stop()
        activeTracker = nil
        controllers.forEach { $0.onTransientUIChanged = nil }
    }
}
