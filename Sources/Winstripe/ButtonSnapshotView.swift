import AppKit

/// Snapshot-only grid: variants run top to bottom, interaction states left to right.
@MainActor
final class ButtonSnapshotView: NSView {
    override var isFlipped: Bool { true }

    init(bar: TaskbarView) {
        precondition(SnapshotFixture.isActive)
        precondition(bar.settings.edge == .bottom)
        let tasks = bar.subviews.compactMap { $0 as? RetroButton }.filter { $0.kind == .task }
        guard let task = tasks.first else { preconditionFailure("Button sheets require fixture tasks") }
        let startSize = bar.startButton.frame.size
        let height = task.frame.height
        let iconWidth = tasks.first(where: { $0.title.isEmpty })?.frame.width ?? height
        let gutter: CGFloat = 4
        let cellWidth: CGFloat = 160
        let cellHeight = max(startSize.height, height)
        let states: [(hovered: Bool, pressed: Bool, isOn: Bool)] = [
            (false, false, false), (true, false, false), (false, true, false),
            (false, false, true), (true, false, true), (false, true, true)
        ]
        let widths: [CGFloat] = [
            startSize.width, cellWidth, iconWidth, cellWidth, cellWidth,
            cellWidth, iconWidth, cellWidth, iconWidth, 15
        ]
        precondition(widths.allSatisfy { $0 > 0 && $0 <= cellWidth })
        let size = NSSize(width: CGFloat(states.count) * (cellWidth + gutter) + gutter,
                          height: CGFloat(widths.count) * (cellHeight + gutter) + gutter)
        super.init(frame: NSRect(origin: .zero, size: size))

        // Preserve the taskbar's own background. Alpha also keeps its normal content
        // invisible if TaskbarView relayout changes a child's isHidden during caching.
        bar.appearance = nil
        bar.frame = bounds
        bar.layoutSubtreeIfNeeded()
        for child in bar.subviews where !(child is AcrylicView) {
            child.isHidden = true
            child.alphaValue = 0
        }
        addSubview(bar)

        let apps = SnapshotFixture.sampleApps
        for row in widths.indices {
            for (column, state) in states.enumerated() {
                let button = RetroButton(frame: NSRect(
                    x: gutter + CGFloat(column) * (cellWidth + gutter),
                    y: gutter + CGFloat(row) * (cellHeight + gutter),
                    width: widths[row], height: row == 0 ? startSize.height : height))
                button.theme = bar.theme
                button.smoothing = bar.startButton.smoothing
                switch row {
                case 0:
                    button.kind = .start
                    button.title = bar.startButton.title
                case 1, 3, 4:
                    button.kind = .task
                    button.title = "Safari"
                    button.icon = apps[0].icon
                    button.isRunning = row != 3
                    button.badge = row == 4 ? "3" : nil
                case 2:
                    button.kind = .task
                    button.icon = apps[0].icon
                case 5:
                    button.kind = .task
                    button.title = "Notes"
                    button.symbol = "note.text"
                case 6:
                    button.kind = .quickLaunch
                    button.icon = apps[1].icon
                case 7:
                    button.kind = .plain
                    button.title = "Notes"
                case 8:
                    button.kind = .plain
                    button.usesSmallIcon = true
                    button.icon = apps[1].icon
                default:
                    button.kind = .plain
                    button.aeroDesktopStrip = true
                }
                button.isOn = state.isOn
                button.setSnapshotState(hovered: state.hovered, pressed: state.pressed)
                addSubview(button)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        // Opaque underlay for the taskbar's translucent materials.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
