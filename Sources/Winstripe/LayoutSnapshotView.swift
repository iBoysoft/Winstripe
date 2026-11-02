import AppKit

/// Shared only by fixture exporters. Keep the legacy field set and rounding unchanged.
@MainActor
enum LayoutSnapshotJSON {
    static func rect(_ frame: NSRect) -> [Double] {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].map {
            let rounded = (Double($0) * 100).rounded() / 100
            return rounded == 0 ? 0 : rounded
        }
    }
    static func descendants(_ view: NSView) -> [[String: Any]] {
        view.subviews.flatMap { child -> [[String: Any]] in
            let title: Any
            if let button = child as? RetroButton { title = button.title }
            else if let button = child as? NSButton { title = button.title }
            else { title = NSNull() }
            let row: [String: Any] = ["type": String(describing: type(of: child)),
                                      "frame": rect(child.frame), "isHidden": child.isHidden,
                                      "title": title]
            return [row] + descendants(child)
        }
    }
}

/// Deterministic, fixture-only layout coverage for the pre-Step-8 engines.
@MainActor
final class LayoutSnapshotView: NSView {
    override var isFlipped: Bool { true }
    private let bars: [(String, TaskbarView)]

    init(bars: [(String, TaskbarView)]) {
        self.bars = bars
        let gutter: CGFloat = 8
        let width = bars.map { $0.1.bounds.width }.max() ?? 0
        let height = bars.reduce(gutter) { $0 + $1.1.bounds.height + gutter }
        super.init(frame: NSRect(x: 0, y: 0, width: width + gutter * 2, height: height))
        var y = gutter
        for (_, bar) in bars {
            bar.frame.origin = NSPoint(x: gutter, y: y)
            addSubview(bar)
            y += bar.bounds.height + gutter
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
    }

    private static func app(_ index: Int, windows: Int = 1, running: Bool = true) -> AppEntry {
        let names = ["Safari", "Notes", "Calendar", "Mail", "Maps", "Music", "Photos", "Calculator"]
        let symbols = ["safari", "note.text", "calendar", "envelope.fill", "map", "music.note", "photo", "plus.forwardslash.minus"]
        let name = names[index % names.count]
        let icon = NSImage(systemSymbolName: symbols[index % symbols.count], accessibilityDescription: name)
        let pid = pid_t(100 + index)
        let ws: [WindowEntry] = (0..<windows).map { n -> WindowEntry in
            let number = index * 100 + n
            return WindowEntry(id: CGWindowID(number + 1), title: "\(name) Window \(n + 1)", minimized: false,
                               frame: .zero, element: nil, firstSeen: UInt64(number), idSource: "fixture")
        }
        return AppEntry(pid: running ? pid : 0, name: name, icon: icon, badge: nil,
                        windowCount: windows, isHidden: false, windows: ws,
                        bundleID: "com.winstripe.\(name.lowercased())", path: "/Applications/\(name).app")
    }

    private static func apps(mixed: Bool) -> [AppEntry] {
        if mixed {
            // The first two entries match fixture pins; the remaining two are
            // unpinned running apps, with one of them owning three windows.
            var calculator = app(0, windows: 1, running: true)
            calculator.bundleID = "com.apple.calculator"
            calculator.path = "/System/Applications/Calculator.app"
            var maps = app(1, windows: 1, running: true)
            maps.bundleID = "com.apple.Maps"
            maps.path = "/System/Applications/Maps.app"
            let notes = app(2, windows: 3, running: true)
            let calendar = app(3, windows: 1, running: true)
            return [calculator, maps, notes, calendar]
        }
        return SnapshotFixture.sampleApps
    }

    private static func overflowApps() -> [AppEntry] {
        (0..<30).map { app($0, windows: $0 % 3 == 0 ? 2 : 1) }
    }

    private static func bar(settings: TaskbarSettings, size: NSSize, apps: [AppEntry], pins: [PinnedApp], quick: Bool) -> TaskbarView {
        let bar = TaskbarView(frame: NSRect(origin: .zero, size: size))
        bar.appearance = NSAppearance(named: settings.theme == .win10 ? .darkAqua : .aqua)
        bar.isPreview = true
        bar.usesStartOverflowPanel = settings.capabilities.startButtonOverflow && !settings.edge.isVertical
        bar.settings = settings
        bar.apps = apps
        bar.activePID = apps.first?.pid
        bar.activeWindowID = apps.first?.windows.first?.id
        bar.pinnedApps = pins
        bar.quickLaunchItems = quick ? [
            URL(fileURLWithPath: "/Applications/Calculator.app"),
            URL(fileURLWithPath: "/Applications/Maps.app"),
            URL(fileURLWithPath: "/Applications/Photos.app")
        ] : []
        bar.clockText = SnapshotFixture.time(settings.resolvedLanguage)
        bar.dateText = SnapshotFixture.longDate(settings.resolvedLanguage)
        bar.shortDateText = "10/9/2026"
        bar.inputText = "EN"
        bar.reload(); bar.layoutSubtreeIfNeeded()
        return bar
    }

    private static func makeSettings(theme: ThemeKind, edge: TaskbarEdge, grouping: TaskbarGrouping,
                                     alignment: TaskbarAlignment = .left) -> TaskbarSettings {
        var s = SnapshotFixture.settings
        s.theme = theme; s.edge = edge; s.taskbarGrouping = grouping; s.alignment = alignment
        return s
    }

    private static func caseRecord(name: String, settings: TaskbarSettings, bar: TaskbarView,
                                   screen: NSRect, extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "name": name, "theme": SnapshotFixture.themeID(settings.theme), "edge": settings.edge.rawValue,
            "grouping": settings.taskbarGrouping.rawValue, "alignment": settings.alignment.rawValue,
            "barFrame": LayoutSnapshotJSON.rect(NSRect(origin: .zero, size: bar.bounds.size)),
            "screen": LayoutSnapshotJSON.rect(screen), "subviews": LayoutSnapshotJSON.descendants(bar),
            "tray": ["frame": LayoutSnapshotJSON.rect(bar.tray.frame),
                     "items": bar.tray.debugItemRects.map { ["name": $0.name, "frame": LayoutSnapshotJSON.rect($0.frame)] as [String: Any] }],
            "startButton": LayoutSnapshotJSON.rect(bar.startButton.frame),
            "identity": bar.snapshotLayoutIdentity
        ]
        for (key, value) in extra { row[key] = value }
        return row
    }

