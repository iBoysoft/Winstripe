import AppKit

/// `--all-displays-selftest`: "Show taskbar on all displays" against fake screens and real
/// (offscreen) bar panels: toggle on/off, connect, disconnect, resolution change, re-enumerated
/// display ids, primary display removal, and idempotent reconciles.
@MainActor
enum AllDisplaysSelfTest {
    static func run() -> Int {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        func screen(_ id: CGDirectDisplayID, _ f: NSRect) -> ScreenInfo {
            ScreenInfo(id: id, frame: f, visibleFrame: NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height - 25), scale: 1)
        }
        let a = screen(1, NSRect(x: 0, y: 0, width: 1512, height: 945))
        let b = screen(2, NSRect(x: 1512, y: -135, width: 1920, height: 1080))
        let c = screen(3, NSRect(x: -1280, y: 0, width: 1280, height: 800))
        var screens = [a]
        var focused: ActiveDisplayFocusedWindow?
        let scheduler = ActiveDisplayFakeScheduler()
        var made: [TaskbarController] = []
        let bars = DisplayBarManager(screens: { screens }) { id, primary in
            let t = TaskbarController(displayID: id)
            t.followsPrimaryScreen = primary
            t.screenProvider = { screens }
            t.prepareForScreenTest()
            t.applyScreenGeometry("test")
            made.append(t)
            return t
        }
        let tracker = ActiveDisplayTracker(
            screens: { screens },
            focusedWindow: { focused },
            mouseLocation: { NSPoint(x: 100, y: 100) },
            mainScreenID: { 1 },
            scheduler: { delay, action in scheduler.schedule(delay: delay, action: action) },
            retarget: { id in
                guard bars.primary?.displayID != id else { return }
                bars.primary?.retarget(to: id)
            })
        bars.trackerForTesting = tracker
        func live() -> [TaskbarController] { bars.controllers }
        func ids() -> [CGDirectDisplayID] { live().compactMap(\.displayID) }
        func barX(_ id: CGDirectDisplayID) -> CGFloat? {
            live().first { $0.displayID == id }?.testPanel?.frame.minX
        }
        func width(_ id: CGDirectDisplayID) -> CGFloat? {
            live().first { $0.displayID == id }?.testPanel?.frame.width
        }
        func stoppedAreGone() -> Bool {
            made.filter { t in !live().contains { $0 === t } }.allSatisfy { $0.isStopped && $0.testPanel?.isVisible != true }
        }
        func refresh() { live().forEach { $0.applyScreenGeometry("test") } }

        bars.reconcile(allDisplays: false)
        scheduler.runAll()
        check(ids() == [1], "off, one display: one bar on it (got \(ids()))")

        screens = [a, b]
        focused = ActiveDisplayFocusedWindow(pid: 42, frame: b.frame, coordinateSpace: .cocoa)
        bars.reconcile(allDisplays: false)
        scheduler.runAll()
        check(ids() == [2], "off, two displays: one bar follows the active display (got \(ids()))")

        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [1, 2], "toggle on: a bar on every display (got \(ids()))")
        check(barX(2) == 1512 && width(2) == 1920, "second bar spans the external display (x=\(barX(2) ?? -1) w=\(width(2) ?? -1))")
        let count = made.count
        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [1, 2] && made.count == count, "reconcile is idempotent")

        bars.reconcile(allDisplays: false)
        scheduler.runAll()
        check(ids() == [2] && stoppedAreGone(), "toggle off: extra bars torn down (got \(ids()))")
        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [1, 2], "toggle on again (got \(ids()))")

        screens = [a, b, c]
        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [1, 2, 3] && ids().count == 3, "connect: new display gets a bar (got \(ids()))")
        check(barX(3) == -1280, "third bar on the left display (x=\(barX(3) ?? -1))")

        screens = [a, c]
        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [1, 3] && ids().count == 2 && stoppedAreGone(), "disconnect: its bar is removed (got \(ids()))")

        screens = [a, screen(3, NSRect(x: -1920, y: 0, width: 1920, height: 1080))]
        refresh()
        bars.reconcile(allDisplays: true)
        check(barX(3) == -1920 && width(3) == 1920, "resolution change: bar follows (x=\(barX(3) ?? -1) w=\(width(3) ?? -1))")

        screens = [a, screen(9, NSRect(x: -1920, y: 0, width: 1920, height: 1080))]
        let before = made.count
        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [1, 9] && ids().count == 2 && made.count == before, "re-enumerated id: bar reused, no duplicate (got \(ids()))")

        screens = [screen(9, NSRect(x: 0, y: 0, width: 1920, height: 1080))]
        refresh()
        bars.reconcile(allDisplays: true)
        check(ids() == [9] && stoppedAreGone(), "primary display removed: one bar, no duplicate (got \(ids()))")

        screens = [screen(9, NSRect(x: 0, y: 0, width: 1920, height: 1080)), b]
        bars.reconcile(allDisplays: true)
        check(Set(ids()) == [9, 2], "reconnect: bar returns (got \(ids()))")
        bars.reconcile(allDisplays: false)
        check(ids().count == 1 && stoppedAreGone(), "final toggle off (got \(ids()))")

        bars.stopAll()
        print("all-displays-selftest failures=\(failures.count)")
        return failures.isEmpty ? 0 : 1
    }
}
