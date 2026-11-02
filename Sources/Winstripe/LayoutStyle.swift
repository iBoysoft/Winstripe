import AppKit

/// Geometry and behavior resolved once when a theme loads. Strategy fields describe
/// independent layout policies; none encode a theme identity. Missing values use
/// the compiled family default (win95 / win11), then a neutral value.
struct LayoutStyle {
    enum Engine: String { case linear, aero, win8 }
    enum Pins: String { case superbar, quickLaunch }
    enum LabelMode: String { case never, always, byGrouping }
    enum Overflow: String { case shrinkThenHide, shrinkLabelsThenHide }
    enum WidthPolicy: String { case equalShare, measured }
    enum Rounding: String { case none, floorAfterCap }
    enum QuickPlacement: String { case none, separate, group }
    enum TrayWidth: String { case preferred, clamped, remaining }
    enum Cross: String { case fixed, bounds, center }
    enum Extent: String { case fixed, bounds }
    enum TraySizing: String { case button, preferred, fixed }
    enum Anchor: String { case fixed, outer }
    let thickness: CGFloat
    let verticalWidth: CGFloat
    let verticalWidthCombined: CGFloat
    let fitMinWidth: CGFloat
    let reservedSpace: CGFloat
    let reservedSpaceVertical: CGFloat
    let buttonGap: CGFloat
    let taskMin: CGFloat
    let taskMax: CGFloat
    let quickSize: CGFloat
    let quickPitch: CGFloat
    let separatorAdvance: CGFloat
    let labelMin: CGFloat
    let labelMax: CGFloat
    let labelLeading: CGFloat
    let labelIcon: CGFloat
    let labelGap: CGFloat
    let labelTrailing: CGFloat
    let shrinkMin: CGFloat
    let startOverflow: CGFloat
    let engine: Engine
    let pins: Pins
    let labelMode: LabelMode
    let overflow: Overflow
    let groupingDefault: TaskbarGrouping
    let startInGroup: Bool
    let oneButtonPerApp: Bool
    let lTaskWidth: WidthPolicy
    let lRounding: Rounding
    let lSubtractGaps: Bool
    let lQuickPlacement: QuickPlacement
    let lTrayWidth: TrayWidth
    let lButtonCross: Cross
    let lStartCross: Cross
    let lStartX: CGFloat
    let lStartY: CGFloat
    let lStartHeight: CGFloat
    let lStartHeightInset: CGFloat
    let lStartAdvanceGap: CGFloat
    let lTaskY: CGFloat
    let lTaskHeight: CGFloat
    let lTaskHeightInset: CGFloat
    let lIconWidth: CGFloat
    let lPinnedIconWidth: Bool
    let lLabelGap: CGFloat
    let lQuickSeparator: Bool
    let lTaskSeparator: Bool
    let lTrayY: CGFloat
    let lTrayHeight: CGFloat
    let lTrayHeightInset: CGFloat
    let lTrayTrailing: CGFloat
    let lTrayGap: CGFloat
    let lHideGap: CGFloat
    let lAvailableTrailing: CGFloat
    let lEdgeMin: CGFloat
    let lGroupTrayGap: CGFloat
    let lLeading: CGFloat
    let lQuickTrailing: CGFloat
    let vForceIconOnly: Bool
    let vStartY: CGFloat
    let vInset: CGFloat
    let vStartWidth: Extent
    let vStartSize: CGFloat
    let vStartHeight: CGFloat
    let vAfterStartGap: CGFloat
    let vButtonHeight: CGFloat
    let vTaskWidth: Extent
    let vTaskSize: CGFloat
    let vTaskPitch: CGFloat
    let vLabelledWidth: CGFloat
    let vLabelledPitch: CGFloat
    let vQuickLaunchWrap: Bool
    let vQuickLaunchPitch: CGFloat
    let vPinnedQuickLaunchCentered: Bool
    let vQuickLaunchHideReserve: CGFloat
    let vAfterQuickLaunchGap: CGFloat
    let vHideTaskGap: CGFloat
    let vTaskHideHeight: CGFloat
    let vTraySizing: TraySizing
    let vTrayHeight: CGFloat
    let vTrayMinY: CGFloat
    let vTrayInsetBottom: CGFloat
    let vTrayReserve: CGFloat
    let aTaskHeight: CGFloat
    let aVerticalTaskHeight: CGFloat
    let aOrbSize: CGFloat
    let aOrbX: CGFloat
    let aOrbY: CGFloat
    let aOrbAnchor: Anchor
    let aOrbVerticalY: CGFloat
    let aOrbWidthInset: CGFloat
    let aContentLeading: CGFloat
    let aTrayVerticalReserve: CGFloat
    let aAfterOrbGap: CGFloat
    let aQuickSize: CGFloat
    let aQuickPitch: CGFloat
    let aQuickHideGap: CGFloat
    let aQuickSeparatorGap: CGFloat
    let aQuickSeparatorGapVertical: CGFloat
    let aTaskWidthInset: CGFloat
    let aIconWidth: CGFloat
    let aLimitPinnedWidth: Bool
    let aCombinedWidth: CGFloat
    let aLabelledWidth: CGFloat
    let aMinWidth: CGFloat
    let aFitGap: CGFloat
    let aTaskGap: CGFloat
    let aTaskGapVertical: CGFloat
    let cSize: CGFloat
    let cSmallSize: CGFloat
    let cTaskWidth: CGFloat
    let cStartGap: CGFloat
    let cTrayReserve: CGFloat
    let cHideGap: CGFloat
    let cGap: CGFloat
    let searchX: CGFloat
    let searchMinWidth: CGFloat
    let searchMaxWidth: CGFloat
    let searchWidthFraction: CGFloat
    let searchHeightInset: CGFloat
    let searchGapAfter: CGFloat
    let searchVerticalSize: CGFloat
    let taskViewWidth: CGFloat
    let taskViewGapAfter: CGFloat
    let taskViewVerticalSize: CGFloat
    let desktopWidth: CGFloat
    let desktopHeight: CGFloat
    let desktopPitch: CGFloat
    let fixedItems: [String]
    let alignmentOptions: [String]
    let forcedSmoothing: Bool
    let startWidth: CGFloat
    let startIncludesLabel: Bool
    let startFont, measureFont: NSFont
    let material: String
    let barColor: ThemeColor
    let barAlpha: CGFloat
    let appliesBarAlpha: Bool
    let barStops: [ThemeColor]
    let barAngle, barVerticalAngleOffset: CGFloat
    let acrylicColor: ThemeColor
    let acrylicEdge: Edge
    let usesSettingColor: Bool
    let glass: Glass
    let edges: [String: [Edge]]
    struct Edge { let color: ThemeColor; let width: CGFloat }
    struct Glass {
        let tint: ThemeColor
        let sheenTop, sheenBottom, verticalSheenTop, verticalSheenBottom, sheenFraction, edgeWidth: CGFloat
        let verticalFullSheen: Bool
        let outer, inner, separatorDark, separatorLight: ThemeColor
        let separatorVerticalInset, separatorHorizontalInset, separatorWidth: CGFloat
    }

