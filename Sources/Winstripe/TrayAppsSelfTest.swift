import AppKit

@MainActor
enum TrayAppsSelfTest {
    static func run() -> Int {
        SnapshotFixture.activate()

        let suiteName = "Winstripe-TrayApps-SelfTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("FAIL tray apps selftest: unable to create suite\n", stderr)
            return 1
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var input = TaskbarSettings()
        input.collapseTrayIcons = true
        input.trayApps = ["/tmp/One.app", "/tmp/Two.app"]
        input.trayAppsAlwaysShow = ["/tmp/One.app"]
        SettingsStore.save(input, to: defaults)
        let output = SettingsStore.load(from: defaults)
        guard output.collapseTrayIcons == input.collapseTrayIcons && output.trayApps == input.trayApps
                && output.trayAppsAlwaysShow == input.trayAppsAlwaysShow else {
            fputs("FAIL tray apps selftest: settings round-trip\n", stderr)
            return 1
        }

        let icon = NSRect(x: 20, y: 10, width: 18, height: 18)
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let labels = ["3", "120", "0", "•"]
        guard let rect3 = TrayBadgeLayout.rect(for: icon, label: labels[0], font: font),
              let rect120 = TrayBadgeLayout.rect(for: icon, label: labels[1], font: font),
              let rectDot = TrayBadgeLayout.rect(for: icon, label: labels[3], font: font),
              TrayBadgeLayout.rect(for: icon, label: labels[2], font: font) == nil,
              TrayBadgeLayout.content(for: labels[1]) == .text("99+"),
              TrayBadgeLayout.content(for: labels[3]) == .dot,
              rect3.minX <= icon.minX && rect3.maxY >= icon.maxY - 1,
              rect120.minX <= icon.minX && rect120.maxY >= icon.maxY - 1,
              abs(rectDot.width - rectDot.height) < 0.01 else {
            fputs("FAIL tray apps selftest: badge layout\n", stderr)
            return 1
        }

        let labelsByName = ["Calendar": "3", "Mail": "120", "Notes": "•"]
        guard let calendar = TrayAppInfo.resolve(SnapshotFixture.trayAppPaths[0]), labelsByName[calendar.name] == "3" else {
            fputs("FAIL tray apps selftest: mock badge provider\n", stderr)
            return 1
        }
        let badgeCell = NSRect(x: 0, y: 0, width: 24, height: 24)
        let badgeIcon = TrayBadgeLayout.iconRect(in: badgeCell, iconSize: 16)
        let badgeFont = NSFont.systemFont(ofSize: 8, weight: .bold)
        for label in ["3", "120", "•"] {
            guard let badge = TrayBadgeLayout.rect(for: badgeCell, iconRect: badgeIcon, label: label,
                                                   font: badgeFont), badge.intersects(badgeIcon),
                  badge.maxY <= badgeCell.maxY + 0.01 else {
                fputs("FAIL tray apps selftest: badge bounds\n", stderr)
                return 1
            }
        }
        func check(_ kind: ThemeKind, edge: TaskbarEdge, collapse: Bool) -> Bool {
            func rectDescription(_ rect: TrayItemRect) -> String {
                "\(rect.name)=\(rect.rect)"
            }
            var themed = TaskbarSettings()
            themed.theme = kind
            themed.edge = edge
            themed.collapseTrayIcons = collapse
            themed.trayApps = SnapshotFixture.trayAppPaths
            themed.trayAppsAlwaysShow = [SnapshotFixture.trayAppPaths[0]]
            let size = edge.isVertical ? NSSize(width: 160, height: 520) : NSSize(width: 520, height: 48)
            let tray = TrayView(frame: NSRect(origin: .zero, size: size))
            tray.theme = Theme.make(themed)
            tray.edge = edge
            let vertical = edge.isVertical && tray.theme.trayStyle.supportsVertical
            tray.verticalLayout = vertical
            tray.collapse = collapse
            tray.showInput = true
            tray.showClock = true
            tray.showDesktop = true
            tray.trayAppsAlwaysShow = themed.trayAppsAlwaysShow
            tray.trayApps = themed.trayApps
            tray.badgeProvider = { labelsByName[$0.name] }
            tray.arrange()
            let visible = tray.itemRects().filter { $0.visible && !$0.rect.isEmpty }
            let minimumGap: CGFloat = tray.theme.classic ? 1 : 4
            for i in visible.indices {
                for j in visible.indices where j > i {
                    guard !visible[i].rect.intersects(visible[j].rect) else {
                        fputs("FAIL tray apps selftest: \(kind) \(edge) collapse=\(collapse) intersect \(rectDescription(visible[i])) with \(rectDescription(visible[j]))\n", stderr)
                        return false
                    }
                }
            }
            let sorted = visible.sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            for pair in zip(sorted, sorted.dropFirst()) {
                // Items on opposite sides of a vertical tray (for example the
                // Win11 show-desktop strip) share the Y span but are not
                // adjacent flow cells. Only measure a gap when their
                // perpendicular projections overlap.
                let perpendicularOverlap = vertical
                    ? pair.0.rect.maxX > pair.1.rect.minX && pair.1.rect.maxX > pair.0.rect.minX
                    : pair.0.rect.maxY > pair.1.rect.minY && pair.1.rect.maxY > pair.0.rect.minY
                guard perpendicularOverlap else { continue }
                let gap = vertical ? pair.1.rect.minY - pair.0.rect.maxY : pair.1.rect.minX - pair.0.rect.maxX
                if gap + 0.01 < minimumGap {
                    fputs("FAIL tray apps selftest: \(kind) \(edge) collapse=\(collapse) gap=\(gap) min=\(minimumGap) between \(rectDescription(pair.0)) and \(rectDescription(pair.1))\n", stderr)
                    return false
                }
            }
            let appCount = visible.filter { $0.name.hasPrefix("trayApp") }.count
            if !collapse && appCount != 3 {
                fputs("FAIL tray apps selftest: \(kind) \(edge) collapse=\(collapse) app-count=\(appCount) expected=3 items=\(visible.map(rectDescription))\n", stderr)
                return false
            }
            if collapse && !tray.theme.classic && appCount != 1 {
                fputs("FAIL tray apps selftest: \(kind) \(edge) collapse=\(collapse) app-count=\(appCount) expected=1 items=\(visible.map(rectDescription))\n", stderr)
                return false
            }
            if collapse && !tray.theme.classic {
                let taskbarFrame = NSRect(x: 0, y: 0, width: 1000, height: 48)
                tray.openOverflowPanel(taskbarFrame: taskbarFrame, edge: .bottom)
                let chevron = tray.itemRects().first { $0.name == "chevron" && $0.visible }
                guard let panelFrame = tray.overflowPanelFrame,
                      let chevron,
                      panelFrame.minY - taskbarFrame.maxY >= 8 - 0.01,
                      abs(panelFrame.midX - chevron.rect.midX) < 0.01,
                      tray.overflowPanelItemCount == 2,
                      abs(tray.overflowPanelCornerRadius - (kind == .win11 ? 8 : 0)) < 0.01 else {
                    fputs("FAIL tray apps selftest: \(kind) \(edge) collapse=\(collapse) panel frame=\(String(describing: tray.overflowPanelFrame)) count=\(tray.overflowPanelItemCount)\n", stderr)
                    return false
                }
                tray.closeOverflowPanel()
            }
            return true
        }

        for kind in ThemeKind.allCases {
            for edge in [TaskbarEdge.bottom, .left] {
                guard check(kind, edge: edge, collapse: false), check(kind, edge: edge, collapse: true) else {
                    fputs("FAIL tray apps selftest: \(kind) \(edge) geometry\n", stderr)
                    return 1
                }
            }
        }

        func toggleSequence(_ kind: ThemeKind, edge: TaskbarEdge) -> Bool {
            var settings = TaskbarSettings()
            settings.theme = kind
            settings.edge = edge
            settings.collapseTrayIcons = true
            settings.trayApps = SnapshotFixture.trayAppPaths
            let size = edge.isVertical ? NSSize(width: 160, height: 520) : NSSize(width: 520, height: 48)
            let tray = TrayView(frame: NSRect(origin: .zero, size: size))
            tray.theme = Theme.make(settings)
            tray.edge = edge
            tray.verticalLayout = edge.isVertical && tray.theme.trayStyle.supportsVertical
            tray.collapse = true
            tray.showInput = true
            tray.showClock = true
            tray.trayApps = settings.trayApps
            tray.arrange()
            let taskbarFrame = NSRect(origin: .zero, size: size)
            let modern = !tray.theme.classic
            let closedGlyph = tray.debugChevronGlyph

            func clickChevron() {
                if modern {
                    tray.toggleOverflowPanel(taskbarFrame: taskbarFrame, edge: edge)
                } else {
                    tray.expanded.toggle()
                    tray.arrange()
                }
            }
            func closeBy(_ reason: String) -> Bool {
                if modern { tray.closeOverflowPanel() }
                else { tray.expanded = false; tray.arrange() }
                let expectedGlyph = tray.debugChevronGlyph
                guard !tray.expanded, !tray.isOverflowPanelOpen,
                      expectedGlyph == closedGlyph else {
                    fputs("FAIL tray overflow selftest: \(kind) \(reason) did not close glyph=\(expectedGlyph) expanded=\(tray.expanded)\n", stderr)
                    return false
                }
                return true
            }

            clickChevron()
            guard tray.expanded, (!modern || tray.isOverflowPanelOpen) else {
                fputs("FAIL tray overflow selftest: \(kind) first click did not open\n", stderr)
                return false
            }
            let openGlyph = tray.debugChevronGlyph
            guard openGlyph != closedGlyph || kind == .win7 else {
                fputs("FAIL tray overflow selftest: \(kind) open glyph unchanged closed=\(closedGlyph) open=\(openGlyph)\n", stderr)
                return false
            }

            // This models the chevron mouseDown followed by its click handler.
            clickChevron()
            guard !tray.expanded, !tray.isOverflowPanelOpen else {
                fputs("FAIL tray overflow selftest: \(kind) chevron click did not close\n", stderr)
                return false
            }
            clickChevron()
            guard tray.expanded, (!modern || tray.isOverflowPanelOpen) else {
                fputs("FAIL tray overflow selftest: \(kind) second click did not reopen\n", stderr)
                return false
            }
            guard closeBy("Esc") else { return false }
            clickChevron()
            guard tray.expanded, (!modern || tray.isOverflowPanelOpen) else {
                fputs("FAIL tray overflow selftest: \(kind) outside sequence did not open\n", stderr)
                return false
            }
            guard closeBy("outside click") else { return false }
            return true
        }

        for kind in [ThemeKind.win11, .win10, .win7, .win95] {
            for edge in TaskbarEdge.allCases where !toggleSequence(kind, edge: edge) {
                return 1
            }
        }
        print("PASS tray apps selftest")
        return 0
    }
}
