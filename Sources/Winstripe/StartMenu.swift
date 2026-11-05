import AppKit

enum StartItem: CaseIterable {
    case programs, documents, settings, run, shutDown

    var titleKey: String {
        switch self {
        case .programs: return "Programs"
        case .documents: return "Documents"
        case .settings: return "Settings"
        case .run: return "Run…"
        case .shutDown: return "Shut Down…"
        }
    }

    var symbol: String {
        switch self {
        case .programs: return "folder.fill"
        case .documents: return "doc.text.fill"
        case .settings: return "gearshape.fill"
        case .run: return "terminal.fill"
        case .shutDown: return "power"
        }
    }

    var color: NSColor {
        switch self {
        case .programs: return NSColor(hex: 0xD8A800)
        case .documents: return NSColor(hex: 0x2060C0)
        case .settings: return NSColor(hex: 0x505050)
        case .run: return NSColor(hex: 0x000080)
        case .shutDown: return NSColor(hex: 0xA01010)
        }
    }

    var hasSubmenu: Bool { self == .programs || self == .settings }
}

enum StartMenuPresentation: Equatable {
    case popover
    case fullScreen
}

struct StartMenuPlacement {
    enum HorizontalAnchor {
        case barStart
        case startButton
        case barCenter
        case barStartInset(CGFloat)
        case startButtonWhenOffset(CGFloat)
    }

    enum MainAxis {
        case flush
        case overlap(CGFloat)
        case gap(CGFloat)
        case fullScreen(taskbarTheme: ThemeKind)
    }

    enum VerticalAnchor {
        case barTop
        case startButtonTop
    }

    let horizontal: HorizontalAnchor
    let mainAxis: MainAxis
    let vertical: VerticalAnchor
    var clampsToVisibleFrame = false

    var isFullScreen: Bool {
        if case .fullScreen = mainAxis { return true }
        return false
    }

    func coversTaskbar(for taskbarTheme: ThemeKind) -> Bool {
        guard case .fullScreen(let defaultTheme) = mainAxis else { return false }
        return taskbarTheme == defaultTheme
    }
}

@MainActor
struct StartMenuContext {
    let settings: TaskbarSettings
    let taskbarTheme: ThemeKind
    let menuStyle: StartMenuStyle
    let edge: TaskbarEdge
    let barFrame: NSRect
    let startButtonFrame: NSRect
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let language: Language
    let searchText: String
    let allApps: Bool
    let preserveAllAppsSnapshot: Bool
    let barIsCentered: Bool

    init(settings: TaskbarSettings, menuStyle: StartMenuStyle? = nil, edge: TaskbarEdge? = nil,
         barFrame: NSRect, startButtonFrame: NSRect, screenFrame: NSRect, visibleFrame: NSRect,
         searchText: String = "", allApps: Bool = false, preserveAllAppsSnapshot: Bool = false) {
        self.settings = settings
        self.taskbarTheme = settings.theme
        self.menuStyle = menuStyle ?? settings.startMenuStyle
        self.edge = edge ?? settings.edge
        self.barFrame = barFrame
        self.startButtonFrame = startButtonFrame
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.language = settings.resolvedLanguage
        self.searchText = searchText
        self.allApps = allApps
        self.preserveAllAppsSnapshot = preserveAllAppsSnapshot
        self.barIsCentered = settings.alignment == .center &&
            Theme.make(settings).layoutStyle.alignmentOptions.contains("center")
    }
}

@MainActor
protocol StartMenuTemplate {
    static var style: StartMenuStyle { get }
    static var presentation: StartMenuPresentation { get }
    static var placement: StartMenuPlacement { get }
    init(context: StartMenuContext)
    var view: NSView { get }
    var preferredSize: NSSize { get }
}

@MainActor
private protocol StartMenuViewTemplate: StartMenuTemplate {
    static func makeView(context: StartMenuContext) -> NSView
    init(view: NSView)
}

@MainActor
private extension StartMenuViewTemplate {
    init(context: StartMenuContext) { self.init(view: Self.makeView(context: context)) }
    var preferredSize: NSSize { view.frame.size }
}

@MainActor
private struct Classic95StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win95
    static let presentation = StartMenuPresentation.popover
    static let placement = StartMenuPlacement(horizontal: .startButton, mainAxis: .overlap(2), vertical: .startButtonTop)
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        StartMenuView(theme: Theme.make(.win95), settings: context.settings)
    }
}

@MainActor
private struct Classic98StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win98
    static let presentation = StartMenuPresentation.popover
    static let placement = Classic95StartMenuTemplate.placement
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        StartMenuView(theme: Theme.make(.win98), settings: context.settings)
    }
}

@MainActor
private struct ClassicMEStartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.winME
    static let presentation = StartMenuPresentation.popover
    static let placement = Classic95StartMenuTemplate.placement
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        StartMenuView(theme: Theme.make(.winME), settings: context.settings)
    }
}

@MainActor
private struct Classic2000StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win2000
    static let presentation = StartMenuPresentation.popover
    static let placement = Classic95StartMenuTemplate.placement
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        StartMenuView(theme: Theme.make(.win2000), settings: context.settings)
    }
}

