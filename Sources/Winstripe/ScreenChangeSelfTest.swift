import AppKit

/// Simulates screen reconfigurations against a real (offscreen) taskbar panel:
/// resolution change, re-enumerated display id, moved origin, vertical edges,
/// auto-hide, scale change, no screens, and debouncing.
@MainActor
enum ScreenChangeSelfTest {
    static func run() -> Int {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        func near(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        func screen(_ id: CGDirectDisplayID, _ f: NSRect, menuBar: CGFloat = 25, scale: CGFloat = 1) -> ScreenInfo {
            ScreenInfo(id: id, frame: f, visibleFrame: NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height - menuBar), scale: scale)
        }

        // Pure resolution rules.
        let a = screen(1, NSRect(x: 0, y: 0, width: 1920, height: 1080)), b = screen(2, NSRect(x: 1920, y: 0, width: 1280, height: 800))
        check(DisplayGeometry.resolve(tracked: 2, screens: [a, b], followPrimary: true) == b, "resolve keeps tracked display")
        check(DisplayGeometry.resolve(tracked: 9, screens: [a, b], followPrimary: true) == a, "resolve follows primary when id vanishes")
        check(DisplayGeometry.resolve(tracked: 9, screens: [a, b], followPrimary: false) == nil, "secondary bar does not jump to primary")
        check(DisplayGeometry.resolve(tracked: nil, screens: [], followPrimary: true) == nil, "no screens")

        var screens = [a]
        let c = TaskbarController(displayID: 1)
        c.screenProvider = { screens }
        c.prepareForScreenTest()
        guard let panel = c.testPanel else { print("FAIL screen-change selftest: no panel"); return 1 }
        let store = SettingsStore.shared
        store.mutate { $0.edge = .bottom; $0.autoHide = false }
        c.applyScreenGeometry("test")
        let h = panel.frame.height
        check(h > 0, "bar has thickness")
        check(near(panel.frame, NSRect(x: 0, y: 0, width: 1920, height: h)), "bottom bar spans 1920: \(panel.frame)")

        // Resolution change on the same display.
        screens = [screen(1, NSRect(x: 0, y: 0, width: 1280, height: 720))]
        c.applyScreenGeometry("test")
        check(near(panel.frame, NSRect(x: 0, y: 0, width: 1280, height: h)), "bottom bar follows 1280x720: \(panel.frame)")

        // Display re-enumerated under a new id at a new size (headless Mac mini behaviour).
        screens = [screen(14, NSRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2)]
        c.applyScreenGeometry("test")
        check(c.displayID == 14, "retargets to new display id (got \(c.displayID.map(String.init) ?? "nil"))")
        check(near(panel.frame, NSRect(x: 0, y: 0, width: 2560, height: h)), "bar spans re-enumerated 2560: \(panel.frame)")
        check(c.testViewLayerScale == nil || c.testViewLayerScale == 2, "layer scale follows backing 2x (got \(c.testViewLayerScale ?? 0))")

        // Origin moves (arrangement change).
        screens = [screen(14, NSRect(x: -1280, y: 200, width: 1280, height: 800))]
        c.applyScreenGeometry("test")
        check(near(panel.frame, NSRect(x: -1280, y: 200, width: 1280, height: h)), "bar follows moved origin: \(panel.frame)")

        // Vertical edges use the full height below the menu bar.
        store.mutate { $0.edge = .left }
        c.applyScreenGeometry("test")
        check(abs(panel.frame.minX + 1280) < 0.5 && abs(panel.frame.minY - 200) < 0.5 && abs(panel.frame.height - 775) < 0.5,
              "left bar spans moved screen height: \(panel.frame)")
        store.mutate { $0.edge = .right }
        screens = [screen(14, NSRect(x: 0, y: 0, width: 1600, height: 900))]
        c.applyScreenGeometry("test")
        check(abs(panel.frame.maxX - 1600) < 0.5 && abs(panel.frame.height - 875) < 0.5, "right bar after resize: \(panel.frame)")

        // Auto-hide position is computed against the new screen.
        store.mutate { $0.edge = .bottom }
        let hidden = TaskbarController.frame(settings: store.current, screenFrame: screens[0].frame,
                                             visibleFrame: screens[0].visibleFrame, hidden: true)
        check(near(hidden, NSRect(x: 0, y: -h, width: 1600, height: h)), "auto-hide frame below new screen: \(hidden)")

        // No screens mid-reconfiguration keeps the last good frame instead of a placeholder.
        c.applyScreenGeometry("test")
        let good = panel.frame
        screens = []
        c.applyScreenGeometry("test")
        check(near(panel.frame, good), "keeps last frame with no screens: \(panel.frame)")

        // Debounce: a burst of notifications applies once.
        screens = [screen(14, NSRect(x: 0, y: 0, width: 1440, height: 900))]
        let before = c.screenGeometryApplyCount
        for _ in 0..<6 { c.scheduleScreenGeometryUpdate("burst", delay: 0.05) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(c.screenGeometryApplyCount - before == 1, "burst coalesced to 1 apply (got \(c.screenGeometryApplyCount - before))")
        check(near(panel.frame, NSRect(x: 0, y: 0, width: 1440, height: h)), "debounced apply uses latest screen: \(panel.frame)")

        // Secondary bar whose display vanished hides instead of covering the primary.
        let secondary = TaskbarController(displayID: 2)
        secondary.followsPrimaryScreen = false
        var secondaryScreens = [a, b]
        secondary.screenProvider = { secondaryScreens }
        secondary.prepareForScreenTest()
        secondary.applyScreenGeometry("test")
        check(abs((secondary.testPanel?.frame.minX ?? 0) - 1920) < 0.5, "secondary bar on second display")
        secondaryScreens = [a]
        secondary.applyScreenGeometry("test")
        check(secondary.testPanel?.isVisible == false, "secondary bar hides when its display is removed")

        if failures.isEmpty {
            print("PASS screen-change selftest")
            return 0
        }
        failures.forEach { print("FAIL screen-change selftest: \($0)") }
        return 1
    }
}
