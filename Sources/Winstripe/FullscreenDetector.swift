import AppKit

enum TaskbarSpace: Equatable {
    case desktop
    case covered(display: CGDirectDisplayID, owner: pid_t)
    case fullscreen(display: CGDirectDisplayID, space: UInt64)

    var display: CGDirectDisplayID? {
        switch self {
        case .desktop: return nil
        case .covered(let display, _), .fullscreen(let display, _): return display
        }
    }
}

enum FullscreenDetector {
    // AppKit announces Space changes but doesn't expose the active Space's type.
    // Read WindowServer's per-display record, including when Split View or another app has focus.
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let readSpaces: (() -> [[String: Any]]?)? = {
        let scope = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(scope, "CGSMainConnectionID"),
              let copy = dlsym(scope, "CGSCopyManagedDisplaySpaces") else { return nil }
        let mainConnection = unsafeBitCast(connection, to: Connection.self)
        let copySpaces = unsafeBitCast(copy, to: CopySpaces.self)
        return { copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] }
    }()

    static func activeSpace(on display: CGDirectDisplayID) -> TaskbarSpace? {
        guard let records = readSpaces?(),
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return activeSpace(in: records, display: display, uuid: CFUUIDCreateString(nil, uuid) as String,
                           isMain: display == CGMainDisplayID())
    }

    static func activeSpace(in records: [[String: Any]], display: CGDirectDisplayID,
                            uuid: String, isMain: Bool) -> TaskbarSpace? {
        let record = records.first { entry in
            guard let name = entry["Display Identifier"] as? String else { return false }
            return name.caseInsensitiveCompare(uuid) == .orderedSame || (isMain && name == "Main")
        }
        guard let current = record?["Current Space"] as? [String: Any],
              let type = current["type"] as? NSNumber else { return nil }
        guard type.intValue == 4 else { return .desktop }
        guard let id = current["ManagedSpaceID"] as? NSNumber else { return nil }
        return .fullscreen(display: display, space: id.uint64Value)
    }

    static func taskbarSpace(native: TaskbarSpace?, display: CGDirectDisplayID, bounds: CGRect,
                             frontmostPID: pid_t?, previous: TaskbarSpace,
                             windows: @autoclosure () -> [[String: Any]]?,
                             axFullscreen: WindowTracker.FullscreenWindows) -> TaskbarSpace? {
        if case .fullscreen = native { return native }
        guard var pid = frontmostPID else { return nil }
        if pid == getpid() {
            // While our UI has focus, recheck the app underneath it.
            guard case .covered(display, let owner) = previous else { return native }
            pid = owner
        }
        guard let info = windows(), !bounds.isEmpty else { return nil }
        let covered = info.contains { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return false }
            if let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { return false }
            let dict = entry[kCGWindowBounds as String] as? NSDictionary
            let frame = dict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            if let frame, frame.intersection(bounds).isEmpty { return false }
            if let id = entry[kCGWindowNumber as String] as? NSNumber,
               let axFrame = axFullscreen[pid]?[id.uint32Value], matches(axFrame, bounds) { return true }
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0, let frame else { return false }
            return matches(frame, bounds)
        }
        guard covered else { return native }
        if native == nil, case .fullscreen(display, _) = previous { return previous }
        return .covered(display: display, owner: pid)
    }

    private static func matches(_ frame: CGRect, _ bounds: CGRect) -> Bool {
        abs(frame.minX - bounds.minX) < 0.5 && abs(frame.minY - bounds.minY) < 0.5 &&
            abs(frame.width - bounds.width) < 0.5 && abs(frame.height - bounds.height) < 0.5
    }
}

struct FullscreenTaskbarReveal {
    private(set) var space = TaskbarSpace.desktop
    private var lastInside: TimeInterval?
    private var missingSince: TimeInterval?
    var isFullscreen: Bool { space != .desktop }
    var isHidden: Bool { isFullscreen && lastInside == nil }

    func desktopBarHidden(autoHidden: Bool) -> Bool { !isFullscreen && autoHidden }

    func needsMousePolling(autoHide: Bool, showPreviews: Bool) -> Bool {
        isFullscreen || autoHide || showPreviews
    }

    mutating func observe(_ observation: TaskbarSpace?, display: CGDirectDisplayID, now: TimeInterval) {
        if let observation {
            missingSince = nil
            move(to: observation)
        } else {
            // Bridge a short WindowServer transition, then resume ordinary desktop behavior.
            let since = missingSince ?? now
            missingSince = since
            if space.display != display || now - since >= 1 {
                move(to: .desktop)
            }
        }
    }