@MainActor
private struct XPStartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.xp
    static let presentation = StartMenuPresentation.popover
    static let placement = StartMenuPlacement(horizontal: .startButton, mainAxis: .flush, vertical: .startButtonTop, clampsToVisibleFrame: true)
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        XPStartMenuView(context: context)
    }
}

@MainActor
private struct VistaStartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.vista
    static let presentation = StartMenuPresentation.popover
    static let placement = StartMenuPlacement(horizontal: .startButtonWhenOffset(64), mainAxis: .flush, vertical: .barTop)
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        AeroStartMenuView(settings: context.settings, searchText: context.searchText, allApps: context.allApps,
                          preserveAllAppsSnapshot: context.preserveAllAppsSnapshot)
    }
}

@MainActor
private struct Win7StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win7
    static let presentation = StartMenuPresentation.popover
    static let placement = VistaStartMenuTemplate.placement
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        AeroStartMenuView(settings: context.settings, searchText: context.searchText, allApps: context.allApps,
                          preserveAllAppsSnapshot: context.preserveAllAppsSnapshot)
    }
}

@MainActor
private struct Win8StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win8
    static let presentation = StartMenuPresentation.fullScreen
    static let placement = StartMenuPlacement(horizontal: .barStart, mainAxis: .fullScreen(taskbarTheme: .win8), vertical: .barTop)
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        Win8StartScreenView(settings: context.settings, coversTaskbar: placement.coversTaskbar(for: context.settings.theme),
                            allApps: context.allApps, searchText: context.searchText)
    }
}

@MainActor
private struct Win10StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win10
    static let presentation = StartMenuPresentation.popover
    static let placement = VistaStartMenuTemplate.placement
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        Win10StartMenuView(settings: context.settings, searchText: context.searchText)
    }
}

@MainActor
private struct Win11StartMenuTemplate: StartMenuViewTemplate {
    static let style = StartMenuStyle.win11
    static let presentation = StartMenuPresentation.popover
    static let placement = StartMenuPlacement(horizontal: .barCenter, mainAxis: .gap(10), vertical: .startButtonTop)
    let view: NSView
    init(view: NSView) { self.view = view }
    static func makeView(context: StartMenuContext) -> NSView {
        Win11StartMenuView(settings: context.settings, allApps: context.allApps, searchText: context.searchText)
    }
}

@MainActor
enum StartMenuTemplateRegistry {
    static func make(context: StartMenuContext) -> any StartMenuTemplate {
        switch context.menuStyle {
        case .win95: return Classic95StartMenuTemplate(context: context)
        case .win98: return Classic98StartMenuTemplate(context: context)
        case .winME: return ClassicMEStartMenuTemplate(context: context)
        case .win2000: return Classic2000StartMenuTemplate(context: context)
        case .xp: return XPStartMenuTemplate(context: context)
        case .vista: return VistaStartMenuTemplate(context: context)
        case .win7: return Win7StartMenuTemplate(context: context)
        case .win8: return Win8StartMenuTemplate(context: context)
        case .win10: return Win10StartMenuTemplate(context: context)
        case .win11: return Win11StartMenuTemplate(context: context)
        }
    }

    static func placement(for style: StartMenuStyle) -> StartMenuPlacement {
        switch style {
        case .win95: return Classic95StartMenuTemplate.placement
        case .win98: return Classic98StartMenuTemplate.placement
        case .winME: return ClassicMEStartMenuTemplate.placement
        case .win2000: return Classic2000StartMenuTemplate.placement
        case .xp: return XPStartMenuTemplate.placement
        case .vista: return VistaStartMenuTemplate.placement
        case .win7: return Win7StartMenuTemplate.placement
        case .win8: return Win8StartMenuTemplate.placement
        case .win10: return Win10StartMenuTemplate.placement
        case .win11: return Win11StartMenuTemplate.placement
        }
    }

    static func presentation(for style: StartMenuStyle) -> StartMenuPresentation {
        style == .win8 ? .fullScreen : .popover
    }
}

@MainActor
enum StartMenuGeometry {
    static func frame(style: StartMenuStyle, menuSize: NSSize, buttonRect: NSRect, barFrame: NSRect,
                      edge: TaskbarEdge, alignment: TaskbarAlignment, screenFrame: NSRect,
                      visibleFrame: NSRect) -> NSRect {
        let placement = StartMenuTemplateRegistry.placement(for: style)
        let centered = alignment == .center
        return frame(placement: placement, menuSize: menuSize, buttonRect: buttonRect, barFrame: barFrame,
                     edge: edge, barIsCentered: centered, screenFrame: screenFrame, visibleFrame: visibleFrame)
    }

