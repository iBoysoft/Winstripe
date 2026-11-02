import AppKit

@MainActor
enum MenuMatrix {
    struct CaseRecord {
        let scenario: String
        let taskbar: ThemeKind
        let menu: StartMenuStyle
        let edge: TaskbarEdge
        let bar: NSRect
        let button: NSRect
        let frame: NSRect
        let gap: CGFloat
        let coversTaskbar: Bool
        let orbOverlap: Bool
    }

    static func write(to url: URL) throws {
        let cases = try records()
        let objects: [[String: Any]] = cases.map { c in
            ["scenario": c.scenario, "taskbar": SnapshotFixture.themeID(c.taskbar), "menu": c.menu.rawValue,
             "edge": c.edge.rawValue, "bar": rect(c.bar), "button": rect(c.button), "frame": rect(c.frame),
             "gap": c.gap, "coversTaskbar": c.coversTaskbar, "orbOverlap": c.orbOverlap]
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": objects], options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func records() throws -> [CaseRecord] {
        let screen = SnapshotFixture.screenFrame
        let visible = SnapshotFixture.visibleFrame
        var output: [CaseRecord] = []
        for theme in ThemeKind.allCases {
            for style in StartMenuStyle.allCases {
                var settings = SnapshotFixture.settings
                settings.theme = theme
                settings.startMenuStyleChoice = style
                settings.alignment = Theme.make(theme).layoutStyle.alignmentOptions.contains("center") ? .center : .left
                output.append(try record(scenario: "bottom", settings: settings, edge: .bottom,
                                         screen: screen, visible: visible))
            }
        }
        for theme in ThemeKind.allCases {
            for edge in [TaskbarEdge.left, .top] {
                var settings = SnapshotFixture.settings
                settings.theme = theme
                settings.startMenuStyleChoice = theme.defaultStartMenu
                settings.edge = edge
                settings.alignment = Theme.make(theme).layoutStyle.alignmentOptions.contains("center") ? .center : .left
                output.append(try record(scenario: "sampled-\(edge.rawValue)", settings: settings, edge: edge,
                                         screen: screen, visible: visible))
            }
        }
        guard StartMenuStyle(rawValue: "classicXP") == .xp,
              StartMenuStyle(rawValue: "classicXP")?.rawValue == "xp",
              ThemeStartMenu(default: "classicXP").style == .xp,
              StartMenuStyle.xp.supportsStartPins else {
            throw NSError(domain: "Winstripe.MenuMatrix", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "XP migration/pin contract failed"])
        }
        for theme in ThemeKind.allCases {
            for edge in TaskbarEdge.allCases {
                for (label, size) in [("xp", NSSize(width: 1440, height: 900)),
                                      ("xp-small", NSSize(width: 1024, height: 600)),
                                      ("xp-compact", NSSize(width: 640, height: 400))] {
                    // Offset origins and visible insets also exercise secondary-screen/Dock clamping.
                    let frame = NSRect(origin: NSPoint(x: -1600, y: 100), size: size)
                    let inset = NSRect(x: frame.minX + 12, y: frame.minY + 10,
                                       width: frame.width - 24, height: frame.height - 35)
                    var settings = SnapshotFixture.settings
                    settings.theme = theme; settings.edge = edge; settings.startMenuStyleChoice = .xp
                    output.append(try record(scenario: label, settings: settings, edge: edge, screen: frame, visible: inset))
                }
            }
        }
        return output
    }

    static func sceneRecord(settings: TaskbarSettings, taskbar: TaskbarView? = nil) throws -> CaseRecord {
        try record(scenario: "scene", settings: settings, edge: settings.edge,
                   screen: SnapshotFixture.screenFrame, visible: SnapshotFixture.visibleFrame, taskbarView: taskbar)
    }

