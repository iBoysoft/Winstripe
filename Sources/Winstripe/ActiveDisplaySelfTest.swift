import AppKit

/// `--active-display-selftest`: deterministic active-display routing with fake screens and bars.
@MainActor
enum ActiveDisplaySelfTest {
    static func run() -> Int {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        func screen(_ id: CGDirectDisplayID, _ frame: NSRect) -> ScreenInfo {
            ScreenInfo(id: id, frame: frame,
                       visibleFrame: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 25), scale: 1)
        }
        let a = screen(1, NSRect(x: 0, y: 0, width: 1200, height: 800))
        let b = screen(2, NSRect(x: 1200, y: 0, width: 1600, height: 900))
        let c = screen(3, NSRect(x: -900, y: 0, width: 900, height: 700))
        var screens = [a, b]
        var focused: ActiveDisplayFocusedWindow?
        var mouse = NSPoint(x: 100, y: 100)
        var menuOpen = false
        let scheduler = ActiveDisplayFakeScheduler()
        let bars = DisplayBarManager(screens: { screens }) { id, primary in
            let bar = TaskbarController(displayID: id)
            bar.followsPrimaryScreen = primary
            bar.screenProvider = { screens }
            bar.prepareForScreenTest()
            bar.applyScreenGeometry("active-test")
            return bar
        }
        let tracker = ActiveDisplayTracker(
            screens: { screens },
            focusedWindow: { focused },
            mouseLocation: { mouse },
            mainScreenID: { 1 },
            isBarMenuOpen: { menuOpen },
            scheduler: { delay, action in scheduler.schedule(delay: delay, action: action) },
            retarget: { id in
                guard bars.primary?.displayID != id else { return }
                bars.primary?.retarget(to: id)
            })
        bars.trackerForTesting = tracker

        bars.reconcile(allDisplays: false)
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [1], "single bar starts on screen A")

        focused = ActiveDisplayFocusedWindow(pid: 42, frame: NSRect(x: 1400, y: 120, width: 800, height: 500), coordinateSpace: .cocoa)
        tracker.event()
        scheduler.runAll()
        let movedWidth = bars.primary?.testPanel?.frame.width ?? 0
        check(bars.coveredDisplayIDs == [2] && movedWidth == 1600,
              "focus moves to screen B after debounce and spans it")

        let beforeRapid = bars.primary?.screenGeometryApplyCount ?? 0
        focused = ActiveDisplayFocusedWindow(pid: 42, frame: NSRect(x: 1500, y: 120, width: 500, height: 300), coordinateSpace: .cocoa)
        tracker.event()
        focused = ActiveDisplayFocusedWindow(pid: 42, frame: NSRect(x: 100, y: 120, width: 500, height: 300), coordinateSpace: .cocoa)
        tracker.event()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [1] && (bars.primary?.screenGeometryApplyCount ?? 0) == beforeRapid + 1,
              "rapid A to B to A coalesces to one retarget")

        focused = ActiveDisplayFocusedWindow(pid: getpid(), frame: b.frame, coordinateSpace: .cocoa)
        mouse = NSPoint(x: 1500, y: 100)
        tracker.event()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [2], "Winstripe focus is ignored")

        menuOpen = true
        focused = ActiveDisplayFocusedWindow(pid: 42, frame: a.frame, coordinateSpace: .cocoa)
        tracker.event()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [2], "open bar menu suppresses movement")
        menuOpen = false
        tracker.transientUIChanged()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [1], "bar moves after menu closes")

        focused = nil
        mouse = NSPoint(x: 1500, y: 200)
        tracker.event()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [2], "no focused window falls back to mouse screen")

        screens = [a]
        tracker.event()
        scheduler.runAll()
        let remainingPanelExists = bars.primary?.testPanel != nil
        check(bars.coveredDisplayIDs == [1] && remainingPanelExists,
              "removed focused display falls back without an orphan")

        screens = [a, b, c]
        bars.reconcile(allDisplays: true)
        check(Set(bars.coveredDisplayIDs) == [1, 2, 3], "all-displays mode keeps one bar per display")
        let onIDs = bars.coveredDisplayIDs
        focused = ActiveDisplayFocusedWindow(pid: 42, frame: b.frame, coordinateSpace: .cocoa)
        tracker.event()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == onIDs, "all-displays mode does not retarget bars")

        bars.reconcile(allDisplays: false)
        tracker.event()
        scheduler.runAll()
        check(bars.coveredDisplayIDs == [2], "toggling off resumes active-display following")

        bars.stopAll()
        print("active-display-selftest failures=\(failures.count)")
        return failures.isEmpty ? 0 : 1
    }
}