    static func frame(placement: StartMenuPlacement, menuSize: NSSize, buttonRect: NSRect, barFrame: NSRect,
                      edge: TaskbarEdge, barIsCentered: Bool, screenFrame: NSRect,
                      visibleFrame: NSRect) -> NSRect {
        if placement.isFullScreen { return screenFrame }
        if placement.clampsToVisibleFrame {
            return XPMenuLayout.frame(menuSize: menuSize, button: buttonRect, bar: barFrame,
                                      edge: edge, visible: visibleFrame)
        }
        let overlap: CGFloat
        switch placement.mainAxis {
        case .overlap(let value): overlap = value
        default: overlap = 0
        }
        let horizontalAnchor: CGFloat
        switch placement.horizontal {
        case .barStart: horizontalAnchor = barFrame.minX
        case .startButton: horizontalAnchor = buttonRect.minX
        case .barCenter: horizontalAnchor = barIsCentered ? barFrame.midX : barFrame.minX + 8
        case .barStartInset(let inset): horizontalAnchor = barFrame.minX + inset
        case .startButtonWhenOffset(let threshold):
            horizontalAnchor = buttonRect.minX - barFrame.minX > threshold ? buttonRect.minX : barFrame.minX
        }
        let mainOffset: CGFloat
        switch placement.mainAxis {
        case .flush: mainOffset = 0
        case .overlap(let value): mainOffset = value
        case .gap(let value): mainOffset = value
        case .fullScreen: mainOffset = 0
        }
        var size = NSSize(width: min(menuSize.width, screenFrame.width),
                          height: min(menuSize.height, visibleFrame.maxY - screenFrame.minY))
        let origin: NSPoint
        switch edge {
        case .bottom:
            let centered = barIsCentered && { if case .barCenter = placement.horizontal { return true }; return false }()
            let x = centered ? horizontalAnchor - size.width / 2 : horizontalAnchor
            origin = NSPoint(x: x, y: barFrame.maxY + (placement.mainAxis.isGap ? mainOffset : -overlap))
        case .top:
            let centered = barIsCentered && { if case .barCenter = placement.horizontal { return true }; return false }()
            let x = centered ? horizontalAnchor - size.width / 2 : horizontalAnchor
            origin = NSPoint(x: x, y: barFrame.minY - size.height - (placement.mainAxis.isGap ? mainOffset : -overlap))
        case .left:
            let x = barFrame.maxX + (placement.mainAxis.isGap ? 0 : -overlap)
            let y = placement.vertical == .barTop ? barFrame.maxY - size.height : buttonRect.maxY - size.height
            origin = NSPoint(x: x, y: y)
        case .right:
            let x = barFrame.minX - size.width - (placement.mainAxis.isGap ? 0 : -overlap)
            let y = placement.vertical == .barTop ? barFrame.maxY - size.height : buttonRect.maxY - size.height
            origin = NSPoint(x: x, y: y)
        }

        var x = origin.x
        var y = origin.y
        let minY = edge == .bottom ? barFrame.maxY - overlap : screenFrame.minY
        let maxY = edge == .top ? barFrame.minY + overlap : visibleFrame.maxY
        let minX = edge == .left ? barFrame.maxX - overlap : screenFrame.minX
        let maxX = edge == .right ? barFrame.minX + overlap : screenFrame.maxX
        if edge.isVertical {
            size.width = min(size.width, max(0, maxX - minX))
            x = edge == .left ? minX : maxX - size.width
            size.height = min(size.height, max(0, visibleFrame.maxY - screenFrame.minY))
            y = min(max(y, screenFrame.minY), visibleFrame.maxY - size.height)
        } else {
            size.height = min(size.height, max(0, maxY - minY))
            size.width = min(size.width, max(0, screenFrame.maxX - screenFrame.minX))
            x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
            y = min(max(y, minY), maxY - size.height)
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

private extension StartMenuPlacement.MainAxis {
    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }
}

@MainActor
enum StartMenuRendering {
    static func view(settings: TaskbarSettings, searchText: String = "", allApps: Bool = false,
                     preserveAllAppsSnapshot: Bool = false) -> NSView {
        let screen = SnapshotFixture.screenFrame
        let bar = TaskbarController.frame(settings: settings, screenFrame: screen,
                                          visibleFrame: SnapshotFixture.visibleFrame, hidden: false)
        let context = StartMenuContext(settings: settings, barFrame: bar, startButtonFrame: bar,
                                       screenFrame: screen, visibleFrame: SnapshotFixture.visibleFrame,
                                       searchText: searchText, allApps: allApps,
                                       preserveAllAppsSnapshot: preserveAllAppsSnapshot)
        let template = StartMenuTemplateRegistry.make(context: context)
        return template.view
    }
}

/// Owns the selected Start menu template and its presentation.
@MainActor
final class StartMenuController: NSObject {
    private unowned let owner: TaskbarController
    private var panel: NSPanel?
    private var menuView: NSView?
    private var classicSubmenus: [(menu: NSMenu, panel: NSPanel)] = []
    /// The open Programs menu and its row, to update when a scan or new icons arrive.
    private var openPrograms: (menu: NSMenu, rect: NSRect, classic: Bool)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastButtonRect = NSRect.zero
    private var lastBarFrame = NSRect.zero
    private var lastEdge: TaskbarEdge = .bottom
    private var lastSettings = TaskbarSettings()
    private var lastScreen: NSScreen?

    var isOpen: Bool { panel != nil }

    init(owner: TaskbarController) {
        self.owner = owner
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(catalogChanged), name: AppCatalog.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(iconsUpdated), name: AppIconCache.didUpdate, object: nil)
    }

    private func buildProgramsMenu(into menu: NSMenu? = nil) -> NSMenu {
        let lang = SnapshotFixture.isActive ? SnapshotFixture.settings.resolvedLanguage : SettingsStore.shared.current.resolvedLanguage
        let target = menu ?? NSMenu()
        ProgramsMenu.populate(target, target: self, action: #selector(launchApp(_:)), lang: lang,
                              webFolders: AppCollections.folders(settings: lastSettings),
                              webItems: AppCollections.rootItems(settings: lastSettings))
        return target
    }

    /// Hovers Programs, for `--app-catalog-selftest`.
    func debugShowPrograms() { select(.programs, rect: NSRect(x: 0, y: 0, width: 100, height: 24)) }
    var debugProgramsTitles: [String] { classicSubmenus.first?.menu.items.map(\.title) ?? [] }
    var debugClassicPanelCount: Int { classicSubmenus.count }

    /// Replaces what an open Programs menu shows. Never waits for the scan that caused this.
    @objc private func catalogChanged() {
        guard let open = openPrograms else { return }
        if open.classic {
            guard classicSubmenus.first?.menu === open.menu, let anchor = menuView else {
                openPrograms = nil
                return
            }
            let menu = buildProgramsMenu()
            openPrograms = (menu, open.rect, true)
            closeClassicSubmenus()
            showClassicSubmenu(menu, anchoredTo: open.rect, in: anchor, depth: 0)
        } else {
            _ = buildProgramsMenu(into: open.menu)
        }
    }

    @objc private func iconsUpdated() {
        func redrawView(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redrawView)
        }
        func redrawWindow(_ window: NSWindow) {
            if let content = window.contentView { redrawView(content) }
            window.childWindows?.forEach(redrawWindow)
        }
        if let panel { redrawWindow(panel) }
        func refresh(_ menu: NSMenu) {
            for item in menu.items {
                item.image = item.image
                if let submenu = item.submenu { refresh(submenu) }
            }
        }
        if let open = openPrograms, !open.classic { refresh(open.menu) }
    }