    mutating func move(to newSpace: TaskbarSpace) {
        guard space != newSpace else { return }
        space = newSpace
        lastInside = nil
    }

    mutating func poll(mouse: NSPoint, screens: [ScreenInfo], edge: TaskbarEdge, interacting: Bool,
                       now: TimeInterval) {
        guard let display = space.display else { return }
        if (!isHidden && interacting) || Self.atEdge(mouse, of: display, screens: screens, edge: edge) {
            lastInside = now
        } else if let lastInside, now - lastInside >= 0.8 {
            self.lastInside = nil
        }
    }

    private static func atEdge(_ mouse: NSPoint, of display: CGDirectDisplayID,
                               screens: [ScreenInfo], edge: TaskbarEdge) -> Bool {
        // AppKit assigns shared edges to a single screen. Also accept an exact outer
        // boundary (e.g. y == 0 on the bottom display) when no neighbor owns it.
        let hit = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens.first {
            ($0.frame.minX...$0.frame.maxX).contains(mouse.x) && ($0.frame.minY...$0.frame.maxY).contains(mouse.y)
        }
        guard let hit, hit.id == display else { return false }
        switch edge {
        case .bottom: return mouse.y <= hit.frame.minY + 2
        case .top:    return mouse.y >= hit.frame.maxY - 2
        case .left:   return mouse.x <= hit.frame.minX + 2
        case .right:  return mouse.x >= hit.frame.maxX - 2
        }
    }
}

