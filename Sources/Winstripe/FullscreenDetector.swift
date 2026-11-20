import AppKit

enum TaskbarSpace: Equatable {
    case desktop
    case fullscreen(display: CGDirectDisplayID, space: UInt64)
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
}

struct FullscreenTaskbarReveal {
    private(set) var space = TaskbarSpace.desktop
    private var lastInside: TimeInterval?
    var isFullscreen: Bool { space != .desktop }
    var isHidden: Bool { isFullscreen && lastInside == nil }

    mutating func move(to newSpace: TaskbarSpace) {
        guard space != newSpace else { return }
        space = newSpace
        lastInside = nil
    }

    mutating func poll(mouse: NSPoint, screens: [ScreenInfo], edge: TaskbarEdge, interacting: Bool,
                       now: TimeInterval) {
        guard case .fullscreen(let display, _) = space else { return }
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
        print(failures == 0 ? "PASS fullscreen-selftest" : "FAIL fullscreen-selftest")
        return failures == 0 ? 0 : 1
    }
}