    func show(buttonRect: NSRect, barFrame: NSRect, edge: TaskbarEdge, settings: TaskbarSettings, screen: NSScreen?, searchText: String = "", focusMenu: Bool = true) {
        lastButtonRect = buttonRect
        lastBarFrame = barFrame
        lastEdge = edge
        lastSettings = settings
        lastScreen = screen
        close(notify: false)
        AppCatalog.shared.refreshIfStale()
        let screenFrame = screen?.frame ?? NSRect(origin: .zero, size: NSSize(width: 1440, height: 900))
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let context = StartMenuContext(settings: settings, edge: edge, barFrame: barFrame,
                                       startButtonFrame: buttonRect, screenFrame: screenFrame,
                                       visibleFrame: visibleFrame, searchText: searchText)
        let template = StartMenuTemplateRegistry.make(context: context)
        let style = context.menuStyle
        let v = template.view
        let placement = StartMenuTemplateRegistry.placement(for: style)
        wire(template: template, view: v)
        let size = v.frame.size
        if StartMenuTemplateRegistry.presentation(for: style) == .fullScreen {
            let coversTaskbar = placement.coversTaskbar(for: settings.theme)
            let contentFrame: NSRect
            if coversTaskbar {
                contentFrame = screenFrame
            } else {
                switch edge {
                case .bottom: contentFrame = NSRect(x: screenFrame.minX, y: barFrame.maxY,
                                                     width: screenFrame.width, height: max(0, screenFrame.maxY - barFrame.maxY))
                case .top: contentFrame = NSRect(x: screenFrame.minX, y: screenFrame.minY,
                                                  width: screenFrame.width, height: max(0, barFrame.minY - screenFrame.minY))
                case .left: contentFrame = NSRect(x: barFrame.maxX, y: screenFrame.minY,
                                                   width: max(0, screenFrame.maxX - barFrame.maxX), height: screenFrame.height)
                case .right: contentFrame = NSRect(x: screenFrame.minX, y: screenFrame.minY,
                                                    width: max(0, barFrame.minX - screenFrame.minX), height: screenFrame.height)
                }
            }
            v.frame = NSRect(origin: .zero, size: contentFrame.size)
            (v as? Win8StartScreenView)?.taskbarStartRect =
                coversTaskbar ? NSRect(x: buttonRect.minX - contentFrame.minX, y: contentFrame.maxY - buttonRect.maxY,
                                       width: buttonRect.width, height: buttonRect.height) : nil
            let p = Win8StartPanel(contentRect: contentFrame,
                                   styleMask: [.borderless], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            p.isOpaque = true
            p.backgroundColor = Win8Drawing.accent(settings.win8StartColor)
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.hasShadow = false
            p.isReleasedWhenClosed = false
            p.acceptsMouseMovedEvents = true
            p.becomesKeyOnlyIfNeeded = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = v
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.makeKey()
            (v as? Win8StartScreenView)?.beginVisibleAnimations()
            (v as? Win8StartScreenView)?.focusSearch()
            panel = p
            menuView = v
            installMonitors()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                p.animator().alphaValue = 1
            }
            return
        }
        let finalFrame = StartMenuGeometry.frame(placement: placement, menuSize: size, buttonRect: buttonRect,
                                                  barFrame: barFrame, edge: edge, barIsCentered: context.barIsCentered,
                                                  screenFrame: screenFrame, visibleFrame: visibleFrame)
        v.frame = NSRect(origin: .zero, size: finalFrame.size)
        v.layoutSubtreeIfNeeded()
        let aero = style.isAero
        let panelType: NSPanel.Type = style == .win11 || aero ? Win11StartPanel.self : NSPanel.self
        let p = panelType.init(contentRect: finalFrame,
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.hasShadow = ![.win95, .win98, .winME, .win2000].contains(style)
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        if style == .win11 || aero || style == .xp {
            p.isOpaque = false
            p.backgroundColor = .clear
            p.becomesKeyOnlyIfNeeded = false
        }
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = v
        p.orderFrontRegardless()
        if let modern = v as? Win11StartMenuView {
            p.makeKey()
            modern.focusSearch()
        }
        if let modern = v as? Win10StartMenuView {
            if focusMenu {
                p.makeKey()
                modern.focusSearch()
            }
        }
        if let aero = v as? AeroStartMenuView {
            p.makeKey()
            aero.focusSearch()
        }
        panel = p
        menuView = v
        installMonitors()
        debugLog("Start menu opened frame=\(finalFrame) bar=\(barFrame) button=\(buttonRect)")
    }

    func updateSearch(_ searchText: String) {
        guard let panel, menuView is Win10StartMenuView else { return }
        let screenFrame = lastScreen?.frame ?? NSRect(origin: .zero, size: NSSize(width: 1440, height: 900))
        let visibleFrame = lastScreen?.visibleFrame ?? screenFrame
        let context = StartMenuContext(settings: lastSettings, edge: lastEdge, barFrame: lastBarFrame,
                                       startButtonFrame: lastButtonRect, screenFrame: screenFrame,
                                       visibleFrame: visibleFrame, searchText: searchText)
        let template = StartMenuTemplateRegistry.make(context: context)
        let view = template.view
        wire(template: template, view: view)
        view.frame = NSRect(origin: .zero, size: panel.contentView?.bounds.size ?? view.frame.size)
        panel.contentView = view
        menuView = view
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
    }

    private func wire(template: any StartMenuTemplate, view: NSView) {
        if let classic = view as? StartMenuView {
            classic.onSelect = { [weak self] item, rect in self?.select(item, rect: rect) }
            classic.onHover = { [weak self] item, rect in
                guard let self else { return }
                if item.hasSubmenu {
                    self.select(item, rect: rect)
                } else {
                    self.closeClassicSubmenus()
                }
            }
        }
        if let menu = view as? XPStartMenuView {
            menu.onLaunch = { [weak self] entry in self?.close(); AppCollections.open(entry) }
            menu.onCommand = { [weak self] item in self?.command(item) }
        }
        if let menu = view as? AeroStartMenuView {
            menu.onLaunch = { [weak self] entry in self?.close(); AppCollections.open(entry) }
            menu.onCommand = { [weak self] item in self?.command(item) }
        }
        if let menu = view as? Win10StartMenuView {
            menu.onLaunch = { [weak self] entry in self?.close(); AppCollections.open(entry) }
            menu.onCommand = { [weak self] item in self?.command(item) }
        }
        if let menu = view as? Win11StartMenuView {
            menu.onLaunch = { [weak self] entry in self?.close(); AppCollections.open(entry) }
            menu.onCommand = { [weak self] item in self?.command(item) }
        }
        if let menu = view as? Win8StartScreenView {
            menu.onLaunch = { [weak self] entry in self?.close(); AppCollections.open(entry) }
            menu.onCommand = { [weak self] item in self?.command(item) }
            menu.onClose = { [weak self] in self?.close() }
        }
    }

    private func command(_ item: StartItem) {
        close()
        switch item {
        case .run: owner.runDialog()
        case .settings: owner.showProperties()
        case .shutDown: owner.shutDown()
        case .documents:
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
        default: break
        }
    }

    func close(notify: Bool = true) {
        removeMonitors()
        closeClassicSubmenus()
        openPrograms = nil
        (menuView as? XPStartMenuView)?.closeFlyouts()
        (menuView as? Win8StartScreenView)?.stopAnimations()
        panel?.orderOut(nil)
        panel = nil
        menuView = nil
        if notify { owner.startMenuDidClose() }
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if let screen = self.menuView as? Win8StartScreenView, screen.isShowingPowerMenu { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil } // Esc
                if event.window === panel, let screen = self.menuView as? Win8StartScreenView,
                   screen.routeSearchKey(event) { return nil }
                return event
            }
            if event.window === panel { return event }
            if classicSubmenus.contains(where: { $0.panel === event.window }) { return event }
            if let xp = self.menuView as? XPStartMenuView, xp.ownsFlyout(event.window) { return event }
            if self.owner.isStartButtonEvent(event) { return event }
            self.close()
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func select(_ item: StartItem, rect: NSRect) {
        let lang = SnapshotFixture.isActive ? SnapshotFixture.settings.resolvedLanguage : SettingsStore.shared.current.resolvedLanguage
        let menuTheme = lastSettings.startMenuStyle.classicThemeKind.map { Theme.make($0) }
            ?? Theme.make(lastSettings)
        switch item {
        case .programs:
            let menu = buildProgramsMenu()
            openPrograms = (menu, rect, menuTheme.classic)
            if menuTheme.classic {
                showClassicSubmenu(menu, anchoredTo: rect, in: menuView, depth: 0)
            } else {
                popUp(menu, at: rect)
                openPrograms = nil
            }
        case .settings:
            let m = NSMenu()
            m.autoenablesItems = false
            let i = NSMenuItem(title: L.t("Winstripe Settings…", lang), action: #selector(openProperties), keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)
            m.addItem(i)
            if menuTheme.classic {
                showClassicSubmenu(m, anchoredTo: rect, in: menuView, depth: 0)
            } else {
                popUp(m, at: rect)
            }
        case .documents:
            close()
            let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            NSWorkspace.shared.open(docs)
        case .run:
            close()
            owner.runDialog()
        case .shutDown:
            close()
            owner.shutDown()
        }
    }

    private func popUp(_ menu: NSMenu, at rect: NSRect) {
        guard let v = menuView else { return }
        (v as? StartMenuView)?.lockedHighlight = true
        menu.popUp(positioning: nil, at: NSPoint(x: rect.maxX - 3, y: rect.minY), in: v)
        close()
    }

    private func showClassicSubmenu(_ menu: NSMenu, anchoredTo rect: NSRect, in anchorView: NSView?, depth: Int) {
        guard let anchorView, let anchorWindow = anchorView.window else { return }
        if depth < classicSubmenus.count, classicSubmenus[depth].menu === menu { return }
        closeClassicSubmenus(from: depth)

        let theme = lastSettings.startMenuStyle.classicThemeKind.map { Theme.make($0) }
            ?? Theme.make(lastSettings)
        let view = ClassicSubmenuView(menu: menu, theme: theme)
        let anchorInWindow = anchorView.convert(rect, to: nil)
        let anchorOnScreen = anchorWindow.convertToScreen(anchorInWindow)
        let visible = anchorWindow.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let contentHeight = view.frame.height
        let panelHeight = min(contentHeight, max(28, visible.height - 8))
        let needsScroll = contentHeight > panelHeight
        let width = view.frame.width + (needsScroll ? 16 : 0)
        var x = anchorOnScreen.maxX - 3
        if x + width > visible.maxX { x = anchorOnScreen.minX - width + 3 }
        x = min(max(x, visible.minX), visible.maxX - width)
        var y = anchorOnScreen.maxY - panelHeight
        y = min(max(y, visible.minY), visible.maxY - panelHeight)

        let submenuPanel = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: panelHeight),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        submenuPanel.level = .popUpMenu
        submenuPanel.isFloatingPanel = true
        submenuPanel.hidesOnDeactivate = false
        submenuPanel.hasShadow = true
        submenuPanel.isOpaque = true
        submenuPanel.backgroundColor = theme.face
        submenuPanel.isReleasedWhenClosed = false
        submenuPanel.acceptsMouseMovedEvents = true
        submenuPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if needsScroll {
            let contentWidth = view.frame.width
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: panelHeight))
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = theme.face
            scrollView.hasVerticalScroller = false
            view.frame = NSRect(x: 0, y: 0, width: view.frame.width, height: contentHeight)
            scrollView.documentView = view
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelHeight))
            container.wantsLayer = false
            container.addSubview(scrollView)
            let scrollbar = ClassicScrollbarView(frame: NSRect(x: contentWidth, y: 0, width: width - contentWidth, height: panelHeight),
                                                  scrollView: scrollView, theme: theme)
            container.addSubview(scrollbar)
            submenuPanel.contentView = container
        } else {
            submenuPanel.contentView = view
        }
        view.onHover = { [weak self, weak view] item, itemRect in
            guard let self, let view else { return }
            if let submenu = item.submenu {
                self.showClassicSubmenu(submenu, anchoredTo: itemRect, in: view, depth: depth + 1)
            } else {
                self.closeClassicSubmenus(from: depth + 1)
            }
        }
        view.onActivate = { [weak self] item in
            guard let self else { return }
            if let url = item.representedObject as? URL {
                self.close()
                debugLog("Launching \(url.isFileURL ? url.path : url.absoluteString)")
                AppCollections.open(row: item, url: url)
            } else if item.action == #selector(self.openProperties) {
                self.close()
                self.owner.showProperties()
            }
        }
        view.onContext = { [weak self] item, event in
            guard let entry = (item as? ProgramsMenuItem)?.entry,
                  let contentView = event.window?.contentView else { return }
            let hiddenBefore = HiddenStore().entries
            NSMenu.popUpContextMenu(AppPinMenu.shared.menu(entry: entry, settings: SettingsStore.shared.current), with: event, for: contentView)
            // The open panels list the entry just hidden; the next ones are built without it.
            if HiddenStore().entries != hiddenBefore { self?.closeClassicSubmenus() }
        }
        classicSubmenus.append((menu, submenuPanel))
        anchorWindow.addChildWindow(submenuPanel, ordered: .above)
        submenuPanel.orderFrontRegardless()
    }

    private func closeClassicSubmenus(from depth: Int = 0) {
        guard depth < classicSubmenus.count else { return }
        for entry in classicSubmenus[depth...] {
            entry.panel.parent?.removeChildWindow(entry.panel)
            entry.panel.orderOut(nil)
        }
        classicSubmenus.removeSubrange(depth...)
    }

    @objc private func launchApp(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        debugLog("Launching \(url.isFileURL ? url.path : url.absoluteString)")
        AppCollections.open(row: sender, url: url)
    }

    @objc private func openProperties() {
        owner.showProperties()
    }
}