    private static func record(scenario: String, settings: TaskbarSettings, edge: TaskbarEdge,
                               screen: NSRect, visible: NSRect, taskbarView: TaskbarView? = nil) throws -> CaseRecord {
        let bar = TaskbarController.frame(settings: settings, screenFrame: screen, visibleFrame: visible, hidden: false)
        let taskbar = taskbarView ?? TaskbarView(frame: NSRect(origin: .zero, size: bar.size))
        if taskbarView == nil {
            taskbar.settings = settings
            taskbar.reload()
        }
        let sb = taskbar.startButton.frame
        let button = NSRect(x: bar.minX + sb.minX,
                             y: taskbar.isFlipped ? bar.maxY - sb.maxY : bar.minY + sb.minY,
                             width: sb.width, height: sb.height)
        let context = StartMenuContext(settings: settings, edge: edge, barFrame: bar, startButtonFrame: button,
                                       screenFrame: screen, visibleFrame: visible)
        let template = StartMenuTemplateRegistry.make(context: context)
        let placement = templateTypePlacement(style: settings.startMenuStyle)
        let frame: NSRect
        let coversTaskbar: Bool
        if placement.isFullScreen {
            coversTaskbar = placement.coversTaskbar(for: settings.theme)
            frame = coversTaskbar ? screen : uncoveredFrame(screen: screen, bar: bar, edge: edge)
        } else {
            coversTaskbar = false
            frame = StartMenuGeometry.frame(placement: placement, menuSize: template.preferredSize,
                                             buttonRect: button, barFrame: bar, edge: edge,
                                             barIsCentered: context.barIsCentered,
                                             screenFrame: screen, visibleFrame: visible)
        }
        if settings.startMenuStyle == .xp {
            let area = XPMenuLayout.available(bar: bar, edge: edge, visible: visible)
            let expectedAnchor = edge.isVertical
                ? min(max(button.maxY, area.minY + frame.height), area.maxY)
                : min(max(button.minX, area.minX), area.maxX - frame.width)
            let actualAnchor = edge.isVertical ? frame.maxY : frame.minX
            guard abs(expectedAnchor - actualAnchor) < 0.1,
                  template.preferredSize == frame.size,
                  let xp = template.view as? XPStartMenuView,
                  xp.visibleMFUCount <= 6,
                  (area.height >= 480 || xp.visibleMFUCount < 6) else {
                throw NSError(domain: "Winstripe.MenuMatrix", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "XP button alignment/content fitting failed"])
            }
        }
        let gap = edgeGap(frame: frame, bar: bar, edge: edge)
        let orbOverlap = settings.capabilities.startButtonOverflow &&
            frame.intersects(orbFrame(bar: bar, settings: settings))
        try assertGeometry(frame: frame, bar: bar, edge: edge, placement: placement,
                           visible: visible, screen: screen, coversTaskbar: coversTaskbar,
                           orbOverlap: orbOverlap, settings: settings)
        return CaseRecord(scenario: scenario, taskbar: settings.theme, menu: settings.startMenuStyle,
                          edge: edge, bar: bar, button: button, frame: frame, gap: gap,
                          coversTaskbar: coversTaskbar, orbOverlap: orbOverlap)
    }

    private static func templateTypePlacement(style: StartMenuStyle) -> StartMenuPlacement {
        StartMenuTemplateRegistry.placement(for: style)
    }

    private static func uncoveredFrame(screen: NSRect, bar: NSRect, edge: TaskbarEdge) -> NSRect {
        switch edge {
        case .bottom: return NSRect(x: screen.minX, y: bar.maxY, width: screen.width, height: screen.maxY - bar.maxY)
        case .top: return NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: bar.minY - screen.minY)
        case .left: return NSRect(x: bar.maxX, y: screen.minY, width: screen.maxX - bar.maxX, height: screen.height)
        case .right: return NSRect(x: screen.minX, y: screen.minY, width: bar.minX - screen.minX, height: screen.height)
        }
    }

    private static func edgeGap(frame: NSRect, bar: NSRect, edge: TaskbarEdge) -> CGFloat {
        switch edge {
        case .bottom: return frame.minY - bar.maxY
        case .top: return bar.minY - frame.maxY
        case .left: return frame.minX - bar.maxX
        case .right: return bar.minX - frame.maxX
        }
    }

    private static func orbFrame(bar: NSRect, settings: TaskbarSettings) -> NSRect {
        let overflow = Theme.make(settings).startStyle.overflow
        return NSRect(x: bar.minX,
                      y: settings.edge == .bottom ? bar.minY - overflow.panelInset : bar.maxY + overflow.panelInset - overflow.panelHeight,
                      width: overflow.panelWidth, height: overflow.panelHeight)
    }

    private static func assertGeometry(frame: NSRect, bar: NSRect, edge: TaskbarEdge,
                                       placement: StartMenuPlacement, visible: NSRect, screen: NSRect,
                                       coversTaskbar: Bool, orbOverlap: Bool,
                                       settings: TaskbarSettings) throws {
        let bounds = placement.isFullScreen ? screen : visible
        guard bounds.contains(frame) else {
            throw NSError(domain: "Winstripe.MenuMatrix", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "menu \(settings.theme.id)+\(settings.startMenuStyle.rawValue) is outside \(bounds)"])
        }
        if placement.isFullScreen {
            if !coversTaskbar && frame.intersects(bar) {
                throw NSError(domain: "Winstripe.MenuMatrix", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "mixed Win8 menu covers the taskbar band"])
            }
            return
        }
        let expected: CGFloat
        switch placement.mainAxis {
        case .overlap(let value): expected = -value
        case .gap(let value): expected = edge.isVertical ? 0 : value
        case .flush: expected = 0
        case .fullScreen: expected = 0
        }
        let actual = edgeGap(frame: frame, bar: bar, edge: edge)
        guard abs(actual - expected) < 0.1 else {
            throw NSError(domain: "Winstripe.MenuMatrix", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "placement gap \(actual) != \(expected) for \(settings.startMenuStyle.rawValue)"])
        }
        // The overflow orb is raised one level above pop-up menus by TaskbarController.
        // A spatial overlap is safe only while that ordering remains true.
        if orbOverlap {
            let menuLevel = NSWindow.Level.popUpMenu.rawValue
            guard hasHigherWindowLevel(than: menuLevel) else {
                throw NSError(domain: "Winstripe.MenuMatrix", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "overflow Start orb would be under the menu"])
            }
        }
    }

    private static func rect(_ r: NSRect) -> [String: CGFloat] {
        ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
    }

    @inline(never)
    private static func hasHigherWindowLevel(than level: Int) -> Bool {
        NSWindow.Level(rawValue: level + 1).rawValue > level
    }
}