    private static func saveSheet(_ bars: [(String, TaskbarView)], name: String,
                                  appearance: NSAppearance.Name,
                                  saveView: (NSView, String) -> Void) {
        let sheet = LayoutSnapshotView(bars: bars)
        sheet.appearance = NSAppearance(named: appearance)
        saveView(sheet, name)
    }

    static func writeSnapshots(to directory: URL,
                               saveView: (NSView, String) -> Void,
                               saveImage: (NSImage, String) -> Void) throws {
        precondition(SnapshotFixture.isActive)
        var cases: [[String: Any]] = []
        var metrics: [[String: Any]] = []
        let pins = SnapshotFixture.pins
        let themes = ThemeKind.allCases
        let edges = TaskbarEdge.allCases
        let bottomScreen = SnapshotFixture.screenFrame
        for theme in themes {
            for edge in edges {
                for grouping in TaskbarGrouping.allCases {
                    let s = makeSettings(theme: theme, edge: edge, grouping: grouping)
                    let size = edge.isVertical
                        ? NSSize(width: TaskbarView.verticalWidth(for: s), height: SnapshotFixture.visibleFrame.height)
                        : NSSize(width: SnapshotFixture.screenFrame.width, height: TaskbarView.thickness(for: s))
                    let base = bar(settings: s, size: size, apps: SnapshotFixture.sampleApps, pins: [], quick: false)
                    cases.append(caseRecord(name: "alignment-left", settings: s, bar: base,
                                            screen: edge.isVertical ? NSRect(x: 0, y: 0, width: 900, height: 900) : bottomScreen))
                    var centered = s; centered.alignment = .center
                    let centeredBar = bar(settings: centered, size: size, apps: SnapshotFixture.sampleApps, pins: [], quick: false)
                    cases.append(caseRecord(name: "alignment-center", settings: centered, bar: centeredBar, screen: bottomScreen))
                    for pinMode in [false, true] {
                        var quickSettings = s
                        quickSettings.showQuickLaunch = true
                        let q = bar(settings: quickSettings, size: size, apps: SnapshotFixture.sampleApps,
                                   pins: pinMode ? pins : [], quick: true)
                        cases.append(caseRecord(name: pinMode ? "quicklaunch-with-pins" : "quicklaunch",
                                                settings: quickSettings, bar: q, screen: bottomScreen,
                                                extra: ["quickLaunchItems": 3, "pins": pinMode ? 3 : 0]))
                    }
                    let mixed = bar(settings: s, size: size, apps: apps(mixed: true), pins: pins, quick: false)
                    cases.append(caseRecord(name: "mixed-pins-running", settings: s, bar: mixed, screen: bottomScreen,
                                            extra: ["runningPins": 2, "unpinnedRunningApps": 2, "threeWindowApp": true]))
                    let overflowSize = edge.isVertical ? NSSize(width: size.width, height: 900) : NSSize(width: 1440, height: size.height)
                    let overflow = bar(settings: s, size: overflowSize, apps: overflowApps(), pins: [], quick: false)
                    cases.append(caseRecord(name: "overflow", settings: s, bar: overflow,
                                            screen: edge.isVertical ? NSRect(x: 0, y: 0, width: 900, height: 900) : NSRect(x: 0, y: 0, width: 1440, height: 900),
                                            extra: ["runningApps": 30, "windows": 40]))
                    let narrowSize = edge.isVertical ? NSSize(width: size.width, height: 900) : NSSize(width: 800, height: size.height)
                    let narrow = bar(settings: s, size: narrowSize, apps: apps(mixed: true), pins: pins, quick: false)
                    cases.append(caseRecord(name: "narrow", settings: s, bar: narrow,
                                            screen: edge.isVertical ? NSRect(x: 0, y: 0, width: 900, height: 900) : NSRect(x: 0, y: 0, width: 800, height: 900)))
                }
                var ms = makeSettings(theme: theme, edge: edge, grouping: .alwaysCombine)
                metrics.append(["theme": SnapshotFixture.themeID(theme), "edge": edge.rawValue,
                                "thickness": TaskbarView.thickness(for: ms),
                                "verticalWidth": TaskbarView.verticalWidth(for: ms),
                                "groupings": TaskbarGrouping.allCases.map { grouping -> [String: Any] in
                                    ms.taskbarGrouping = grouping
                                    return ["grouping": grouping.rawValue,
                                            "thickness": TaskbarView.thickness(for: ms),
                                            "verticalWidth": TaskbarView.verticalWidth(for: ms)]
                                }])
            }
            if theme == .win8 {
                for color in [UInt32(0x2D004E), UInt32(0x0078D7)] {
                var s = makeSettings(theme: .win8, edge: .bottom, grouping: .neverCombine)
                s.win8StartColor = color
                let b = bar(settings: s, size: NSSize(width: 1440, height: 40), apps: SnapshotFixture.sampleApps, pins: [], quick: false)
                cases.append(caseRecord(name: "win8-start-color-\(String(format: "%06X", color))", settings: s, bar: b, screen: bottomScreen,
                                        extra: ["win8StartColor": color]))
                }
            }
        }

        // A compact visual sheet per theme: five representative rows on the bottom and one vertical strip.
        for theme in themes {
            var quickSettings = makeSettings(theme: theme, edge: .bottom, grouping: .alwaysCombine)
            quickSettings.showQuickLaunch = true
            let rows: [(String, TaskbarView)] = [
                ("left", bar(settings: makeSettings(theme: theme, edge: .bottom, grouping: .alwaysCombine, alignment: .left), size: NSSize(width: 1440, height: TaskbarView.thickness(for: makeSettings(theme: theme, edge: .bottom, grouping: .alwaysCombine))), apps: SnapshotFixture.sampleApps, pins: [], quick: false)),
                ("quicklaunch", bar(settings: quickSettings, size: NSSize(width: 1440, height: TaskbarView.thickness(for: quickSettings)), apps: SnapshotFixture.sampleApps, pins: [], quick: true)),
                ("mixed", bar(settings: makeSettings(theme: theme, edge: .bottom, grouping: .neverCombine), size: NSSize(width: 1440, height: TaskbarView.thickness(for: makeSettings(theme: theme, edge: .bottom, grouping: .neverCombine))), apps: apps(mixed: true), pins: pins, quick: false)),
                ("overflow", bar(settings: makeSettings(theme: theme, edge: .bottom, grouping: .combineWhenFull), size: NSSize(width: 1440, height: TaskbarView.thickness(for: makeSettings(theme: theme, edge: .bottom, grouping: .combineWhenFull))), apps: overflowApps(), pins: [], quick: false)),
                ("narrow", bar(settings: makeSettings(theme: theme, edge: .bottom, grouping: .neverCombine), size: NSSize(width: 800, height: TaskbarView.thickness(for: makeSettings(theme: theme, edge: .bottom, grouping: .neverCombine))), apps: apps(mixed: true), pins: pins, quick: false))
            ]
            saveSheet(rows, name: "layout-\(SnapshotFixture.themeID(theme))-variants.png", appearance: theme == .win10 ? .darkAqua : .aqua, saveView: saveView)
            var v = makeSettings(theme: theme, edge: .left, grouping: .neverCombine)
            v.showQuickLaunch = true
            let vertical = bar(settings: v, size: NSSize(width: TaskbarView.verticalWidth(for: v), height: 900), apps: apps(mixed: true), pins: pins, quick: true)
            saveSheet([("vertical", vertical)], name: "layout-\(SnapshotFixture.themeID(theme))-vertical.png", appearance: theme == .win10 ? .darkAqua : .aqua, saveView: saveView)
        }

        for theme in themes {
            var s = SnapshotFixture.settings; s.theme = theme; s.edge = .left
            saveImage(PreviewRenderer.image(settings: s, apps: SnapshotFixture.sampleApps, activePID: 1),
                      "properties-taskbar-\(SnapshotFixture.themeID(theme))-left.png")
        }
        var win10 = SnapshotFixture.settings; win10.theme = .win10; win10.showQuickLaunch = true
        for edge in [TaskbarEdge.bottom, .left] {
            win10.edge = edge
            let size = edge.isVertical ? NSSize(width: TaskbarView.verticalWidth(for: win10), height: 900) : NSSize(width: 1440, height: TaskbarView.thickness(for: win10))
            saveView(bar(settings: win10, size: size, apps: SnapshotFixture.sampleApps, pins: [], quick: true),
                     edge == .bottom ? "taskbar-win10-quicklaunch.png" : "taskbar-win10-quicklaunch-left.png")
        }
        let data = try JSONSerialization.data(withJSONObject: ["metrics": metrics, "cases": cases], options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("layout-variants.json"))
    }
}