@MainActor
final class ClassicScrollbarView: NSView {
    private weak var scrollView: NSScrollView?
    private let theme: Theme
    private var observer: NSObjectProtocol?
    private var dragging = false
    private var dragStartY: CGFloat = 0
    private var dragStartOffset: CGFloat = 0

    init(frame: NSRect, scrollView: NSScrollView, theme: Theme) {
        self.scrollView = scrollView
        self.theme = theme
        super.init(frame: frame)
        wantsLayer = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }

    private var documentHeight: CGFloat {
        scrollView?.documentView?.bounds.height ?? 0
    }

    private var viewportHeight: CGFloat {
        scrollView?.contentView.bounds.height ?? 0
    }

    private var maxOffset: CGFloat {
        max(0, documentHeight - viewportHeight)
    }

    private var offset: CGFloat {
        scrollView?.contentView.bounds.minY ?? 0
    }

    private var trackRect: NSRect {
        NSRect(x: 1, y: 16, width: max(1, bounds.width - 2), height: max(1, bounds.height - 32))
    }

    private var knobRect: NSRect {
        let track = trackRect
        let proportion = documentHeight > 0 ? min(1, viewportHeight / documentHeight) : 1
        let knobHeight = max(16, floor(track.height * proportion))
        let travel = max(0, track.height - knobHeight)
        let progress = maxOffset > 0 ? min(1, max(0, offset / maxOffset)) : 0
        return NSRect(x: track.minX + 1, y: track.minY + floor(travel * progress),
                      width: max(1, track.width - 2), height: min(knobHeight, track.height))
    }

