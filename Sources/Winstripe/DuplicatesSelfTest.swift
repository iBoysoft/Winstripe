import AppKit

/// `--duplicates-selftest`: shared icons, duplicate window ids and duplicate pins
/// must never trap (regression for the uniqueKeysWithValues crash in
/// AeroDrawing.prewarmAverageColors).
@MainActor
enum DuplicatesSelfTest {
    static func run() -> Int {
        _ = NSApplication.shared
        var failures: [String] = []
        let shared = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let other = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }

        // 1. The crashing call: the same NSImage object several times.
        var done = false
        AeroDrawing.prewarmAverageColors([shared, shared, other, shared]) { done = true }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !done { failures.append("prewarm-completion") }

        // 2. firstWins keeps the first value on duplicates.
        let d = Dictionary(firstWins: [(1, "a"), (1, "b"), (2, "c")])
        if d[1] != "a" || d.count != 2 { failures.append("firstWins") }

        // 3. Real taskbar views: two apps sharing one icon, an app with duplicate
        //    window ids (one minimized), duplicate pins, Vista + Win7 (aero prewarm).
        let dupWindows = [
            WindowEntry(id: 42, title: "One", minimized: false, frame: .zero, element: nil, firstSeen: 1, idSource: "test"),
            WindowEntry(id: 42, title: "One again", minimized: true, frame: .zero, element: nil, firstSeen: 2, idSource: "test"),
            WindowEntry(id: 43, title: "Two", minimized: true, frame: .zero, element: nil, firstSeen: 3, idSource: "test")
        ]
        let apps = [
            AppEntry(pid: 501, name: "Shared A", icon: shared, windowCount: 3, isHidden: false, windows: dupWindows,
                     bundleID: "test.shared", path: "/Applications/Safari.app"),
            AppEntry(pid: 502, name: "Shared B", icon: shared, windowCount: 1, isHidden: false,
                     bundleID: "test.shared", path: "/Applications/Safari.app"),
            AppEntry(pid: 503, name: "Other", icon: other, windowCount: 0, isHidden: false)
        ]
        let pin = PinnedApp(bundleID: "test.shared", path: "/Applications/Safari.app")
        for theme in [ThemeKind.vista, .win7, .winXP, .win8, .win11] {
            for grouping in TaskbarGrouping.allCases {
                var s = TaskbarSettings()
                s.theme = theme
                s.taskbarGrouping = grouping
                let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 1200, height: TaskbarView.thickness(for: s)))
                view.isPreview = true
                view.settings = s
                view.apps = apps
                view.pinnedApps = [pin, pin]
                view.taskOrder = ["test.shared", "test.shared"]
                view.activePID = 501
                view.activeWindowID = 42
                view.reload()
                view.layoutSubtreeIfNeeded()
                var prewarmed = false
                AeroDrawing.prewarmAverageColors(view.aeroPrewarmIcons) { prewarmed = true }
                let until = Date().addingTimeInterval(5)
                while !prewarmed && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                if !prewarmed { failures.append("prewarm-\(theme.id)-\(grouping.rawValue)") }
                if view.aeroPrewarmIcons.filter({ $0 === shared }).count < 2 && grouping == .neverCombine {
                    failures.append("fixture-\(theme.id): expected shared icon on several buttons")
                }
            }
        }
        if failures.isEmpty {
            print("PASS duplicates selftest")
            return 0
        }
        print("FAIL duplicates selftest: \(failures.joined(separator: ", "))")
        return 1
    }
}
