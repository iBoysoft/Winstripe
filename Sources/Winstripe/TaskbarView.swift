import AppKit
import ApplicationServices

struct AppEntry: Equatable {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    var badge: String?
    var windowCount: Int
    var isHidden: Bool
    var windows: [WindowEntry] = []
    var bundleID: String? = nil
    var path: String? = nil

    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.pid == b.pid && a.name == b.name && a.badge == b.badge && a.windowCount == b.windowCount && a.isHidden == b.isHidden &&
            a.windows == b.windows
    }
}

struct WindowEntry: Equatable {
    let id: CGWindowID
    let title: String
    let minimized: Bool
    let frame: CGRect
    let element: AXUIElement?
    let firstSeen: UInt64
    let idSource: String
    static func == (lhs: WindowEntry, rhs: WindowEntry) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.minimized == rhs.minimized && lhs.frame == rhs.frame
    }
}

@MainActor
protocol TaskbarViewDelegate: AnyObject {
    func taskbarStartPressed()
    func taskbarSearchChanged(_ text: String)
    func taskbarSearchSubmitted(_ text: String)
    func taskbarAppClicked(_ pid: pid_t)
    func taskbarWindowClicked(_ pid: pid_t, windowID: CGWindowID)
    func taskbarQuickLaunch(_ url: URL)
    func taskbarShowDesktop()
    func taskbarToggleTray()
    func taskbarMoved(to edge: TaskbarEdge)
    func taskbarShowProperties()
    func taskbarToggleLock()
    func taskbarMenu(for event: NSEvent) -> NSMenu?
    func taskbarTaskMenu(pid: pid_t, windowID: CGWindowID?, event: NSEvent) -> NSMenu?
    func taskbarStartMenu(for event: NSEvent) -> NSMenu?
}

/// The taskbar itself. Also used off-screen to render the Properties preview.
@MainActor
final class TaskbarView: NSView {
    static var thickness: CGFloat { thickness(for: TaskbarSettings()) }
    static var verticalWidth: CGFloat { verticalWidth(for: TaskbarSettings()) }
    static func thickness(for settings: TaskbarSettings) -> CGFloat {
        Theme.make(settings).layoutStyle.thickness
    }
    static func verticalWidth(for settings: TaskbarSettings) -> CGFloat {
        let style = Theme.make(settings).layoutStyle
        let grouping = settings.taskbarGroupingChoice ?? style.groupingDefault
        return grouping == .alwaysCombine ? style.verticalWidthCombined : style.verticalWidth
    }

    var settings = TaskbarSettings() {
        didSet {
            if settings.activeThemeID != oldValue.activeThemeID { theme = Theme.make(settings) }
        }
    }
    private(set) var theme = Theme.make(.win95)
    var apps: [AppEntry] = []
    var activePID: pid_t?
    var quickLaunchItems: [URL] = []
    var pinnedApps: [PinnedApp] = []

    var aeroPrewarmIcons: [NSImage] {
        subviews.compactMap { ($0 as? RetroButton)?.icon }
    }
    var taskOrder: [String] = []
    var clockText = ""
    var dateText = ""
    var shortDateText = ""
    var inputText = "EN"
    var trayExpanded = false
    var trayBadges: [String: String] = [:]
    var isPreview = false
    var usesStartOverflowPanel = false
    var startMenuOpen = false { didSet { startButton.isOn = startMenuOpen } }
    var searchText = ""
    weak var delegate: TaskbarViewDelegate?