    private func topButtonRect() -> NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: min(16, bounds.height / 2))
    }

    private func bottomButtonRect() -> NSRect {
        NSRect(x: 0, y: max(0, bounds.height - 16), width: bounds.width, height: min(16, bounds.height / 2))
    }

    private func setOffset(_ value: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        var point = clip.bounds.origin
        point.y = min(max(0, value), maxOffset)
        clip.scroll(to: point)
        scrollView.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.face.setFill()
        bounds.fill()
        let track = trackRect
        theme.shadow.setFill()
        track.fill()
        Retro.edge(track, tl: theme.darkShadow, br: theme.highlight)

        drawButton(topButtonRect(), direction: -1)
        drawButton(bottomButtonRect(), direction: 1)
        let knob = knobRect
        if dragging { Retro.pressed(knob, theme) } else { Retro.raised(knob, theme) }
        theme.face.setFill()
        knob.insetBy(dx: 2, dy: 2).fill()
    }

    private func drawButton(_ rect: NSRect, direction: CGFloat) {
        Retro.raised(rect, theme)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        if direction < 0 {
            path.move(to: NSPoint(x: center.x - 4, y: center.y + 2))
            path.line(to: NSPoint(x: center.x, y: center.y - 3))
            path.line(to: NSPoint(x: center.x + 4, y: center.y + 2))
        } else {
            path.move(to: NSPoint(x: center.x - 4, y: center.y - 2))
            path.line(to: NSPoint(x: center.x, y: center.y + 3))
            path.line(to: NSPoint(x: center.x + 4, y: center.y - 2))
        }
        path.close()
        NSColor.black.setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if topButtonRect().contains(point) {
            setOffset(offset - 28)
        } else if bottomButtonRect().contains(point) {
            setOffset(offset + 28)
        } else if knobRect.contains(point) {
            dragging = true
            dragStartY = point.y
            dragStartOffset = offset
            needsDisplay = true
        } else if trackRect.contains(point) {
            setOffset(offset + (point.y < knobRect.minY ? -viewportHeight : viewportHeight))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let travel = max(1, trackRect.height - knobRect.height)
        setOffset(dragStartOffset + (point.y - dragStartY) / travel * maxOffset)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        setOffset(offset - event.scrollingDeltaY * multiplier)
    }
}

