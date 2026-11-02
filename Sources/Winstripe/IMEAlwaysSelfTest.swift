import AppKit

@MainActor
enum IMEAlwaysSelfTest {
    static func run() -> Int {
        SnapshotFixture.activate()
        let horizontalSizes = [
            NSSize(width: 520, height: 48),
            NSSize(width: 280, height: 40),
            NSSize(width: 180, height: 32)
        ]
        let verticalSizes = [
            NSSize(width: 160, height: 520),
            NSSize(width: 160, height: 307),
            NSSize(width: 120, height: 180)
        ]

        func describe(_ item: TrayItemRect) -> String { "\(item.name)=\(item.rect)" }
        func check(_ kind: ThemeKind, edge: TaskbarEdge, collapse: Bool,
                   expanded: Bool, size: NSSize) -> Bool {
            var settings = TaskbarSettings()
            settings.theme = kind
            settings.edge = edge
            settings.collapseTrayIcons = collapse
            settings.trayApps = SnapshotFixture.trayAppPaths
            settings.trayAppsAlwaysShow = [SnapshotFixture.trayAppPaths[0]]
            let tray = TrayView(frame: NSRect(origin: .zero, size: size))
            tray.theme = Theme.make(settings)
            tray.edge = edge
            tray.verticalLayout = edge.isVertical && tray.theme.trayStyle.supportsVertical
            tray.collapse = collapse
            tray.expanded = expanded
            tray.showInput = true
            tray.showClock = true
            tray.showDesktop = true
            tray.trayAppsAlwaysShow = settings.trayAppsAlwaysShow
            tray.trayApps = settings.trayApps
            tray.arrange()
            let visible = tray.itemRects().filter { $0.visible && !$0.rect.isEmpty }
            guard let input = visible.first(where: { $0.name == "input" }),
                  input.rect.width > 0, input.rect.height > 0,
                  input.rect.minX >= tray.bounds.minX - 0.01,
                  input.rect.minY >= tray.bounds.minY - 0.01,
                  input.rect.maxX <= tray.bounds.maxX + 0.01,
                  input.rect.maxY <= tray.bounds.maxY + 0.01 else {
                fputs("FAIL ime always: \(kind) \(edge) collapse=\(collapse) expanded=\(expanded) size=\(size) missing-or-outside input items=\(visible.map(describe))\n", stderr)
                return false
            }
            for other in visible where other.name != "input" {
                guard !input.rect.intersects(other.rect) else {
                    fputs("FAIL ime always: \(kind) \(edge) collapse=\(collapse) expanded=\(expanded) size=\(size) input=\(input.rect) intersects \(describe(other))\n", stderr)
                    return false
                }
            }
            return true
        }

        for kind in ThemeKind.allCases {
            for edge in TaskbarEdge.allCases {
                let vertical = edge.isVertical && Theme.make(kind).trayStyle.supportsVertical
                let sizes = vertical ? verticalSizes : horizontalSizes
                for collapse in [false, true] {
                    for expanded in [false, true] {
                        for size in sizes where !check(kind, edge: edge, collapse: collapse,
                                                       expanded: expanded, size: size) {
                            return 1
                        }
                    }
                }
            }
        }
        print("PASS ime always selftest")
        return 0
    }
}