    init() { self.init(ThemeLoader().load("win95").theme) }
    init(_ resolved: ResolvedTheme) {
        let json = resolved.json
        let defaults = ThemeLoader.resolvedBuiltinJSON(resolved.config.family == .classic ? "win95" : "win11")
        func node(_ path: String) -> ThemeJSON? {
            let parts = path.split(separator: ".").map(String.init)
            return json.at(parts) ?? defaults.at(parts)
        }
        func n(_ path: String, _ fallback: CGFloat = 0) -> CGFloat { CGFloat(node(path)?.number ?? Double(fallback)) }
        func s(_ path: String, _ fallback: String = "") -> String { node(path)?.string ?? fallback }
        func b(_ path: String) -> Bool { node(path) == .bool(true) }
        func color(_ path: String) -> ThemeColor {
            (try? ThemeColor.parse(node(path) ?? .string("system:clear"), palette: resolved.config.palette)) ?? .system("clear")
        }
        func font(_ path: String) -> NSFont {
            var value = node(path)
            if let ref = value?["ref"]?.string { value = node("fonts." + ref) }
            let size = CGFloat(value?["size"]?.number ?? 0)
            let family = value?["family"]?.string ?? "system"
            if family == "system" { return .systemFont(ofSize: size) }
            return NSFont(name: family, size: size)
                ?? (value?["fallback"]?.string == "systemBold" ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }
        thickness = n("metrics.barThickness")
        verticalWidth = n("metrics.verticalBarWidth")
        verticalWidthCombined = n("metrics.verticalBarWidthWhenCombined", n("metrics.verticalBarWidth"))
        fitMinWidth = n("layout.grouping.fitMinWidth")
        reservedSpace = n("layout.grouping.reservedSpace")
        reservedSpaceVertical = n("layout.grouping.reservedSpaceVertical")
        buttonGap = n("metrics.buttonGap")
        taskMin = n("metrics.taskButton.minWidth")
        taskMax = n("metrics.taskButton.maxWidth")
        quickSize = n("metrics.quickLaunch.buttonSize")
        quickPitch = n("metrics.quickLaunch.pitch")
        separatorAdvance = n("metrics.separator.advance")
        labelMin = n("metrics.taskButton.labelled.minWidth")
        labelMax = n("metrics.taskButton.labelled.maxWidth")
        labelLeading = n("metrics.taskButton.labelled.padding.leading")
        labelIcon = n("metrics.taskButton.iconSizeLabelled")
        labelGap = n("metrics.taskButton.labelled.padding.iconGap")
        labelTrailing = n("metrics.taskButton.labelled.padding.trailing")
        shrinkMin = n("metrics.taskButton.labelled.shrinkMin")
        startOverflow = n("startButton.overflow.outer")
        engine = Engine(rawValue: s("layout.engine")) ?? .linear
        pins = Pins(rawValue: s("layout.pins")) ?? .superbar
        labelMode = LabelMode(rawValue: s("layout.labelMode")) ?? .never
        overflow = Overflow(rawValue: s("layout.overflow")) ?? .shrinkThenHide
        groupingDefault = TaskbarGrouping(rawValue: s("layout.groupingDefault")) ?? .neverCombine
        startInGroup = b("layout.startInGroup")
        oneButtonPerApp = b("layout.classicOneButtonPerAppWidth")
        lTaskWidth = WidthPolicy(rawValue: s("layout.linear.taskWidth")) ?? .equalShare
        lRounding = Rounding(rawValue: s("layout.linear.rounding")) ?? .none
        lSubtractGaps = b("layout.linear.subtractGaps")
        lQuickPlacement = QuickPlacement(rawValue: s("layout.linear.quickPlacement")) ?? .none
        lTrayWidth = TrayWidth(rawValue: s("layout.linear.trayWidth")) ?? .preferred
        lButtonCross = Cross(rawValue: s("layout.linear.buttonCross")) ?? .fixed
        lStartCross = Cross(rawValue: s("layout.linear.startCross")) ?? .fixed
        lStartX = n("startButton.position.x", n("layout.linear.startX"))
        lStartY = n("startButton.position.y", n("layout.linear.startY"))
        lStartHeight = n("metrics.params.startButtonHeight", n("metrics.buttonHeight", n("layout.linear.startHeight")))
        lStartHeightInset = n("layout.linear.startHeightInset")
        lStartAdvanceGap = n("metrics.startToContentGap", n("layout.linear.startAdvanceGap"))
        lTaskY = n("metrics.contentInset.top", n("layout.linear.taskY"))
        lTaskHeight = n("metrics.params.taskButtonHeight", n("metrics.buttonHeight", n("layout.linear.taskHeight")))
        lTaskHeightInset = n("layout.linear.taskHeightInset")
        lIconWidth = n("layout.linear.iconWidth")
        lPinnedIconWidth = b("layout.linear.pinnedIconWidth")
        lLabelGap = n("layout.linear.labelGap")
        lQuickSeparator = b("layout.linear.quickSeparator")
        lTaskSeparator = b("layout.linear.taskSeparator")
        lTrayY = n("metrics.contentInset.top", n("layout.linear.trayY"))
        lTrayHeight = n("metrics.params.trayHeight", n("metrics.buttonHeight", n("layout.linear.trayHeight")))
        lTrayHeightInset = n("layout.linear.trayHeightInset")
        lTrayTrailing = n("metrics.trayInset.trailing", n("layout.linear.trayTrailing"))
        lTrayGap = n("metrics.trayInset.gapBeforeTray", n("layout.linear.trayGap"))
        lHideGap = n("metrics.trayInset.hideTaskIfWithin", n("layout.linear.hideGap"))
        lAvailableTrailing = n("layout.linear.availableTrailing")
        lEdgeMin = n("layout.linear.edgeMin")
        lGroupTrayGap = n("layout.linear.groupTrayGap")
        lLeading = n("metrics.contentInset.left", n("layout.linear.leading"))
        lQuickTrailing = n("metrics.quickLaunch.trailingGap", n("layout.linear.quickTrailing"))
        vForceIconOnly = b("layout.vertical.forceIconOnly")
        vStartY = n("layout.vertical.startY")
        vInset = n("layout.vertical.inset")
        vStartWidth = Extent(rawValue: s("layout.vertical.startWidth")) ?? .fixed
        vStartSize = n("layout.vertical.startSize")
        vStartHeight = n("metrics.params.startButtonHeight", n("layout.vertical.startHeight"))
        vAfterStartGap = n("layout.vertical.afterStartGap")
        vButtonHeight = n("metrics.params.taskButtonHeight", n("layout.vertical.buttonHeight"))
        vTaskWidth = Extent(rawValue: s("layout.vertical.taskWidth")) ?? .fixed
        vTaskSize = n("layout.vertical.taskSize")
        vTaskPitch = n("layout.vertical.taskPitch")
        vLabelledWidth = n("layout.vertical.labelledWidth")
        vLabelledPitch = n("layout.vertical.labelledPitch")
        vQuickLaunchWrap = b("layout.vertical.quickLaunchWrap")
        vQuickLaunchPitch = n("layout.vertical.quickLaunchPitch")
        vPinnedQuickLaunchCentered = b("layout.vertical.pinnedQuickLaunchCentered")
        vQuickLaunchHideReserve = n("layout.vertical.quickLaunchHideReserve")
        vAfterQuickLaunchGap = n("layout.vertical.afterQuickLaunchGap")
        vHideTaskGap = n("layout.vertical.hideTaskGap")
        vTaskHideHeight = n("metrics.params.taskButtonHeight", n("layout.vertical.taskHideHeight"))
        vTraySizing = TraySizing(rawValue: s("layout.vertical.traySizing")) ?? .button
        vTrayHeight = n("metrics.params.trayHeight", n("layout.vertical.trayHeight"))
        vTrayMinY = n("layout.vertical.trayMinY")
        vTrayInsetBottom = n("layout.vertical.trayInsetBottom")
        vTrayReserve = n("layout.vertical.trayReserve")
        aTaskHeight = n("layout.aero.taskHeight")
        aVerticalTaskHeight = n("layout.aero.verticalTaskHeight")
        aOrbSize = n("layout.aero.orbSize")
        aOrbX = n("layout.aero.orbX")
        aOrbY = n("layout.aero.orbY")
        aOrbAnchor = Anchor(rawValue: s("layout.aero.orbAnchor")) ?? .fixed
        aOrbVerticalY = n("layout.aero.orbVerticalY")
        aOrbWidthInset = n("layout.aero.orbWidthInset")
        aContentLeading = n("layout.aero.contentLeading")
        aTrayVerticalReserve = n("layout.aero.trayVerticalReserve")
        aAfterOrbGap = n("layout.aero.afterOrbGap")
        aQuickSize = n("layout.aero.quickSize")
        aQuickPitch = n("layout.aero.quickPitch")
        aQuickHideGap = n("layout.aero.quickHideGap")
        aQuickSeparatorGap = n("layout.aero.quickSeparatorGap")
        aQuickSeparatorGapVertical = n("layout.aero.quickSeparatorGapVertical")
        aTaskWidthInset = n("layout.aero.taskWidthInset")
        aIconWidth = n("layout.aero.iconWidth")
        aLimitPinnedWidth = b("layout.aero.limitPinnedWidth")
        aCombinedWidth = n("layout.aero.combinedWidth")
        aLabelledWidth = n("layout.aero.labelledWidth")
        aMinWidth = n("layout.aero.minWidth")
        aFitGap = n("layout.aero.fitGap")
        aTaskGap = n("layout.aero.taskGap")
        aTaskGapVertical = n("layout.aero.taskGapVertical")
        cSize = n("layout.compact.size")
        cSmallSize = n("layout.compact.smallSize")
        cTaskWidth = n("layout.compact.taskWidth")
        cStartGap = n("layout.compact.startGap")
        cTrayReserve = n("layout.compact.trayReserve")
        cHideGap = n("layout.compact.hideGap")
        cGap = n("layout.compact.gap")
        searchX = n("layout.fixedItemParams.search.x")
        searchMinWidth = n("layout.fixedItemParams.search.minWidth")
        searchMaxWidth = n("layout.fixedItemParams.search.maxWidth")
        searchWidthFraction = n("layout.fixedItemParams.search.widthFraction")
        searchHeightInset = n("layout.fixedItemParams.search.heightInset")
        searchGapAfter = n("layout.fixedItemParams.taskView.gap")
        searchVerticalSize = n("layout.fixedItemParams.search.verticalSize")
        taskViewWidth = n("layout.fixedItemParams.taskView.width")
        taskViewGapAfter = n("layout.fixedItemParams.taskView.gapAfter")
        taskViewVerticalSize = n("layout.fixedItemParams.taskView.verticalSize")
        desktopWidth = n("layout.fixedItemParams.showDesktop.width")
        desktopHeight = n("layout.fixedItemParams.showDesktop.height")
        desktopPitch = n("layout.fixedItemParams.showDesktop.pitch")
        fixedItems = resolved.config.layout.fixedItems
        alignmentOptions = resolved.config.layout.alignmentOptions
        forcedSmoothing = s("fonts.smoothing") == "forcedOn"
        let width = node("startButton.size.width")
        let expression = width?.string ?? ""
        startIncludesLabel = expression.hasPrefix("label+")
        startWidth = CGFloat(width?.number ?? Double(expression.dropFirst("label+".count)) ?? 0)
        startFont = font("startButton.label.font")
        measureFont = font("metrics.taskButton.labelled.measureFont")
        material = resolved.config.bar.material.type
        barColor = color("bar.material.color")
        barAlpha = n("bar.material.alpha", 1)
        appliesBarAlpha = node("bar.material.alpha")?.number != nil
        barStops = (resolved.config.bar.material.stops ?? []).map { stop in
            (try? ThemeColor.parse(stop["color"] ?? stop, palette: resolved.config.palette)) ?? .system("clear")
        }
        barAngle = n("bar.material.angle")
        barVerticalAngleOffset = n("bar.material.params.verticalAngleOffset")
        acrylicColor = color("bar.material.snapshotFallback")
        let edge = resolved.config.bar.edge["all"]?.first
        acrylicEdge = Edge(color: (try? ThemeColor.parse(edge?.color ?? .string("system:clear"), palette: resolved.config.palette)) ?? .system("clear"),
                           width: CGFloat(edge?.width ?? 0))
        usesSettingColor = s("bar.material.color") == "setting:win8StartColor"
        edges = resolved.config.bar.edge.mapValues { lines in
            lines.map { Edge(color: (try? ThemeColor.parse($0.color, palette: resolved.config.palette)) ?? .system("clear"), width: CGFloat($0.width)) }
        }
        let p = "bar.material.params."
        glass = Glass(tint: color("bar.material.tint"),
                      sheenTop: n(p + "sheenTop"), sheenBottom: n(p + "sheenBottom"),
                      verticalSheenTop: n(p + "verticalSheenTop"), verticalSheenBottom: n(p + "verticalSheenBottom"),
                      sheenFraction: n(p + "sheenFraction"), edgeWidth: n(p + "edgeWidth"),
                      verticalFullSheen: b(p + "verticalFullSheen"),
                      outer: color(p + "edgeOuterColor"), inner: color(p + "edgeInnerColor"),
                      separatorDark: color(p + "separatorDark"), separatorLight: color(p + "separatorLight"),
                      separatorVerticalInset: n(p + "separatorVerticalInset"),
                      separatorHorizontalInset: n(p + "separatorHorizontalInset"), separatorWidth: n(p + "separatorWidth"))
    }
}