@MainActor
final class StartMenuView: NSView {
    private struct Row {
        let item: StartItem?   // nil = separator
        let rect: NSRect
    }

    private let theme: Theme
    private let settings: TaskbarSettings
    private var rows: [Row] = []
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }
    var lockedHighlight = false
    var onSelect: ((StartItem, NSRect) -> Void)?
    var onHover: ((StartItem, NSRect) -> Void)?

    private let bannerWidth: CGFloat = 22
    private let itemHeight: CGFloat = 32
    private let menuWidth: CGFloat = 186

    init(theme: Theme, settings: TaskbarSettings) {
        self.theme = theme
        self.settings = settings
        var rows: [Row] = []
        var y: CGFloat = 3
        let bannerWidth: CGFloat = 22
        let layout: [StartItem?] = [.programs, .documents, .settings, .run, nil, .shutDown]
        for entry in layout {
            if let item = entry {
                rows.append(Row(item: item, rect: NSRect(x: 3 + bannerWidth, y: y, width: 186 - bannerWidth - 6, height: 32)))
                y += 32
            } else {
                rows.append(Row(item: nil, rect: NSRect(x: 3 + bannerWidth, y: y, width: 186 - bannerWidth - 6, height: 8)))
                y += 8
            }
        }
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: 186, height: y + 3))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func index(at p: NSPoint) -> Int? {
        rows.firstIndex { $0.item != nil && $0.rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !lockedHighlight else { return }
        let next = index(at: convert(event.locationInWindow, from: nil))
        guard next != hover else { return }
        hover = next
        guard let next, let item = rows[next].item else { return }
        onHover?(item, rows[next].rect)
    }

    override func mouseExited(with event: NSEvent) {
        if !lockedHighlight { hover = nil }
    }

    override func mouseDown(with event: NSEvent) {
        hover = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), let item = rows[i].item else { return }
        hover = i
        onSelect?(item, rows[i].rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let lang = settings.resolvedLanguage
        let classicMenu = theme.classic && settings.startMenuStyle != .xp
        (classicMenu ? theme.face : theme.menuFace).setFill()
        b.fill()
        if classicMenu {
            if let c = theme.classicConfig { c.bevel("windowFrame", in: b) }
            else { Retro.windowFrame(b, theme) }
        } else {
            (settings.startMenuStyle == .win7 ? NSColor(white: 0.2, alpha: 1) : theme.buttonBorder).setFill()
            Retro.edge(b, tl: theme.buttonBorder, br: theme.buttonBorder)
        }

        let banner = NSRect(x: 3, y: 3, width: bannerWidth - 1, height: b.height - 6)
        Retro.fill(banner, theme.bannerFill)
        drawBannerText(in: banner)

        let menuText = classicMenu ? NSColor.black : theme.menuText
        for (i, row) in rows.enumerated() {
            guard let item = row.item else {
                let y = floor(row.rect.midY) - 1
                theme.shadow.setFill(); NSRect(x: row.rect.minX + 1, y: y, width: row.rect.width - 2, height: 1).fill()
                theme.highlight.setFill(); NSRect(x: row.rect.minX + 1, y: y + 1, width: row.rect.width - 2, height: 1).fill()
                continue
            }
            let highlighted = i == hover
            if highlighted {
                theme.menuHighlight.setFill()
                row.rect.fill()
            }
            let color = highlighted ? NSColor.white : menuText
            var icon = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            if let base = icon {
                let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                icon = base.symbolTinted([highlighted ? .white : item.color], configuration: sizeConfiguration)
            }
            if let img = icon {
                let s = img.size
                let scale = min(22 / max(s.width, 1), 22 / max(s.height, 1))
                let w = s.width * scale, h = s.height * scale
                Retro.drawImage(img, in: NSRect(x: row.rect.minX + 6 + (22 - w) / 2, y: row.rect.midY - h / 2, width: w, height: h))
            }
            Retro.drawText(L.t(item.titleKey, lang),
                           in: NSRect(x: row.rect.minX + 36, y: row.rect.minY, width: row.rect.width - 52, height: row.rect.height),
                           font: Retro.font(), color: color, smoothing: settings.fontSmoothing)
            if item.hasSubmenu {
                Retro.drawTriangleRight(center: NSPoint(x: row.rect.maxX - 9, y: row.rect.midY), size: 4, color: color)
            }
        }
    }

    private func drawBannerText(in banner: NSRect) {
        let size: CGFloat = 15
        let s = NSMutableAttributedString(string: "Retro", attributes: [.font: Retro.font(bold: true, size: size), .foregroundColor: theme.bannerText])
        s.append(NSAttributedString(string: "Dock ", attributes: [.font: Retro.font(size: size), .foregroundColor: theme.bannerText]))
        s.append(NSAttributedString(string: theme.bannerSuffix, attributes: [.font: Retro.font(bold: true, size: size), .foregroundColor: NSColor.white]))
        let textSize = s.size()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: banner).addClip()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setShouldAntialias(settings.fontSmoothing)
        }
        let t = NSAffineTransform()
        t.translateX(by: banner.minX + (banner.width - textSize.height) / 2, yBy: banner.maxY - 6)
        t.rotate(byDegrees: -90)
        t.concat()
        s.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}