    let startButton = RetroButton()
    let tray = TrayView()
    private let win10Search = Win10SearchBox(frame: .zero)
    private let win10SearchIcon = RetroButton()
    private let win10TaskView = RetroButton()
    private var taskButtons: [RetroButton] = []
    private var taskButtonEntries: [(pid: pid_t, windowID: CGWindowID?)] = []
    private var taskPins: [PinnedApp?] = []
    private var taskIDs: [String?] = []
    private var taskPaths: [String?] = []
    private var insertionMarker: NSView?
    private var dragDestination = 0
    private var draggedButton: RetroButton?
    private var dragPreviewIndex: Int?
    private var dragFrames: [ObjectIdentifier: NSRect] = [:]
    private var superbar: Bool { theme.layoutStyle.pins == .superbar }
    private var grouping: TaskbarGrouping { settings.taskbarGroupingChoice ?? theme.layoutStyle.groupingDefault }
    var activeWindowID: CGWindowID?
    private var taskButtonsHaveLabels = false
    private var quickButtons: [RetroButton] = []
    private var separators: [CGFloat] = []
    private let acrylic = AcrylicView()
    private let vistaDesktop = RetroButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        acrylic.isHidden = true
        addSubview(acrylic)
        startButton.kind = .start
        startButton.actsOnMouseDown = true
        startButton.onClick = { [weak self] in self?.delegate?.taskbarStartPressed() }
        startButton.onMenu = { [weak self] event in self?.delegate?.taskbarStartMenu(for: event) }
        tray.onShowDesktop = { [weak self] in self?.delegate?.taskbarShowDesktop() }
        tray.onToggle = { [weak self] in self?.delegate?.taskbarToggleTray() }
        addSubview(startButton)
        addSubview(tray)
        vistaDesktop.kind = .quickLaunch
        vistaDesktop.symbol = "desktopcomputer"
        vistaDesktop.onClick = { [weak self] in self?.delegate?.taskbarShowDesktop() }
        addSubview(vistaDesktop)
        win10SearchIcon.kind = .plain
        win10SearchIcon.symbol = "magnifyingglass"
        win10SearchIcon.toolTip = L.t("Search", .english)
        win10SearchIcon.onClick = { [weak self] in self?.delegate?.taskbarStartPressed() }
        addSubview(win10SearchIcon)
        win10TaskView.kind = .plain
        win10TaskView.symbol = "rectangle.3.group"
        win10TaskView.toolTip = L.t("Task View", .english)
        win10TaskView.onClick = {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "Mission Control"]
            try? task.run()
        }
        addSubview(win10TaskView)
        win10Search.onOpen = { [weak self] text in
            self?.delegate?.taskbarSearchChanged(text)
        }
        win10Search.onChange = { [weak self] text in self?.delegate?.taskbarSearchChanged(text) }
        win10Search.onSubmit = { [weak self] text in self?.delegate?.taskbarSearchSubmitted(text) }
        addSubview(win10Search)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func style(_ b: RetroButton) {
        b.theme = theme
        b.smoothing = settings.fontSmoothing
        if theme.layoutStyle.forcedSmoothing { b.smoothing = true }
    }

    /// Rebuilds all child buttons from the current model.
    func reload() {
        clearDrag()
        let lang = settings.resolvedLanguage
        if theme.layoutStyle.usesSettingColor {
            let accent = Win8Drawing.accent(settings.win8StartColor)
            theme.barFill = [accent.withAlphaComponent(theme.layoutStyle.barAlpha)]
            theme.menuFace = accent
        }
        startButton.title = L.t(theme.startStyle.label.key, lang)
        startButton.isHidden = false
        startButton.toolTip = startButton.title
        startButton.isOn = startMenuOpen
        style(startButton)
        win10Search.isHidden = theme.layoutStyle.fixedItems.contains("win10Search") == false
        win10SearchIcon.isHidden = theme.layoutStyle.fixedItems.contains("win10Search") == false
        win10TaskView.isHidden = theme.layoutStyle.fixedItems.contains("win10TaskView") == false
        style(win10SearchIcon)
        style(win10TaskView)
        win10Search.placeholderString = L.t("Type here to search", lang)
        win10Search.stringValue = searchText

        taskButtons.forEach { $0.removeFromSuperview() }
        let s = theme.layoutStyle
        let labelMode = s.labelMode
        let iconOnly = labelMode == .never
            || (labelMode == .byGrouping && grouping == .alwaysCombine)
            || (s.vForceIconOnly && settings.edge.isVertical)
        let windowTotal = apps.reduce(0) { $0 + $1.windows.count }
        let minimumWidth: CGFloat = theme.layoutStyle.fitMinWidth
        let axisLength = settings.edge.isVertical ? bounds.height : bounds.width
        let pinSpace = superbar ? CGFloat(pinnedApps.count) * minimumWidth : 0
        let controlSpace: CGFloat = settings.edge.isVertical ? theme.layoutStyle.reservedSpaceVertical : theme.layoutStyle.reservedSpace
        let baseTaskSpace = pinnedApps.isEmpty ? max(bounds.width, bounds.height)
            : max(0, axisLength - pinSpace - controlSpace - tray.preferredWidth())
        // Equal-share grouped quick launch consumes room before the task buttons.
        let quickCount = (superbar ? 0 : pinnedApps.count) + (settings.showQuickLaunch ? quickLaunchItems.count : 0)
        let quickPitch = settings.edge.isVertical ? s.vQuickLaunchPitch : s.lIconWidth + (iconOnly ? s.buttonGap : s.lLabelGap)
        let quickSpace = s.engine == .linear && s.lTaskWidth == .equalShare && s.lQuickPlacement == .group
            ? CGFloat(quickCount) * quickPitch : 0
        let taskSpace = max(0, baseTaskSpace - quickSpace)
        let canFitAllWindows = windowTotal == 0 || CGFloat(windowTotal) * minimumWidth <= taskSpace
        let effectiveGrouping: TaskbarGrouping = (SnapshotFixture.isActive || isPreview || AXIsProcessTrusted()) ? grouping : .alwaysCombine
        let sortedApps = apps.enumerated().sorted { lhs, rhs in
            let left = lhs.element.bundleID.flatMap { taskOrder.firstIndex(of: $0) }
            let right = rhs.element.bundleID.flatMap { taskOrder.firstIndex(of: $0) }
            return (left ?? (taskOrder.count + lhs.offset)) < (right ?? (taskOrder.count + rhs.offset))
        }.map(\.element)
        let runningEntries: [(AppEntry, WindowEntry?)] = sortedApps.flatMap { app in
            let combine: Bool
            switch effectiveGrouping {
            case .alwaysCombine: combine = true
            case .neverCombine: combine = false
            case .combineWhenFull: combine = !canFitAllWindows
            }
            guard !app.windows.isEmpty && !combine && (SnapshotFixture.isActive || isPreview || AXIsProcessTrusted()) else {
                return [(app, Optional<WindowEntry>.none)]
            }
            return app.windows.map { (app, $0) }
        }
        var entries: [(AppEntry, WindowEntry?, PinnedApp?)] = []
        if superbar {
            for pin in pinnedApps {
                let group = runningEntries.filter { matches($0.0, pin: pin) }
                let combines = effectiveGrouping == .alwaysCombine ||
                    (effectiveGrouping == .combineWhenFull && !canFitAllWindows)
                if combines, let combined = group.first, combined.1 == nil {
                    entries.append((combined.0, nil, pin))
                } else {
                    let collection = pin.collection == nil ? nil : AppCollections.display(of: pin, settings: settings)
                    let name = collection?.name ?? (SnapshotFixture.isActive ? SnapshotFixture.name(for: pin.url) :
                        FileManager.default.displayName(atPath: pin.path).replacingOccurrences(of: ".app", with: ""))
                    let icon = collection?.icon ?? (SnapshotFixture.isActive ? SnapshotFixture.icon(for: pin.url) : NSWorkspace.shared.icon(forFile: pin.path))
                    let app = AppEntry(pid: 0, name: name, icon: icon,
                                       windowCount: 0, isHidden: false, bundleID: pin.bundleID, path: pin.path)
                    entries.append((app, nil, pin))
                    entries += group.map { ($0.0, $0.1, nil) }
                }
            }
        }
        entries += runningEntries.filter { entry in
            !superbar || !pinnedApps.contains { matches(entry.0, pin: $0) }
        }.map { ($0.0, $0.1, nil) }
        taskButtonEntries = entries.map { ($0.0.pid, $0.1?.id) }
        taskPins = entries.map { $0.2 }
        taskIDs = entries.map { $0.0.bundleID }
        taskPaths = entries.map { $0.0.path }
        taskButtonsHaveLabels = !iconOnly && !entries.isEmpty
        taskButtons = entries.map { (app: AppEntry, window: WindowEntry?, pin: PinnedApp?) -> RetroButton in
            let b = RetroButton()
            b.kind = .task
            b.title = iconOnly || pin != nil ? "" : (window?.title ?? app.name)
            b.isRunning = app.pid != 0 || pin.map { p in apps.contains { matches($0, pin: p) } } == true
            b.icon = app.icon
            b.isOn = window == nil ? app.pid == activePID : (app.pid == activePID && window?.id == activeWindowID)
            b.badge = settings.showBadges ? app.badge : nil
            b.toolTip = settings.showWindowPreviews && app.pid != 0 ? nil : (window?.title ?? app.name)
            style(b)
            let pid = app.pid
            b.onClick = { [weak self] in
                if pid == 0, let pin {
                    if let running = self?.apps.first(where: { self?.matches($0, pin: pin) == true }) {
                        self?.delegate?.taskbarAppClicked(running.pid)
                    } else { self?.launch(pin) }
                    return
                }
                if let window { self?.delegate?.taskbarWindowClicked(pid, windowID: window.id) }
                else { self?.delegate?.taskbarAppClicked(pid) }
            }
            b.onMenu = { [weak self] event in
                if pid == 0, let pin, let self {
                    if let running = self.apps.first(where: { self.matches($0, pin: pin) }) {
                        return self.delegate?.taskbarTaskMenu(pid: running.pid, windowID: nil, event: event)
                    }
                    return AppPinMenu.shared.menu(pin: pin, settings: self.settings)
                }
                return self?.delegate?.taskbarTaskMenu(pid: pid, windowID: window?.id, event: event)
            }
            let dragPin = pin ?? (superbar ? pinnedApps.first { matches(app, pin: $0) } : nil)
            configureDrag(b, pin: dragPin, bundleID: app.bundleID)
            addSubview(b)
            return b
        }

        quickButtons.forEach { $0.removeFromSuperview() }
        let quickPins = superbar ? [] : pinnedApps
        let quickURLs = quickPins.map(\.url) + (settings.showQuickLaunch ? quickLaunchItems : [])
        quickButtons = quickURLs.enumerated().map { (index, url) -> RetroButton in
            let b = RetroButton()
            b.kind = .quickLaunch
            if index < quickPins.count, quickPins[index].collection != nil {
                let collection = AppCollections.display(of: quickPins[index], settings: settings)
                b.icon = collection.icon
                b.toolTip = collection.name
            } else {
                b.icon = SnapshotFixture.isActive ? SnapshotFixture.icon(for: url) : NSWorkspace.shared.icon(forFile: url.path)
                b.toolTip = SnapshotFixture.isActive ? SnapshotFixture.name(for: url) : FileManager.default.displayName(atPath: url.path)
            }
            style(b)
            if index < quickPins.count {
                b.usesSmallIcon = true
                let pin = quickPins[index]
                b.onClick = { [weak self] in
                    if let app = self?.apps.first(where: { self?.matches($0, pin: pin) == true }) {
                        self?.delegate?.taskbarAppClicked(app.pid)
                    } else { self?.launch(pin) }
                }
                b.onMenu = { [weak self] event in
                    guard let self else { return nil }
                    if let running = self.apps.first(where: { self.matches($0, pin: pin) }) {
                        return self.delegate?.taskbarTaskMenu(pid: running.pid, windowID: nil, event: event)
                    }
                    return AppPinMenu.shared.menu(pin: pin, settings: self.settings)
                }
                configureDrag(b, pin: pin, bundleID: nil)
            } else {
                b.onClick = { [weak self] in self?.delegate?.taskbarQuickLaunch(url) }
            }
            addSubview(b)
            return b
        }

        tray.theme = theme
        tray.edge = settings.edge
        tray.verticalLayout = settings.edge.isVertical && theme.trayStyle.supportsVertical
        tray.smoothing = settings.fontSmoothing
        tray.language = lang
        tray.showClock = settings.showClock
        tray.clockText = clockText
        tray.dateText = shortDateText
        tray.toolTip = dateText.isEmpty ? nil : dateText
        tray.showInput = settings.showInputLanguage
        tray.inputText = theme.trayStyle.inputFixedText.isEmpty ? inputText : theme.trayStyle.inputFixedText
        if !settings.collapseTrayIcons || theme.classic { tray.closeOverflowPanel() }
        tray.collapse = settings.collapseTrayIcons
        tray.trayApps = settings.trayApps
        tray.trayAppsAlwaysShow = settings.trayAppsAlwaysShow
        tray.trayBadges = trayBadges
        tray.expanded = trayExpanded
        tray.showDesktop = settings.showDesktopButton && theme.trayStyle.showDesktopAllowed
        vistaDesktop.isHidden = theme.layoutStyle.fixedItems.contains("vistaShowDesktop") == false || !settings.showDesktopButton
        vistaDesktop.toolTip = L.t("Show Desktop", lang)
        style(vistaDesktop)
        acrylic.isHidden = theme.layoutStyle.material != "acrylic"
        acrylic.snapshotFill = theme.layoutStyle.acrylicColor.resolve(settings: settings)
        acrylic.separatorColor = theme.layoutStyle.acrylicEdge.color.resolve(settings: settings)
        acrylic.separatorWidth = theme.layoutStyle.acrylicEdge.width
        acrylic.rendersOffscreen = isPreview || ProcessInfo.processInfo.arguments.contains("--snapshot-dir")
        acrylic.separatorEdge = settings.edge
        acrylic.frame = bounds

        relayout()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        relayout()
    }

    func relayout() {
        separators = []
        acrylic.frame = bounds
        switch theme.layoutStyle.engine {
        case .linear: layoutLinear()
        case .aero: layoutAero()
        case .win8: layoutWin8()
        }
        // Task buttons are rebuilt after the fixed controls. Keep the real
        // search field above them so its frame remains the hit target.
        if win10Search.isHidden == false {
            addSubview(win10Search, positioned: .above, relativeTo: nil)
        }
        if theme.startStyle.overflow.enabled && !settings.edge.isVertical && usesStartOverflowPanel { startButton.isHidden = true }
        tray.arrange()
        needsDisplay = true
    }

    /// A single flow: start, quick launch, fixed controls, tasks, tray. Grouped
    /// starts participate in the same width/visibility pass as the task buttons.
    private func layoutLinear() {
        let s = theme.layoutStyle
        let b = bounds
        let taskSeparator = s.lTaskSeparator && (quickButtons.isEmpty == false || settings.locked == false)
        if settings.edge.isVertical {
            let startWidth = s.vStartWidth == .bounds ? b.width - s.vInset * 2 : s.vStartSize
            var y = s.vStartY
            if s.startInGroup == false {
                startButton.frame = NSRect(x: s.vStartWidth == .bounds ? s.vInset : (b.width - startWidth) / 2, y: y, width: startWidth, height: s.vStartHeight)
                y += s.vStartHeight + s.vAfterStartGap
            }
            switch s.vTraySizing {
            case .button:
                tray.frame = NSRect(x: s.vInset, y: b.height - s.vButtonHeight - s.vTrayInsetBottom,
                                    width: b.width - s.vInset * 2, height: s.vButtonHeight)
            case .preferred:
                let height = min(tray.preferredVerticalHeight, max(0, b.height - s.vTrayReserve))
                tray.frame = NSRect(x: 0, y: b.height - height, width: b.width, height: height)
            case .fixed:
                tray.frame = NSRect(x: 0, y: max(s.vTrayMinY, b.height - s.vTrayHeight), width: b.width, height: s.vTrayHeight)
            }
            if s.lQuickPlacement == .separate, quickButtons.isEmpty == false {
                if s.lQuickSeparator { separators.append(y); y += s.separatorAdvance }
                var x = s.vInset
                for (index, q) in quickButtons.enumerated() {
                    if index < pinnedApps.count && s.vPinnedQuickLaunchCentered {
                        q.frame = NSRect(x: (b.width - s.quickSize) / 2, y: y, width: s.quickSize, height: s.vButtonHeight)
                        q.isHidden = q.frame.maxY > b.height - s.vButtonHeight - s.vQuickLaunchHideReserve
                        y += s.vQuickLaunchPitch
                        continue
                    }
                    if s.vQuickLaunchWrap && x + s.quickSize > b.width - s.vInset {
                        x = s.vInset
                        y += s.vQuickLaunchPitch
                    }
                    q.frame = NSRect(x: x, y: y, width: s.quickSize, height: s.vButtonHeight)
                    x += s.vQuickLaunchPitch
                }
                y += quickButtons.count == pinnedApps.count ? s.vAfterQuickLaunchGap : s.vButtonHeight + s.vAfterQuickLaunchGap
            }
            if taskSeparator { separators.append(y); y += s.separatorAdvance }
            layoutFixedItems(vertical: true, cursor: &y)
            let fixed = (s.startInGroup ? [startButton] : []) + (s.lQuickPlacement == .group ? quickButtons : [])
            let buttons = fixed + taskButtons
            for (index, button) in buttons.enumerated() {
                let isFixed = index < fixed.count
                let width = isFixed ? s.vStartSize : (s.vTaskWidth == .bounds ? b.width - s.vInset * 2
                    : (taskButtonsHaveLabels ? s.vLabelledWidth : s.vTaskSize))
                button.isHidden = y + s.vTaskHideHeight > tray.frame.minY - s.vHideTaskGap
                button.frame = NSRect(x: s.vTaskWidth == .bounds && isFixed == false ? s.vInset : (b.width - width) / 2, y: y, width: width, height: s.vButtonHeight)
                y += isFixed ? s.vQuickLaunchPitch : (s.startInGroup && taskButtonsHaveLabels ? s.vLabelledPitch : s.vTaskPitch)
            }
            return
        }

        var x = s.lLeading
        if s.startInGroup == false {
            let width = s.startIncludesLabel ? ceil(Retro.textSize(startButton.title, font: s.startFont).width) + s.startWidth : s.startWidth
            let height = s.lStartCross == .bounds ? b.height - s.lStartHeightInset : s.lStartHeight
            let y = s.lStartCross == .center ? (b.height - height) / 2 : s.lStartY
            startButton.frame = NSRect(x: s.lStartX, y: y, width: width, height: height)
            x += width + s.lStartAdvanceGap
        }
        if s.lQuickPlacement == .separate, quickButtons.isEmpty == false {
            if s.lQuickSeparator { separators.append(x); x += s.separatorAdvance }
            for q in quickButtons {
                q.frame = NSRect(x: x, y: s.lTaskY, width: s.quickSize, height: s.lTaskHeight)
                x += s.quickPitch
            }
            x += s.lQuickTrailing
        }
        if taskSeparator { separators.append(x); x += s.separatorAdvance }
        layoutFixedItems(vertical: false, cursor: &x)
        let preferred = ceil(tray.preferredWidth())
        let trayWidth: CGFloat
        switch s.lTrayWidth {
        case .preferred: trayWidth = preferred
        case .clamped:
            let clamp = theme.trayStyle.widthClamp
            trayWidth = min(clamp.upperBound, max(clamp.lowerBound, preferred))
        case .remaining: trayWidth = min(preferred, max(0, b.width - s.lIconWidth - s.lGroupTrayGap))
        }
        let trayHeight = s.lTrayHeight == 0 ? b.height - s.lTrayHeightInset : s.lTrayHeight
        tray.frame = NSRect(x: b.width - trayWidth - s.lTrayTrailing, y: s.lTrayY, width: trayWidth, height: trayHeight)
        let fixed = (s.startInGroup ? [startButton] : []) + (s.lQuickPlacement == .group ? quickButtons : [])
        let buttons = fixed + taskButtons
        let gap = taskButtonsHaveLabels ? s.lLabelGap : s.buttonGap
        var widths = fixed.map { _ in s.lIconWidth }
        let available = max(0, tray.frame.minX - s.lAvailableTrailing)
        var tasks: [CGFloat]
        if s.lTaskWidth == .measured {
            tasks = taskButtons.map { button in
                guard taskButtonsHaveLabels, button.title.isEmpty == false else { return s.lIconWidth }
                let text = ceil((button.title as NSString).size(withAttributes: [.font: s.measureFont]).width)
                return min(s.labelMax, max(s.labelMin, s.labelLeading + s.labelIcon + s.labelGap + text + s.labelTrailing))
            }
        } else {
            let fixedTotal = widths.reduce(0, +) + CGFloat(widths.count) * gap
            let avail = tray.frame.minX - s.lTrayGap - x - fixedTotal
            let oneWindowPerApp = apps.allSatisfy { $0.windows.count <= 1 }
            let n = CGFloat(max(s.oneButtonPerApp && oneWindowPerApp ? apps.count : taskButtons.count, 1))
            let share = (avail - (s.lSubtractGaps ? (n - 1) * s.buttonGap : 0)) / n
            let width: CGFloat
            switch s.lRounding {
            case .floorAfterCap: width = max(floor(min(s.taskMax, share)), s.taskMin)
            case .none: width = taskButtonsHaveLabels ? min(s.taskMax, max(s.taskMin, share)) : s.lIconWidth
            }
            tasks = taskButtons.map { button in
                s.lPinnedIconWidth && pinnedApps.isEmpty == false && button.title.isEmpty ? s.lIconWidth : width
            }
        }
        if s.overflow == .shrinkLabelsThenHide {
            let fixedTotal = widths.reduce(0, +) + CGFloat(widths.count) * gap
            let taskTotal = tasks.reduce(0, +) + CGFloat(max(0, tasks.count - 1)) * gap
            if taskButtonsHaveLabels, fixedTotal + taskTotal > available, tasks.isEmpty == false {
                let room = max(0, available - fixedTotal - CGFloat(tasks.count - 1) * gap)
                let even = max(s.shrinkMin, floor(room / CGFloat(tasks.count)))
                tasks = tasks.map { min($0, even) }
            }
        }
        widths += tasks
        var visibleCount = buttons.count
        if s.startInGroup {
            visibleCount = 0
            var groupWidth: CGFloat = -gap
            for width in widths {
                if groupWidth + gap + width > available && visibleCount > 0 { break }
                groupWidth += gap + width
                visibleCount += 1
            }
            x = s.alignmentOptions.contains("center") && settings.alignment == .center
                ? max(s.lEdgeMin, min((b.width - groupWidth) / 2, tray.frame.minX - groupWidth - s.lGroupTrayGap)) : s.lLeading
        }
        let height = s.lButtonCross == .bounds ? b.height - s.lTaskHeightInset : s.lTaskHeight
        let y = s.lButtonCross == .center ? (b.height - height) / 2 : s.lTaskY
        for (index, button) in buttons.enumerated() {
            let width = widths[index]
            button.isHidden = s.startInGroup ? index >= visibleCount : x + width > tray.frame.minX - s.lHideGap
            button.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + gap
        }
    }

    private func layoutFixedItems(vertical: Bool, cursor: inout CGFloat) {
        let s = theme.layoutStyle
        for item in s.fixedItems {
            switch item {
            case "win10Search":
                if vertical {
                    win10Search.isHidden = true
                    let size = s.searchVerticalSize
                    win10SearchIcon.frame = NSRect(x: (bounds.width - size) / 2, y: cursor, width: size, height: size)
                    win10SearchIcon.isHidden = win10SearchIcon.frame.maxY > tray.frame.minY
                    cursor += size
                } else {
                    win10SearchIcon.isHidden = true
                    win10Search.frame = NSRect(x: s.searchX, y: s.searchHeightInset,
                                              width: min(s.searchMaxWidth, max(s.searchMinWidth, bounds.width * s.searchWidthFraction)),
                                              height: bounds.height - s.searchHeightInset * 2)
                    cursor = win10Search.frame.maxX + s.searchGapAfter
                }
            case "win10TaskView":
                if vertical {
                    let size = s.taskViewVerticalSize
                    win10TaskView.frame = NSRect(x: (bounds.width - size) / 2, y: cursor, width: size, height: size)
                    win10TaskView.isHidden = win10TaskView.frame.maxY > tray.frame.minY
                    cursor += size
                } else {
                    win10TaskView.frame = NSRect(x: cursor, y: 0, width: s.taskViewWidth, height: bounds.height)
                    cursor += s.taskViewWidth + s.taskViewGapAfter
                }
            default: break // show-desktop participates in the quick-launch flow.
            }
        }
    }

    private func layoutAero() {
        let s = theme.layoutStyle
        let vertical = settings.edge.isVertical
        startButton.isHidden = theme.startStyle.overflow.enabled && vertical == false && usesStartOverflowPanel
        let quick = quickButtons + (s.fixedItems.contains("vistaShowDesktop") && settings.showDesktopButton ? [vistaDesktop] : [])
        let taskHeight = vertical ? s.aVerticalTaskHeight : s.aTaskHeight
        if vertical {
            let orbSize = min(s.aOrbSize, max(0, bounds.width - s.aOrbWidthInset))
            startButton.frame = NSRect(x: (bounds.width - orbSize) / 2, y: s.aOrbVerticalY, width: orbSize, height: orbSize)
            let trayHeight = min(tray.preferredVerticalHeight, max(0, bounds.height - orbSize - s.aTrayVerticalReserve))
            tray.frame = NSRect(x: 0, y: bounds.height - trayHeight, width: bounds.width, height: trayHeight)
            var y = orbSize + s.aAfterOrbGap
            for q in quick {
                let width = q === vistaDesktop ? s.desktopWidth : s.aQuickSize
                let height = q === vistaDesktop ? s.desktopHeight : s.aQuickSize
                q.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
                q.isHidden = y + height > tray.frame.minY
                y += q === vistaDesktop ? s.desktopPitch : s.aQuickPitch
            }
            if quick.isEmpty == false { separators.append(y); y += s.aQuickSeparatorGapVertical }
            for t in taskButtons {
                let width = s.aLimitPinnedWidth && pinnedApps.isEmpty == false && t.title.isEmpty
                    ? min(s.aIconWidth, bounds.width - s.aTaskWidthInset) : bounds.width - s.aTaskWidthInset
                t.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: taskHeight)
                t.isHidden = t.frame.maxY > tray.frame.minY
                y += taskHeight + s.aTaskGapVertical
            }
        } else {
            let orb = s.aOrbSize
            let y = s.aOrbAnchor == .outer ? (settings.edge == .top ? s.aOrbY : bounds.height - orb) : s.aOrbY
            startButton.frame = NSRect(x: s.aOrbX, y: y, width: orb, height: orb)
            var x = s.aContentLeading
            let tw = min(ceil(tray.preferredWidth()), max(0, bounds.width - x))
            tray.frame = NSRect(x: bounds.width - tw, y: 0, width: tw, height: bounds.height)
            var visibleQuick = false
            for q in quick {
                let width = q === vistaDesktop ? s.desktopWidth : s.aQuickSize
                let height = q === vistaDesktop ? s.desktopHeight : s.aQuickSize
                q.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
                q.isHidden = q.frame.maxX > tray.frame.minX - s.aQuickHideGap
                if q.isHidden == false { x += q === vistaDesktop ? s.desktopPitch : s.aQuickPitch; visibleQuick = true }
            }
            if visibleQuick { separators.append(x); x += s.aQuickSeparatorGap }
            let count = CGFloat(max(1, taskButtons.count))
            let target = grouping == .alwaysCombine ? s.aCombinedWidth : s.aLabelledWidth
            let width = max(s.aMinWidth, min(target, floor((tray.frame.minX - x - count * s.aFitGap) / count)))
            for t in taskButtons {
                let buttonWidth = s.aLimitPinnedWidth && pinnedApps.isEmpty == false && t.title.isEmpty ? min(s.aIconWidth, width) : width
                t.frame = NSRect(x: x, y: (bounds.height - taskHeight) / 2, width: buttonWidth, height: taskHeight)
                t.isHidden = t.frame.maxX > tray.frame.minX
                x += buttonWidth + s.aTaskGap
            }
        }
    }

    private func layoutWin8() {
        let s = theme.layoutStyle
        let vertical = settings.edge.isVertical
        let size = s.cSize
        let startSize = min(size, max(0, vertical ? bounds.height : bounds.width))
        startButton.isHidden = false
        if vertical {
            startButton.frame = NSRect(x: max(0, (bounds.width - size) / 2), y: 0,
                                       width: min(size, bounds.width), height: startSize)
            let trayHeight = min(tray.preferredVerticalHeight, max(0, bounds.height - startSize - s.cTrayReserve))
            tray.frame = NSRect(x: 0, y: bounds.height - trayHeight, width: bounds.width, height: trayHeight)
            var y = startSize + s.cStartGap
            for button in quickButtons + taskButtons {
                let height = button.usesSmallIcon ? s.cSmallSize : size
                button.isHidden = y + height > tray.frame.minY - s.cHideGap
                let width = min(s.cTaskWidth, bounds.width)
                button.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
                y += height + s.cGap
            }
        } else {
            startButton.frame = NSRect(x: 0, y: 0, width: startSize, height: bounds.height)
            let trayWidth = min(ceil(tray.preferredWidth()), max(0, bounds.width - startSize - s.cTrayReserve))
            tray.frame = NSRect(x: bounds.width - trayWidth, y: 0, width: trayWidth, height: bounds.height)
            var x = startSize + s.cStartGap
            for button in quickButtons + taskButtons {
                let width = button.usesSmallIcon ? s.cSmallSize : (button.kind == .task ? s.cTaskWidth : size)
                button.isHidden = x + width > tray.frame.minX - s.cHideGap
                button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
                x += width + s.cGap
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = theme.layoutStyle
        if style.material == "aeroGlass" {
            AeroDrawing.glass(bounds, style: style.glass, vertical: settings.edge.isVertical, settings: settings)
            let p = style.glass
            for s in separators {
                p.separatorDark.resolve(settings: settings).setFill()
                (settings.edge.isVertical ? NSRect(x: p.separatorVerticalInset, y: s, width: bounds.width - p.separatorVerticalInset * 2, height: p.separatorWidth)
                    : NSRect(x: s, y: p.separatorHorizontalInset, width: p.separatorWidth, height: bounds.height - p.separatorHorizontalInset * 2)).fill()
                p.separatorLight.resolve(settings: settings).setFill()
                (settings.edge.isVertical ? NSRect(x: p.separatorVerticalInset, y: s + p.separatorWidth, width: bounds.width - p.separatorVerticalInset * 2, height: p.separatorWidth)
                    : NSRect(x: s + p.separatorWidth, y: p.separatorHorizontalInset, width: p.separatorWidth, height: bounds.height - p.separatorHorizontalInset * 2)).fill()
            }
            return
        }
        if style.material == "acrylic" { return }
        let b = bounds
        let vertical = settings.edge.isVertical
        switch style.material {
        case "solid":
            let color = style.usesSettingColor ? Win8Drawing.accent(settings.win8StartColor) : style.barColor.resolve(settings: settings)
            (style.appliesBarAlpha ? color.withAlphaComponent(style.barAlpha) : color).setFill()
            b.fill()
        case "gradient":
            let colors = style.barStops.map { $0.resolve(settings: settings) }
            let path = NSBezierPath(rect: b)
            if colors.count >= 2, let gradient = NSGradient(colors: colors) {
                gradient.draw(in: path, angle: style.barAngle - (vertical ? style.barVerticalAngleOffset : 0))
            } else { colors.first?.setFill(); path.fill() }
        default: break
        }
        var offset: CGFloat = 0
        for line in style.edges[settings.edge.rawValue] ?? style.edges["all"] ?? [] {
            line.color.resolve(settings: settings).setFill()
            switch settings.edge {
            case .bottom: NSRect(x: 0, y: offset, width: b.width, height: line.width).fill()
            case .top: NSRect(x: 0, y: b.height - (offset + line.width), width: b.width, height: line.width).fill()
            case .left: NSRect(x: b.width - (offset + line.width), y: 0, width: line.width, height: b.height).fill()
            case .right: NSRect(x: offset, y: 0, width: line.width, height: b.height).fill()
            }
            offset += line.width
        }
        guard let c = theme.classicConfig else { return }

        // Separators: an etched line when locked, a raised grip when unlocked (like Win98+).
        for s in separators {
            let inset = c.n("metrics.separator.insetY")
            let verticalInset = c.n("metrics.params.separatorVerticalInset")
            let offset = c.n("metrics.params.separatorOffset")
            let width = c.n(settings.locked ? "metrics.params.separatorLockedWidth" : "metrics.params.separatorUnlockedWidth")
            let r = vertical ? NSRect(x: verticalInset, y: s + offset, width: b.width - verticalInset * 2, height: width)
                             : NSRect(x: s + offset, y: inset, width: width, height: b.height - inset * 2)
            let separator = c.config.metrics.separator
            let style = settings.locked ? (separator?.style ?? "classicEtched")
                                        : (separator?.unlockedStyle ?? separator?.style ?? "classicGrip")
            if style == "xpEtched" {
                let dark = c.color("palette.xpSeparatorDark")
                let light = c.color("palette.xpSeparatorLight")
                let dash = 2
                if vertical {
                    for y in stride(from: Int(r.minY), to: Int(r.maxY), by: dash * 2) {
                        dark.setFill(); NSRect(x: r.minX, y: CGFloat(y), width: 1, height: min(2, r.maxY - CGFloat(y))).fill()
                        light.setFill(); NSRect(x: r.minX + 1, y: CGFloat(y), width: 1, height: min(2, r.maxY - CGFloat(y))).fill()
                    }
                } else {
                    for x in stride(from: Int(r.minX), to: Int(r.maxX), by: dash * 2) {
                        dark.setFill(); NSRect(x: CGFloat(x), y: r.minY, width: min(2, r.maxX - CGFloat(x)), height: 1).fill()
                        light.setFill(); NSRect(x: CGFloat(x), y: r.minY + 1, width: min(2, r.maxX - CGFloat(x)), height: 1).fill()
                    }
                }
            } else if style == "classicEtched" || style == "classicGrip" {
                let prefix = style == "classicEtched" ? "palette.separatorEtched" : "palette.separatorGrip"
                Retro.edge(r, tl: c.color(prefix + "TopLeft"), br: c.color(prefix + "BottomRight"))
            } else {
                c.color("palette.separatorHairline").setFill()
                let width = c.n("metrics.params.separatorHairlineWidth")
                (vertical ? NSRect(x: r.minX, y: r.minY, width: r.width, height: width)
                          : NSRect(x: r.minX, y: r.minY, width: width, height: r.height)).fill()
            }
        }
    }

    // MARK: Interaction

    private func matches(_ app: AppEntry, pin: PinnedApp) -> Bool {
        (pin.bundleID != nil && app.bundleID == pin.bundleID) || app.path == pin.path
    }

    private func launch(_ pin: PinnedApp) {
        if pin.collection != nil {
            AppCollections.open(pin, settings: settings)
        } else if pin.url.pathExtension.lowercased() == "app" {
            NSWorkspace.shared.openApplication(at: pin.url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(pin.url)
        }
    }

    var buttonOrderDescription: String {
        let quick = superbar ? [] : pinnedApps.map { "pinned:\($0.bundleID ?? $0.path)" }
        let tasks = taskButtonEntries.indices.map { index in
            let entry = taskButtonEntries[index]
            let kind = entry.pid == 0 ? "pinned" : (entry.windowID == nil ? "running" : "window")
            return "\(kind):\(taskIDs[index] ?? taskPins[index]?.path ?? String(entry.pid))\(taskPins[index] != nil && entry.pid != 0 ? ":pinned" : "")\(entry.windowID.map { ":\($0)" } ?? "")"
        }
        return (quick + tasks).joined(separator: ", ")
    }

    private func axis(_ point: NSPoint) -> CGFloat { settings.edge.isVertical ? point.y : point.x }
    private func midpoint(_ button: RetroButton) -> CGFloat {
        settings.edge.isVertical ? button.frame.midY : button.frame.midX
    }

    private func pinButtons() -> [RetroButton] {
        superbar ? zip(taskButtons, taskPins).compactMap { $0.1 == nil ? nil : $0.0 }
            : Array(quickButtons.prefix(pinnedApps.count))
    }

    private func showInsertion(at index: Int, buttons: [RetroButton]) {
        let marker = insertionMarker ?? NSView()
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        if marker.superview == nil { addSubview(marker) }
        insertionMarker = marker
        var target = index < buttons.count ? buttons[index].frame : buttons.last?.frame ?? startButton.frame
        if index >= buttons.count, superbar, let last = buttons.last,
           let slot = taskButtons.firstIndex(where: { $0 === last }), let pin = taskPins[slot] {
            for next in taskButtons.indices.dropFirst(slot + 1) {
                guard (pin.bundleID != nil && taskIDs[next] == pin.bundleID) || taskPaths[next] == pin.path else { break }
                target = taskButtons[next].frame
            }
        }
        let position = index < buttons.count
            ? (settings.edge.isVertical ? target.minY : target.minX)
            : (settings.edge.isVertical ? target.maxY : target.maxX)
        marker.frame = settings.edge.isVertical
            ? NSRect(x: target.minX, y: position - 1, width: target.width, height: 2)
            : NSRect(x: position - 1, y: target.minY, width: 2, height: target.height)
    }

    private func clearDrag() {
        draggedButton?.alphaValue = 1
        insertionMarker?.removeFromSuperview()
        insertionMarker = nil
        draggedButton = nil
        dragPreviewIndex = nil
        dragFrames = [:]
    }

    private func configureDrag(_ button: RetroButton, pin: PinnedApp?, bundleID: String?) {
        guard !settings.locked, !isPreview, pin != nil || bundleID != nil else { return }
        button.onDrag = { [weak self, weak button] event, finished in
            guard let self, let button, !self.settings.locked else { return }
            if self.draggedButton == nil {
                self.draggedButton = button
                self.dragFrames = Dictionary(firstWins: (self.taskButtons + self.quickButtons).map {
                    (ObjectIdentifier($0), $0.frame)
                })
            }
            let point = self.convert(event.locationInWindow, from: nil)
            let originalTasks = self.taskButtons
            let originalQuick = self.quickButtons
            let currentFrames = Dictionary(firstWins: (originalTasks + originalQuick).map {
                (ObjectIdentifier($0), $0.frame)
            })
            // Use original frames for hit testing, so animation never changes the insertion target.
            for b in originalTasks + originalQuick {
                if let frame = self.dragFrames[ObjectIdentifier(b)] { b.frame = frame }
            }
            let candidates: [RetroButton]
            var ids: [String] = []
            if pin != nil {
                candidates = self.pinButtons()
            } else {
                var seen = Set<String>()
                candidates = self.taskButtons.indices.compactMap { i in
                    guard let id = self.taskIDs[i],
                          !self.superbar || !self.pinnedApps.contains(where: { $0.bundleID == id }),
                          seen.insert(id).inserted else { return nil }
                    ids.append(id)
                    return self.taskButtons[i]
                }
            }
            let source = pin.flatMap { p in self.pinnedApps.firstIndex { $0.matches(p) } }
                ?? bundleID.flatMap { ids.firstIndex(of: $0) } ?? 0
            let others = candidates.enumerated().filter { $0.offset != source }.map(\.element)
            let destination = others.filter { self.axis(point) > self.midpoint($0) }.count
            self.dragDestination = destination
            if finished {
                self.clearDrag()
                self.relayout()
                if let pin { PinStore().insert(pin, at: destination) }
                else if let bundleID {
                    ids.removeAll { $0 == bundleID }
                    ids.insert(bundleID, at: min(destination, ids.count))
                    let saved = PinStore().taskOrder.filter { !ids.contains($0) }
                    PinStore().setTaskOrder(ids + saved)
                }
                return
            }
            if self.dragPreviewIndex == destination {
                for b in originalTasks + originalQuick {
                    if let frame = currentFrames[ObjectIdentifier(b)] { b.frame = frame }
                }
                self.moveDraggedButton(button, to: point)
                self.showInsertion(at: destination, buttons: others)
                return
            }
            self.dragPreviewIndex = destination
            if pin != nil && !self.superbar {
                var reordered = Array(originalQuick.prefix(self.pinnedApps.count))
                if source < reordered.count {
                    let moving = reordered.remove(at: source)
                    reordered.insert(moving, at: min(destination, reordered.count))
                    self.quickButtons = reordered + Array(originalQuick.dropFirst(self.pinnedApps.count))
                }
            } else {
                var keys = pin != nil ? self.pinnedApps.map { $0.bundleID ?? $0.path } : ids
                if source < keys.count {
                    let moving = keys.remove(at: source)
                    keys.insert(moving, at: min(destination, keys.count))
                }
                @MainActor func key(_ index: Int) -> String? {
                    if pin != nil {
                        return self.pinnedApps.first(where: { p in
                            self.taskPins[index]?.matches(p) == true ||
                                (p.bundleID != nil && self.taskIDs[index] == p.bundleID) ||
                                self.taskPaths[index] == p.path
                        }).map { $0.bundleID ?? $0.path }
                    }
                    return self.taskIDs[index]
                }
                let affected = originalTasks.indices.filter { key($0).map(keys.contains) == true }
                let sorted = affected.sorted {
                    let left = key($0).flatMap { keys.firstIndex(of: $0) } ?? 0
                    let right = key($1).flatMap { keys.firstIndex(of: $0) } ?? 0
                    return left == right ? $0 < $1 : left < right
                }
                for (slot, index) in zip(affected, sorted) { self.taskButtons[slot] = originalTasks[index] }
            }
            self.relayout()
            let targets = (originalTasks + originalQuick).map { ($0, $0.frame) }
            self.taskButtons = originalTasks
            self.quickButtons = originalQuick
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                for (b, target) in targets {
                    if b === button { continue }
                    if let current = currentFrames[ObjectIdentifier(b)] { b.frame = current }
                    b.animator().frame = target
                }
            }
            self.moveDraggedButton(button, to: point)
            self.showInsertion(at: destination, buttons: others)
        }
    }

    private func moveDraggedButton(_ button: RetroButton, to point: NSPoint) {
        var floating = button.frame
        if settings.edge.isVertical { floating.origin.y = point.y - floating.height / 2 }
        else { floating.origin.x = point.x - floating.width / 2 }
        button.frame = floating
        button.alphaValue = 0.75
    }

    private func droppedApps(_ sender: NSDraggingInfo) -> [PinnedApp] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.isFileURL && $0.pathExtension.lowercased() == "app" && Bundle(url: $0) != nil }
            .map { PinnedApp(url: $0) }
    }

    private func droppedThemes(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.isFileURL && ["rdtheme", "json"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isPreview, !droppedApps(sender).isEmpty || !droppedThemes(sender).isEmpty else { return [] }
        let buttons = pinButtons()
        let point = convert(sender.draggingLocation, from: nil)
        dragDestination = buttons.filter { axis(point) > midpoint($0) }.count
        showInsertion(at: dragDestination, buttons: buttons)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrag() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let themes = droppedThemes(sender)
        if !themes.isEmpty {
            var imported: [String] = []
            for url in themes {
                if let record = try? ThemeImportExport.importTheme(url) { imported.append(record.id) }
            }
            if let id = imported.first, let kind = ThemeKind(themeID: id) {
                SettingsStore.shared.mutate { $0.theme = kind; $0.userThemeID = nil }
            } else if let id = imported.first {
                SettingsStore.shared.mutate { $0.userThemeID = id; $0.theme = UserThemeCatalog.familyKind(id: id) }
            }
            return !imported.isEmpty
        }
        let dropped = droppedApps(sender)
        let index = dragDestination
        clearDrag()
        var offset = 0
        for app in dropped {
            if settings.locked && PinStore().contains(app) { continue }
            PinStore().insert(app, at: index + offset)
            offset += 1
        }
        return !dropped.isEmpty
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearDrag() }

    func taskButton(at point: NSPoint? = nil, pid: pid_t? = nil) -> (pid: pid_t, windowID: CGWindowID?, rect: NSRect)? {
        guard let window else { return nil }
        for (button, entry) in zip(taskButtons, taskButtonEntries) where !button.isHidden && entry.pid != 0 {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if (point.map { rect.contains($0) } ?? false) || (pid != nil && entry.pid == pid) {
                return (entry.pid, entry.windowID, rect)
            }
        }
        return nil
    }

    func simulateWin10SearchClickForTesting() {
        win10Search.simulateMouseDownForTesting()
    }

    var win10SearchHitFrameForTesting: NSRect { win10Search.frame }
    var isWin10SearchVisibleForTesting: Bool { !win10Search.isHidden }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if win10Search.isHidden == false && win10Search.frame.contains(point) {
            win10Search.simulateMouseDownForTesting()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !settings.locked, !isPreview, let screen = window?.screen ?? NSScreen.screens.first else { return }
        let p = NSEvent.mouseLocation
        let f = screen.frame
        let d: [(TaskbarEdge, CGFloat)] = [(.bottom, p.y - f.minY), (.top, f.maxY - p.y),
                                           (.left, p.x - f.minX), (.right, f.maxX - p.x)]
        if let best = d.min(by: { $0.1 < $1.1 })?.0, best != settings.edge {
            delegate?.taskbarMoved(to: best)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isPreview else { return nil }
        return delegate?.taskbarMenu(for: event)
    }
}

// Read-only fixture access to the actual model-to-button and drag-pin mappings.
extension TaskbarView {
    var snapshotLayoutIdentity: [String: Any] {
        precondition(SnapshotFixture.isActive)
        let pins = pinButtons()
        let buttons = (quickButtons + taskButtons).enumerated().map { order, button -> [String: Any] in
            let taskIndex = taskButtons.firstIndex { $0 === button }
            let quickIndex = quickButtons.firstIndex { $0 === button }
            let pinIndex = pins.firstIndex { $0 === button }
            var row: [String: Any] = [
                "order": order, "kind": String(describing: button.kind),
                "role": pinIndex != nil ? "pin" : (taskIndex != nil ? "task" : "quickLaunch"),
                "title": button.title, "toolTip": button.toolTip as Any? ?? NSNull(),
                "frame": LayoutSnapshotJSON.rect(button.frame), "isHidden": button.isHidden,
                "isRunning": button.isRunning, "isOn": button.isOn,
                "usesSmallIcon": button.usesSmallIcon,
                "pinOrder": pinIndex as Any? ?? NSNull(),
                "subviewOrder": subviews.firstIndex { $0 === button } as Any? ?? NSNull()
            ]
            if let index = taskIndex {
                row["pid"] = taskButtonEntries[index].pid
                row["windowID"] = taskButtonEntries[index].windowID as Any? ?? NSNull()
                row["bundleID"] = taskIDs[index] as Any? ?? NSNull()
                row["path"] = taskPaths[index] as Any? ?? NSNull()
            } else if let index = quickIndex {
                let urls = (superbar ? [] : pinnedApps.map(\.url))
                    + (settings.showQuickLaunch ? quickLaunchItems : [])
                row["path"] = urls[index].path
            }
            return row
        }
        let fixed: [(String, NSView)] = [
            ("start", startButton), ("tray", tray), ("win10Search", win10Search),
            ("win10SearchIcon", win10SearchIcon), ("win10TaskView", win10TaskView),
            ("vistaDesktop", vistaDesktop), ("acrylic", acrylic)
        ]
        return [
            "buttons": buttons, "buttonOrderDescription": buttonOrderDescription,
            "pinsMode": superbar ? "superbar" : "quickLaunch",
            "taskButtonsHaveLabels": taskButtonsHaveLabels,
            "separators": separators.map { Double($0) },
            "fixedItems": fixed.map { name, view in
                ["name": name, "frame": LayoutSnapshotJSON.rect(view.frame),
                 "isHidden": view.isHidden] as [String: Any]
            },
            "acrylic": ["rendersOffscreen": acrylic.rendersOffscreen,
                        "separatorEdge": acrylic.separatorEdge?.rawValue as Any? ?? NSNull()]
        ]
    }
}