enum FullscreenSelfTest {
    @MainActor
    static func run() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures += 1; print("FAIL fullscreen \(label)") }
        }
        let flags = TaskbarController.panelCollectionBehavior
        check(flags.contains([.canJoinAllSpaces, .fullScreenAuxiliary]) && !flags.contains(.fullScreenNone),
              "taskbar and orb can join native fullscreen")
        let records: [[String: Any]] = [
            ["Display Identifier": "Main", "Current Space": ["type": 0, "ManagedSpaceID": 1]],
            ["Display Identifier": "SECOND", "Current Space": ["type": 4, "ManagedSpaceID": 7]]
        ]
        let split = TaskbarSpace.fullscreen(display: 2, space: 7)
        check(FullscreenDetector.activeSpace(in: records, display: 1, uuid: "first", isMain: true) == .desktop,
              "ordinary primary desktop")
        check(FullscreenDetector.activeSpace(in: records, display: 2, uuid: "second", isMain: false) == split,
              "fullscreen secondary display regardless of window size or focus")
        check(FullscreenDetector.activeSpace(in: records, display: 3, uuid: "third", isMain: false) == nil,
              "missing secondary does not borrow primary Space")

        let screen = NSRect(x: -800, y: 100, width: 800, height: 600)
        let display = ScreenInfo(id: 2, frame: screen, visibleFrame: screen, scale: 1)
        let middle = NSPoint(x: -400, y: 400)
        let edges: [(TaskbarEdge, NSPoint, NSPoint)] = [
            (.bottom, NSPoint(x: -400, y: 100), NSPoint(x: -400, y: 99)),
            (.top, NSPoint(x: -400, y: 700), NSPoint(x: -400, y: 701)),
            (.left, NSPoint(x: -800, y: 400), NSPoint(x: -801, y: 400)),
            (.right, NSPoint(x: 0, y: 400), NSPoint(x: 1, y: 400))
        ]
        for (edge, hit, miss) in edges {
            var state = FullscreenTaskbarReveal()
            func poll(_ p: NSPoint, _ t: TimeInterval, interacting: Bool = false) {
                state.poll(mouse: p, screens: [display], edge: edge, interacting: interacting, now: t)
            }
            state.move(to: split)
            poll(middle, 0, interacting: true)
            poll(miss, 1)
            check(state.isHidden, "\(edge) hidden on entry and on adjacent display")
            poll(hit, 2)
            check(!state.isHidden, "\(edge) reveals")
            state.move(to: split)
            poll(middle, 10, interacting: true)
            poll(middle, 10.5)
            check(!state.isHidden, "\(edge) stays open through interaction and leave delay")
            poll(middle, 11)
            check(state.isHidden, "\(edge) hides after leave")
            poll(hit, 12)
            state.move(to: .fullscreen(display: 2, space: 8))
            check(state.isHidden, "new fullscreen Space starts hidden")
            state.move(to: .desktop)
            check(!state.isFullscreen && !state.isHidden, "desktop resumes its own policy")
        }
        let below = screen.offsetBy(dx: 0, dy: -screen.height)
        let neighbor = ScreenInfo(id: 3, frame: below, visibleFrame: below, scale: 1)
        var state = FullscreenTaskbarReveal()
        state.move(to: split)
        state.poll(mouse: NSPoint(x: -400, y: 100), screens: [display, neighbor], edge: .bottom,
                   interacting: false, now: 0)
        check(state.isHidden, "neighbor owns the shared boundary")
        state.poll(mouse: NSPoint(x: -400, y: 101), screens: [display, neighbor], edge: .bottom,
                   interacting: false, now: 1)
        check(!state.isHidden, "bottom pixel inside stacked display reveals")

        // CG and AX both use global, top-left-origin bounds, including on stacked displays.
        let bounds = CGRect(x: -800, y: -600, width: 800, height: 600)
        let app = getpid() + 1
        func window(_ owner: pid_t, _ rect: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowOwnerPID as String: owner, kCGWindowLayer as String: layer,
             kCGWindowNumber as String: 42, kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let desktop = FullscreenDetector.activeSpace(in: records, display: 1, uuid: "first", isMain: true)
        let native = FullscreenDetector.activeSpace(in: records, display: 2, uuid: "second", isMain: false)
        func detect(_ windows: [[String: Any]]?, space: TaskbarSpace? = desktop, front: pid_t = app,
                    previous: TaskbarSpace = .desktop, ax: WindowTracker.FullscreenWindows = [:]) -> TaskbarSpace? {
            FullscreenDetector.taskbarSpace(native: space, display: display.id, bounds: bounds,
                                            frontmostPID: front, previous: previous, windows: windows, axFullscreen: ax)
        }
        let covering = window(app, bounds)
        let normal = window(app, bounds.insetBy(dx: 20, dy: 20))
        let own = window(getpid(), bounds)
        let covered = TaskbarSpace.covered(display: display.id, owner: app)
        check(detect([covering]) == covered, "covering desktop window")
        check(detect([normal, own]) == .desktop, "normal window with Winstripe overlay")
        check(detect([own], front: getpid(), ax: [getpid(): [42: bounds]]) == .desktop, "own CG and AX windows")
        check(detect([own, covering], front: getpid(), previous: covered) == covered, "Winstripe focus preserves coverage")
        check(detect([own], front: getpid(), previous: covered) == .desktop, "covering app closed under Winstripe")
        let moved = window(app, bounds.offsetBy(dx: 0, dy: bounds.height))
        check(detect([moved], ax: [app: [42: bounds]]) == .desktop, "another display with stale AX geometry")
        let floating = window(app, bounds, layer: 1)
        check(detect([floating]) == .desktop, "covering nonstandard layer alone")
        check(detect([floating], ax: [app: [42: bounds]]) == covered, "onscreen AX fullscreen window")
        check(detect([normal], ax: [app: [43: bounds]]) == .desktop, "AX fullscreen window on another Space")

        for autoHide in [false, true] {
            for observation in [detect([own, covering]), detect(nil, space: native)] {
                var reveal = FullscreenTaskbarReveal()
                reveal.observe(observation, display: display.id, now: 0)
                check(reveal.isHidden, "fullscreen starts hidden with auto-hide \(autoHide)")
                check(reveal.needsMousePolling(autoHide: autoHide, showPreviews: false), "edge polling enabled")
                reveal.poll(mouse: NSPoint(x: -400, y: 101), screens: [display], edge: .bottom, interacting: false, now: 1)
                check(!reveal.isHidden && !reveal.desktopBarHidden(autoHidden: autoHide), "edge overrides desktop hide")
                reveal.poll(mouse: middle, screens: [display], edge: .bottom, interacting: false, now: 2)
                check(reveal.isHidden, "leave hides with auto-hide \(autoHide)")
                reveal.observe(detect([normal]), display: display.id, now: 3)
                check(!reveal.isHidden && reveal.desktopBarHidden(autoHidden: autoHide) == autoHide &&
                      reveal.needsMousePolling(autoHide: autoHide, showPreviews: false) == autoHide, "resume desktop policy")
            }
        }
        state.move(to: covered)
        let missing = detect(nil)
        check(detect([covering], space: nil) == covered, "coverage without a Space record")
        check(detect([covering], space: nil, previous: split) == split, "missing record preserves covered native Space")
        state.observe(missing, display: display.id, now: 5)
        check(state.space == covered, "transient failure preserves coverage")
        state.observe(missing, display: display.id, now: 7)
        check(state.space == .desktop, "persistent failure releases bar")
        print(failures == 0 ? "PASS fullscreen-selftest" : "FAIL fullscreen-selftest")
        return failures == 0 ? 0 : 1
    }
}
