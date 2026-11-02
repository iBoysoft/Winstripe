import AppKit

// Guarded by `AeroDrawing.iconColorLock`.
private var iconColors: [ObjectIdentifier: (image: NSImage, color: NSColor)] = [:]
private var iconColorsByContent: [AverageColorKey: NSColor] = [:]

@MainActor
enum AeroDrawing {
    private static func topToBottom(_ path: NSBezierPath, colors: [NSColor]) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: colors)?.draw(from: NSPoint(x: path.bounds.midX, y: path.bounds.minY),
                                        to: NSPoint(x: path.bounds.midX, y: path.bounds.maxY),
                                        options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func glass(_ rect: NSRect, vista: Bool, vertical: Bool = false) {
        (vista ? NSColor(hex: 0x000000, alpha: 0.82) : NSColor(hex: 0x2D4B64, alpha: 0.78)).setFill()
        rect.fill()
        if vista && vertical {
            Retro.fill(rect, [NSColor(white: 1, alpha: 0.035), NSColor(white: 1, alpha: 0.01)], vertical: false)
        } else {
            let sheen = vertical
                ? NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
                : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
            let colors = [NSColor(white: 1, alpha: vista ? 0.14 : 0.10),
                          NSColor(white: 1, alpha: vista ? 0.06 : 0)]
            if vertical { Retro.fill(sheen, colors, vertical: false) }
            else { topToBottom(NSBezierPath(rect: sheen), colors: colors) }
        }
        NSColor(white: vista ? 1 : 0, alpha: vista ? 0.4 : 0.9).setFill()
        (vertical ? NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
                  : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)).fill()
        NSColor(white: vista ? 0 : 1, alpha: vista ? 0.8 : 0.25).setFill()
        (vertical ? NSRect(x: rect.minX + 1, y: rect.minY, width: 1, height: rect.height)
                  : NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 1)).fill()
    }

    /// Taskbar glass uses resolved material parameters; menu glass retains its own defaults.
    static func glass(_ rect: NSRect, style: LayoutStyle.Glass, vertical: Bool, settings: TaskbarSettings) {
        style.tint.resolve(settings: settings).setFill()
        rect.fill()
        if style.verticalFullSheen && vertical {
            Retro.fill(rect, [NSColor(white: 1, alpha: style.verticalSheenTop), NSColor(white: 1, alpha: style.verticalSheenBottom)], vertical: false)
        } else {
            let sheen = vertical
                ? NSRect(x: rect.minX, y: rect.minY, width: rect.width * style.sheenFraction, height: rect.height)
                : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * style.sheenFraction)
            let colors = [NSColor(white: 1, alpha: style.sheenTop), NSColor(white: 1, alpha: style.sheenBottom)]
            if vertical { Retro.fill(sheen, colors, vertical: false) }
            else { topToBottom(NSBezierPath(rect: sheen), colors: colors) }
        }
        style.outer.resolve(settings: settings).setFill()
        (vertical ? NSRect(x: rect.minX, y: rect.minY, width: style.edgeWidth, height: rect.height)
                  : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: style.edgeWidth)).fill()
        style.inner.resolve(settings: settings).setFill()
        (vertical ? NSRect(x: rect.minX + style.edgeWidth, y: rect.minY, width: style.edgeWidth, height: rect.height)
                  : NSRect(x: rect.minX, y: rect.minY + style.edgeWidth, width: rect.width, height: style.edgeWidth)).fill()
    }

    static func flag(in r: NSRect, style s: StartButtonStyle.AeroFlag) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: r.midX, yBy: r.midY)
        transform.rotate(byDegrees: s.rotation)
        transform.translateX(by: -r.midX, yBy: -r.midY)
        transform.concat()
        func point(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
            NSPoint(x: r.minX + (u + s.shear * (0.5 - v)) * r.width,
                    y: r.minY + (v + s.waveAmplitude * sin(u * .pi * s.waveFrequency) + s.tilt * u * (v - 0.5)) * r.height)
        }
        // Opposite control-point offsets give each pane a gentle S-shaped edge.
        func edge(_ path: NSBezierPath, from u0: CGFloat, to u1: CGFloat, at v: CGFloat) {
            let delta = u1 - u0
            let start = point(u0, v), end = point(u1, v)
            let wave = (delta > 0 ? 1.0 : -1.0) * r.height * s.edgeWave
            let rise = (end.y - start.y) / 3
            path.curve(to: end,
                       controlPoint1: NSPoint(x: start.x + delta * r.width / 3,
                                              y: start.y + rise - wave),
                       controlPoint2: NSPoint(x: end.x - delta * r.width / 3,
                                              y: end.y - rise + wave))
        }
        var panes: [NSBezierPath] = []
        for row in 0..<2 {
            for col in 0..<2 {
                let left: CGFloat = s.left[col]
                let right: CGFloat = s.right[col]
                let top: CGFloat = s.top[row]
                let bottom: CGFloat = s.bottom[row]
                let p = NSBezierPath()
                p.move(to: point(left, top))
                edge(p, from: left, to: right, at: top)
                p.line(to: point(right, bottom))
                edge(p, from: right, to: left, at: bottom)
                p.close()
                panes.append(p)
            }
        }
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = s.glowColor.color
        glow.shadowBlurRadius = r.width * s.glowRadius
        glow.shadowOffset = .zero
        glow.set()
        s.glowFill.color.setFill()
        panes.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()
        for (index, pane) in panes.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            pane.addClip()
            let color = s.colors[index].color
            topToBottom(pane, colors: [color.blended(withFraction: s.highlight, of: s.highlightColor.color) ?? color, color])
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func orb(in rect: NSRect, style s: StartButtonStyle.Orb, flagStyle: StartButtonStyle.AeroFlag, hovered: Bool, pressed: Bool) {
        let r = rect.insetBy(dx: s.inset, dy: s.inset)
        if hovered {
            NSGradient(starting: s.glowColor.color, ending: s.glowEnd.color)?
                .draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: s.glowInset, dy: s.glowInset)), relativeCenterPosition: .zero)
        }
        let sphere = NSBezierPath(ovalIn: r)
        NSGraphicsContext.saveGraphicsState()
        sphere.addClip()
        var colors = s.colors.map { $0.color }
        if hovered && !pressed { colors = colors.map { $0.blended(withFraction: s.hoverBlend, of: s.hoverColor.color) ?? $0 } }
        // Radial orbs need 3 stops; a user theme with fewer falls back to linear.
        if !s.radial || colors.count < 3 { topToBottom(sphere, colors: colors) }
        else {
            NSGradient(colors: [colors[1], colors[2], colors[0]])?
                .draw(fromCenter: NSPoint(x: r.midX, y: r.midY + r.height * s.radialOffset), radius: 0,
                      toCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                      options: [.drawsAfterEndingLocation])
        }
        topToBottom(NSBezierPath(ovalIn: NSRect(x: r.minX + s.sheenX, y: r.minY + s.sheenY,
                                               width: r.width - s.sheenWidthInset, height: r.height * s.sheenHeight)),
                    colors: s.sheenColors.map { $0.color })
        let logo = NSRect(x: r.midX - r.width * s.logoX, y: r.midY - r.height * s.logoY,
                          width: r.width * s.logoWidth, height: r.height * s.logoHeight)
        flag(in: logo, style: flagStyle)
        if pressed { s.pressedColor.color.setFill(); r.fill() }
        NSGraphicsContext.restoreGraphicsState()
        s.borderColor.color.setStroke()
        sphere.lineWidth = s.borderWidth
        sphere.stroke()
    }

    static func button(_ r: NSRect, active: Bool, hovered: Bool, pressed: Bool, hotColor: NSColor? = nil,
                       style: AeroButtonStyle = AeroButtonStyle(inset: 1.5, radius: 3, normalAlpha: 0.12, hoverAlpha: 0.20, pressedAlpha: 0.05, lowerAlpha: 0.08,
                                                                  highlightAlpha: 0.12, activeAlpha: 0.32, activeHighlightAlpha: 0.24,
                                                                  borderAlpha: 0.30, activeBorderAlpha: 0.60, innerBorderAlpha: 0.45, hotTrack: false)) {
        let rect = r.insetBy(dx: style.inset, dy: style.inset)
        let p = NSBezierPath(roundedRect: rect, xRadius: style.radius, yRadius: style.radius)
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        Retro.fill(rect, [NSColor(white: 1, alpha: active ? style.activeAlpha : (hovered ? style.hoverAlpha : style.normalAlpha)),
                          NSColor(white: 1, alpha: pressed ? style.pressedAlpha : style.lowerAlpha)])
        Retro.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2),
                   [NSColor(white: 1, alpha: active ? style.activeHighlightAlpha : style.highlightAlpha), .clear])
        if hovered, let hotColor {
            NSGradient(starting: hotColor.withAlphaComponent(0.9), ending: hotColor.withAlphaComponent(0))?
                .draw(in: p, relativeCenterPosition: NSPoint(x: 0, y: 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: active ? style.activeBorderAlpha : style.borderAlpha).setStroke()
        p.lineWidth = 1
        p.stroke()
        NSColor(white: 0, alpha: style.innerBorderAlpha).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).stroke()
    }

    nonisolated private static let iconColorLock = NSLock()
    nonisolated static func averageColor(_ image: NSImage) -> NSColor {
        iconColorLock.lock()
        if let cached = iconColors[ObjectIdentifier(image)]?.color {
            iconColorLock.unlock()
            return cached
        }
        iconColorLock.unlock()
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return .systemBlue }
        let contentKey = AverageColorKey(cg)
        iconColorLock.lock()
        if let cached = iconColorsByContent[contentKey] {
            storeIconColor(cached, for: image)
            iconColorLock.unlock()
            return cached
        }
        iconColorLock.unlock()
        return .systemBlue
    }

    nonisolated static func prewarmAverageColors(_ images: [NSImage], completion: @escaping () -> Void) {
        guard !images.isEmpty else {
            completion()
            return
        }
        let unique = Array(Dictionary(firstWins: images.map { (ObjectIdentifier($0), $0) }).values)
        DispatchQueue.global(qos: .utility).async {
            for image in unique { _ = computeAverageColor(image) }
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func averageColorSync(_ image: NSImage) -> NSColor { computeAverageColor(image) }

    nonisolated private static func computeAverageColor(_ image: NSImage) -> NSColor {
        iconColorLock.lock()
        if let cached = iconColors[ObjectIdentifier(image)]?.color {
            iconColorLock.unlock()
            return cached
        }
        iconColorLock.unlock()
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return .systemBlue }
        let contentKey = AverageColorKey(cg)
        iconColorLock.lock()
        if let cached = iconColorsByContent[contentKey] {
            storeIconColor(cached, for: image)
            iconColorLock.unlock()
            return cached
        }
        iconColorLock.unlock()
        let rep = NSBitmapImageRep(cgImage: cg)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, count: CGFloat = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 24)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 24)) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.8 else { continue }
                red += color.redComponent; green += color.greenComponent; blue += color.blueComponent; count += 1
            }
        }
        let result = count > 0 ? NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1) : .systemBlue
        iconColorLock.lock()
        if iconColorsByContent.count > 512 { iconColorsByContent.removeAll(keepingCapacity: true) }
        iconColorsByContent[contentKey] = result
        storeIconColor(result, for: image)
        iconColorLock.unlock()
        return result
    }

    nonisolated private static func storeIconColor(_ color: NSColor, for image: NSImage) {
        if iconColors.count > 512 { iconColors.removeAll(keepingCapacity: true) }
        iconColors[ObjectIdentifier(image)] = (image, color)
    }

    static func wallpaper(_ r: NSRect, vista: Bool) {
        Retro.fill(r, vista ? [NSColor(hex: 0x164E43), NSColor(hex: 0x072D35)]
                           : [NSColor(hex: 0x5FA8E0), NSColor(hex: 0x1E6FB8)])
    }

    static func userPicture(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
        topToBottom(NSBezierPath(rect: rect), colors: [NSColor(hex: 0x6EC6F0), NSColor(hex: 0x2A8BD0)])
        let center = NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.03)
        NSColor(hex: 0x408227).setStroke()
        let stem = NSBezierPath()
        stem.lineWidth = 2
        stem.move(to: center)
        stem.curve(to: NSPoint(x: center.x - 2, y: rect.maxY + 2),
                   controlPoint1: NSPoint(x: center.x + 5, y: rect.midY + 10),
                   controlPoint2: NSPoint(x: center.x - 3, y: rect.maxY - 3))
        stem.stroke()
        for index in 0..<12 {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: CGFloat(index) * 30)
            transform.concat()
            let petal = NSBezierPath(ovalIn: NSRect(x: -rect.width * 0.08, y: -rect.height * 0.39,
                                                   width: rect.width * 0.16, height: rect.height * 0.34))
            topToBottom(petal, colors: [NSColor(hex: 0xFFB21E), NSColor(hex: 0xE8590C)])
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(starting: NSColor(hex: 0x784419), ending: NSColor(hex: 0xC97212))?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - rect.width * 0.12, y: center.y - rect.height * 0.12,
                                                 width: rect.width * 0.24, height: rect.height * 0.24)),
                  relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class AeroMenuRow: NSView {
    var title = ""
    var subtitle: String?
    var icon: NSImage?
    var whiteText = false
    var arrow = false
    var back = false
    var leadingArrow = false
    var power = false
    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    var hoverEnabled = true
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    private(set) var hovered = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard hoverEnabled else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        guard hoverEnabled else { return }
        hovered = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        guard hoverEnabled else { return }
        hovered = false; needsDisplay = true
    }
    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if power {
            Retro.fill(bounds.insetBy(dx: 0.5, dy: 0.5), [NSColor(hex: 0xE8A23A), NSColor(hex: 0xB5620F)], radius: 3)
        } else if hovered {
            if whiteText { AeroDrawing.button(bounds, active: false, hovered: true, pressed: false) }
            else {
                Retro.fill(bounds.insetBy(dx: 0.5, dy: 0.5), [NSColor(hex: 0xEDF5FF), NSColor(hex: 0xDCEBFC)], radius: 3)
                NSColor(hex: 0x7DA2CE).setStroke()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            }
        }
        let color: NSColor = whiteText ? .white : .black
        var x: CGFloat = 9
        if let icon {
            let size: CGFloat = whiteText ? 16 : 32
            Retro.drawImage(icon, in: NSRect(x: title.isEmpty ? bounds.midX - size / 2 : 7,
                                             y: bounds.midY - size / 2, width: size, height: size))
            x = size + 15
        }
        if back {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 20, yBy: 0); transform.scaleX(by: -1, yBy: 1); transform.concat()
            Retro.drawTriangleRight(center: NSPoint(x: 8, y: bounds.midY), size: 4, color: color)
            NSGraphicsContext.restoreGraphicsState()
            x = 25
        } else if leadingArrow {
            Retro.drawTriangleRight(center: NSPoint(x: 12, y: bounds.midY), size: 4, color: color)
            x = 25
        }
        if let subtitle {
            Retro.drawText(title, in: NSRect(x: x, y: 3, width: bounds.width - x - 8, height: 20),
                           font: .systemFont(ofSize: 12, weight: .semibold), color: color, smoothing: true)
            Retro.drawText(subtitle, in: NSRect(x: x, y: 23, width: bounds.width - x - 8, height: 18),
                           font: .systemFont(ofSize: 11), color: .gray, smoothing: true)
        } else {
            Retro.drawText(title, in: NSRect(x: x, y: 0, width: max(0, bounds.width - x - (arrow ? 19 : 5)), height: bounds.height),
                           font: .systemFont(ofSize: 12), color: color, smoothing: true)
        }
        if arrow {
            Retro.drawTriangleRight(center: NSPoint(x: bounds.maxX - 10, y: bounds.midY), size: 4, color: color)
        }
    }
}

@MainActor
private final class AeroProgramList: NSView {
    private var boundsObserver: NSObjectProtocol?
    private var hoveredRow: AeroMenuRow?
    var separatorY: CGFloat? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let separatorY else { return }
        NSColor(hex: 0xD6D6D6).setFill()
        NSRect(x: 6, y: separatorY, width: max(0, bounds.width - 14), height: 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    func attach(to scrollView: NSScrollView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearHover()
                self.recomputeHoverFromCurrentMouse()
            }
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    private var rows: [AeroMenuRow] { subviews.compactMap { $0 as? AeroMenuRow } }

    var hoveredRowIndices: [Int] {
        guard let hoveredRow, let index = rows.firstIndex(where: { $0 === hoveredRow }) else { return [] }
        return [index]
    }

    func clearHover() {
        hoveredRow = nil
        rows.forEach { $0.setHovered(false) }
    }

    func setHover(atListPoint point: NSPoint?) {
        let next = point.flatMap { p in rows.first { $0.frame.contains(p) } }
        hoveredRow = next
        rows.forEach { $0.setHovered($0 === next) }
    }

    func recomputeHoverFromCurrentMouse() {
        guard let window else {
            clearHover()
            return
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        if let clip = enclosingScrollView?.contentView {
            let clipPoint = clip.convert(windowPoint, from: nil)
            guard clip.bounds.contains(clipPoint) else {
                clearHover()
                return
            }
        }
        let point = convert(windowPoint, from: nil)
        setHover(atListPoint: bounds.contains(point) ? point : nil)
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(atListPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(atListPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        clearHover()
        recomputeHoverFromCurrentMouse()
    }
}

@MainActor
private final class AeroSearchCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 23, y: rect.midY - 9, width: 18, height: 18)
    }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { .zero }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 6, y: rect.minY + 3, width: max(0, rect.width - 32), height: max(0, rect.height - 6))
    }
}

@MainActor
final class AeroStartMenuView: NSView, NSSearchFieldDelegate {
    private let settings: TaskbarSettings
    private var apps: [Win10StartMenuView.Application]
    private var webFolders: [CollectionFolder]
    private var webItems: [CollectionItem]
    private var expandedWebFolders = Set<String>()
    private let preservesAllAppsSnapshot: Bool
    private var preferredPrograms: [Win10StartMenuView.Application] = []
    private var pinnedTitles: [String] = []
    private var programSeparatorY: CGFloat?
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let list = AeroProgramList()
    private let allPrograms = AeroMenuRow()
    private var links: [AeroMenuRow] = []
    private var toolbar: [AeroMenuRow] = []
    private var separatorYs: [CGFloat] = []
    private(set) var allApps: Bool
    var onLaunch: ((AppListEntry) -> Void)?
    var onCommand: ((StartItem) -> Void)?
    private var vista: Bool { settings.startMenuStyle == .vista }
    private var paneWidth: CGFloat { min(vista ? 250 : 255, bounds.width * 0.64) }
    private var filtered: [Win10StartMenuView.Application] {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let web = (webItems + webFolders.flatMap(\.items)).map(Win10StartMenuView.Application.init(collectionItem:))
            return (apps + web).filter { $0.name.localizedStandardContains(query) }
        }
        if allApps {
            guard !webItems.isEmpty else { return apps }
            return (apps + webItems.map(Win10StartMenuView.Application.init(collectionItem:)))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return preferredPrograms
    }

    /// Drops an entry just hidden. One shown again returns when the menu next opens.
    @objc private func hiddenEntriesChanged() {
        let hidden = HiddenStore().snapshot()
        apps.removeAll { hidden.isHidden(app: $0.url) }
        webFolders = AppCollections.folders(settings: settings)
        webItems = AppCollections.rootItems(settings: settings)
        pinnedTitles = []
        preferredPrograms = loadPreferredPrograms()
        let offset = scroll.contentView.bounds.origin
        rebuildPrograms()
        list.scroll(offset)
    }

    private func loadPreferredPrograms() -> [Win10StartMenuView.Application] {
        if SnapshotFixture.isActive, ApplicationCatalog.override != nil {
            pinnedTitles = ["Internet", "E-mail"]
            return apps
        }
        var result: [Win10StartMenuView.Application] = []
        var seen: Set<URL> = []
        func append(_ app: Win10StartMenuView.Application) -> Bool {
            guard seen.insert(app.url.resolvingSymlinksInPath().standardizedFileURL).inserted else { return false }
            result.append(app)
            return true
        }
        for (address, title) in [("https://example.com", "Internet"), ("mailto:", "E-mail")] {
            let url = URL(string: address).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            let app = url.flatMap { target in
                apps.first { $0.url.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() }
            } ?? apps.first { !seen.contains($0.url.resolvingSymlinksInPath().standardizedFileURL) }
            if let app, append(app) { pinnedTitles.append(title) }
        }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let url = running.bundleURL else { continue }
            if let app = apps.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
                _ = append(app)
            }
        }
        for app in apps { _ = append(app) }
        return Array(result.prefix(pinnedTitles.count + 9))
    }

    init(settings: TaskbarSettings, searchText: String = "", allApps: Bool = false,
         applications: [Win10StartMenuView.Application]? = nil, preserveAllAppsSnapshot: Bool = false) {
        self.settings = settings
        self.allApps = allApps
        self.preservesAllAppsSnapshot = preserveAllAppsSnapshot
        self.webFolders = AppCollections.folders(settings: settings)
        self.webItems = AppCollections.rootItems(settings: settings)
        var catalog = applications ?? Win10StartMenuView.loadApplications()
        if applications == nil && !preserveAllAppsSnapshot && !(SnapshotFixture.isActive && ApplicationCatalog.override != nil) {
            for address in ["https://example.com", "mailto:"] {
                guard let resource = URL(string: address),
                      let url = NSWorkspace.shared.urlForApplication(toOpen: resource),
                      !catalog.contains(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else { continue }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                catalog.append(Win10StartMenuView.Application(url: url, name: name,
                                                              icon: NSWorkspace.shared.icon(forFile: url.path)))
            }
            for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
                guard let url = running.bundleURL,
                      !catalog.contains(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else { continue }
                let name = running.localizedName ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                catalog.append(Win10StartMenuView.Application(url: url, name: name,
                                                              icon: running.icon ?? NSWorkspace.shared.icon(forFile: url.path)))
            }
        }
        self.apps = applications != nil || (SnapshotFixture.isActive && ApplicationCatalog.override != nil) ? catalog :
            catalog.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let height: CGFloat = preserveAllAppsSnapshot ? (settings.startMenuStyle == .vista ? 548 : 563) : (settings.startMenuStyle == .vista ? 520 : 535)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        preferredPrograms = loadPreferredPrograms()
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenEntriesChanged), name: HiddenStore.didChange, object: nil)
        search.cell = AeroSearchCell(textCell: "")
        search.stringValue = searchText
        search.placeholderString = L.t(vista ? "Start Search" : "Search programs and files", settings.resolvedLanguage)
        search.font = NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor.withSymbolicTraits(.italic), size: 12)
        search.focusRingType = .none
        search.isEditable = true
        search.isSelectable = true
        search.isBezeled = true
        search.drawsBackground = true
        search.backgroundColor = .white
        search.textColor = .black
        search.bezelStyle = vista ? .squareBezel : .roundedBezel
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.cell?.backgroundStyle = .normal
        if let cell = search.cell as? NSSearchFieldCell {
            cell.cancelButtonCell = nil
            cell.searchButtonCell?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .symbolTinted([NSColor(hex: 0x287BB4)])
        }
        addSubview(search)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        list.attach(to: scroll)
        addSubview(scroll)
        allPrograms.onClick = { [weak self] in
            guard let self else { return }
            self.allApps.toggle()
            self.search.stringValue = ""
            self.rebuildPrograms()
            self.list.scroll(.zero)
        }
        addSubview(allPrograms)
        buildLinks()
        buildToolbar()
        arrange()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func focusSearch() { window?.makeFirstResponder(search) }
    override func layout() { super.layout(); arrange() }
    func controlTextDidChange(_ obj: Notification) { searchChanged() }
    @objc private func searchChanged() {
        rebuildPrograms()
        list.scroll(.zero)
        needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let app = filtered.first { onLaunch?(app.listEntry) }
            return true
        }
        return false
    }

    private func arrange() {
        let left = paneWidth
        search.frame = NSRect(x: 10, y: max(34, bounds.height - 34), width: max(0, left - 18), height: 24)
        allPrograms.frame = NSRect(x: 8, y: max(34, bounds.height - 68), width: max(0, left - 12), height: 28)
        scroll.frame = NSRect(x: 8, y: 36, width: max(0, left - 12), height: max(0, allPrograms.frame.minY - 39))
        var y: CGFloat = 80
        separatorYs = []
        let rowHeight = min(vista ? 26 : 31, max(0, (bounds.height - 134) / CGFloat(links.count)))
        for (index, row) in links.enumerated() {
            if (vista && (index == 5 || index == 10)) || (!vista && (index == 4 || index == 6)) {
                separatorYs.append(y + 2); y += 8
            }
            row.frame = NSRect(x: left + 6, y: y, width: max(0, bounds.width - left - 14), height: rowHeight)
            y += rowHeight
        }
        let rightWidth = max(0, bounds.width - left - 16)
        let widths: [CGFloat] = vista ? [rightWidth * 0.47, rightWidth * 0.32, rightWidth * 0.21] : [rightWidth - 23, 23]
        var x = left + 8
        for (index, row) in toolbar.enumerated() {
            row.frame = NSRect(x: x, y: bounds.height - 35, width: max(0, widths[index]), height: 27)
            x += widths[index]
        }
        rebuildPrograms()
        needsDisplay = true
    }

    private func rebuildPrograms() {
        list.clearHover()
        list.subviews.forEach { $0.removeFromSuperview() }
        list.separatorY = nil
        let programs = filtered
        let preferredMode = !allApps && search.stringValue.isEmpty
        let pinnedCount = preferredMode ? pinnedTitles.count : 0
        let pinnedHeight: CGFloat = vista ? 46 : 40
        let regularCount = max(1, programs.count - pinnedCount)
        let available = scroll.contentSize.height - 4 - CGFloat(pinnedCount) * pinnedHeight - 10
        let regularHeight: CGFloat = preferredMode ? max(34, min(40, available / CGFloat(regularCount))) : 40
        programSeparatorY = nil
        var y: CGFloat = 2
        for (index, app) in programs.enumerated() {
            if preferredMode && index == pinnedCount && pinnedCount > 0 {
                programSeparatorY = y + 4
                list.separatorY = programSeparatorY
                y += 10
            }
            let row = AeroMenuRow(frame: NSRect(x: 0, y: y, width: max(0, scroll.contentSize.width - 2),
                                               height: preferredMode && index < pinnedCount ? pinnedHeight : regularHeight))
            row.title = app.name
            if vista && preferredMode && index < pinnedCount {
                row.title = L.t(pinnedTitles[index], settings.resolvedLanguage)
                row.subtitle = app.name
            }
            row.icon = app.icon
            row.hoverEnabled = false
            row.arrow = !vista && !allApps && index % 3 == 1
            if let detail = app.detail {
                row.subtitle = detail
                row.toolTip = detail
            }
            row.onClick = { [weak self] in self?.onLaunch?(app.listEntry) }
            row.onMenu = { [weak self] in
                guard let self else { return nil }
                return AppPinMenu.shared.menu(entry: app.listEntry, settings: self.settings, includeHide: !preferredMode)
            }
            list.addSubview(row)
            y += row.frame.height
        }
        if allApps && search.stringValue.isEmpty {
            y = addWebFolderRows(at: y, rowHeight: regularHeight)
        }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(y, scroll.contentSize.height))
        assert(!allApps || programSeparatorY == nil)
        if programs.isEmpty {
            let empty = AeroMenuRow(frame: NSRect(x: 0, y: 0, width: list.bounds.width, height: 40))
            empty.title = L.t("No apps found", settings.resolvedLanguage)
            empty.hoverEnabled = false
            list.addSubview(empty)
        }
        allPrograms.title = L.t(allApps ? "Back" : "All Programs", settings.resolvedLanguage)
        allPrograms.back = allApps
        allPrograms.leadingArrow = !allApps
        allPrograms.arrow = false
        allPrograms.needsDisplay = true
    }

    /// All Programs lists each collection folder after the programs; clicking expands it in place.
    private func addWebFolderRows(at top: CGFloat, rowHeight: CGFloat) -> CGFloat {
        var y = top
        let width = max(0, scroll.contentSize.width - 2)
        for folder in webFolders {
            let expanded = expandedWebFolders.contains(folder.id)
            let row = AeroMenuRow(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
            row.title = folder.name
            row.icon = folder.icon
            row.hoverEnabled = false
            row.arrow = !expanded
            row.onClick = { [weak self] in
                guard let self else { return }
                if expanded { self.expandedWebFolders.remove(folder.id) } else { self.expandedWebFolders.insert(folder.id) }
                let offset = self.scroll.contentView.bounds.origin
                self.rebuildPrograms()
                self.list.scroll(offset)
            }
            row.onMenu = { [weak self] in
                self.map { AppPinMenu.shared.menu(entry: .collectionFolder(folder), settings: $0.settings) }
            }
            list.addSubview(row)
            y += rowHeight
            guard expanded else { continue }
            for app in folder.items {
                let item = AeroMenuRow(frame: NSRect(x: 18, y: y, width: max(0, width - 18), height: rowHeight))
                item.title = app.name
                item.subtitle = app.detail
                item.toolTip = app.detail
                item.icon = app.icon
                item.hoverEnabled = false
                item.onClick = { [weak self] in self?.onLaunch?(.collectionItem(app)) }
                item.onMenu = { [weak self] in
                    self.map { AppPinMenu.shared.menu(entry: .collectionItem(app), settings: $0.settings) }
                }
                list.addSubview(item)
                y += rowHeight
            }
        }
        return y
    }

    func debugProgramRows() -> [NSRect] { list.subviews.compactMap { ($0 as? AeroMenuRow)?.frame } }

    func debugProgramSeparatorDocumentY() -> CGFloat? { programSeparatorY }

    func debugProgramSeparatorRectInMenu() -> NSRect? {
        guard let separatorY = list.separatorY else { return nil }
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: self)
        return NSRect(x: clip.minX + 6, y: clip.minY + separatorY - scroll.contentView.bounds.origin.y,
                      width: max(0, clip.width - 14), height: 1)
    }

    func debugProgramRowFramesInMenu() -> [NSRect] {
        list.subviews.compactMap { row in
            guard row is AeroMenuRow else { return nil }
            return list.convert(row.frame, to: self)
        }
    }

    func debugProgramViewportFrameInMenu() -> NSRect {
        scroll.contentView.convert(scroll.contentView.bounds, to: self)
    }

    func debugHoveredProgramRows() -> [Int] { list.hoveredRowIndices }

    func debugHoverProgram(atViewportPoint point: NSPoint) {
        let origin = scroll.contentView.bounds.origin
        list.setHover(atListPoint: NSPoint(x: point.x + origin.x, y: point.y + origin.y))
    }

    func debugScrollProgramList(by delta: CGFloat, keepingCursorAt viewportPoint: NSPoint) {
        let clip = scroll.contentView
        let maxOffset = max(0, list.bounds.height - clip.bounds.height)
        let offset = min(max(0, clip.bounds.origin.y + delta), maxOffset)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: offset))
        list.clearHover()
        let origin = clip.bounds.origin
        list.setHover(atListPoint: NSPoint(x: viewportPoint.x + origin.x, y: viewportPoint.y + origin.y))
    }

    func debugProgramScrollOffset() -> CGFloat { scroll.contentView.bounds.origin.y }

    private func buildLinks() {
        let keys = vista
            ? ["User", "Documents", "Pictures", "Music", "Games", "Search", "Recent Items", "Computer", "Network", "Connect To", "Control Panel", "Default Programs", "Help and Support"]
            : ["User", "Documents", "Pictures", "Music", "Games", "Computer", "Control Panel", "Devices and Printers", "Default Programs", "Help and Support"]
        for key in keys {
            let row = AeroMenuRow()
            row.whiteText = true
            row.title = key == "User" ? SnapshotFixture.userName : L.t(key, settings.resolvedLanguage)
            row.arrow = key == "Recent Items"
            row.onClick = { [weak self, weak row] in self?.openLink(key, row: row) }
            links.append(row)
            addSubview(row)
        }
    }

    private func buildToolbar() {
        let shut = AeroMenuRow()
        shut.whiteText = true
        shut.power = vista
        if vista { shut.icon = whiteSymbol("power") } else { shut.title = L.t("Shut down", settings.resolvedLanguage) }
        shut.toolTip = L.t("Shut Down…", settings.resolvedLanguage)
        shut.onClick = { [weak self] in self?.onCommand?(.shutDown) }
        toolbar.append(shut)
        if vista {
            let lock = AeroMenuRow()
            lock.whiteText = true
            lock.icon = whiteSymbol("lock.fill")
            lock.toolTip = L.t("Lock", settings.resolvedLanguage) + " / " + L.t("Run…", settings.resolvedLanguage)
            lock.onClick = { [weak self] in self?.onCommand?(.run) }
            toolbar.append(lock)
        }
        let arrow = AeroMenuRow()
        arrow.whiteText = true
        arrow.arrow = true
        arrow.onClick = { [weak self] in self?.powerMenu() }
        toolbar.append(arrow)
        toolbar.forEach(addSubview)
    }
    private func whiteSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .symbolTinted([.white])
    }
    private func powerMenu() {
        let menu = NSMenu()
        let commands: [(String, StartItem)] = vista
            ? [("Switch User", .run), ("Log Off", .settings), ("Lock", .run), ("Restart", .shutDown), ("Sleep", .shutDown), ("Shut Down…", .shutDown)]
            : [("Run…", .run), ("Settings", .settings), ("Shut Down…", .shutDown)]
        for (key, command) in commands {
            let item = NSMenuItem(title: L.t(key, settings.resolvedLanguage), action: #selector(powerCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.width - 24, y: bounds.height - 35), in: self)
    }
    @objc private func powerCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? StartItem { onCommand?(command) }
    }
    private func openLink(_ key: String, row: NSView?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch key {
        case "Search": focusSearch()
        case "Recent Items":
            let menu = NSMenu()
            let urls = NSDocumentController.shared.recentDocumentURLs
            if urls.isEmpty {
                if let url = URL(string: "file:///System/Library/CoreServices/Finder.app/Contents/Resources/MyLibraries/myDocuments.cannedSearch") { onLaunch?(.app(url)) }
                return
            }
            for url in urls.prefix(12) {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(recentDocument(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = url; menu.addItem(item)
            }
            if let row { menu.popUp(positioning: nil, at: NSPoint(x: row.frame.maxX, y: row.frame.minY), in: self) }
        case "Documents", "Pictures", "Music": onLaunch?(.app(home.appendingPathComponent(key)))
        case "User": onLaunch?(.app(home))
        case "Computer": onLaunch?(.app(URL(fileURLWithPath: "/")))
        case "Network", "Connect To": if let url = URL(string: "network:///") { onLaunch?(.app(url)) }
        case "Games": onLaunch?(.app(URL(fileURLWithPath: "/Applications")))
        case "Help and Support": onLaunch?(.app(URL(fileURLWithPath: "/System/Applications/Tips.app")))
        default:
            let address = key == "Devices and Printers"
                ? "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension" : "x-apple.systempreferences:"
            if let url = URL(string: address) { onLaunch?(.app(url)) }
        }
    }
    @objc private func recentDocument(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onLaunch?(.app(url)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0.5, y: 28.5, width: bounds.width - 1, height: max(0, bounds.height - 29))
        Retro.fill(body, vista ? [NSColor(hex: 0x554647, alpha: 0.82), NSColor(hex: 0x231F22, alpha: 0.88)]
                              : [NSColor(hex: 0x3A5A78, alpha: 0.80), NSColor(hex: 0x2B4560, alpha: 0.85)], radius: 6)
        NSColor(white: 1, alpha: 0.55).setStroke()
        NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6).stroke()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 34, width: paneWidth - 6, height: max(0, bounds.height - 74)), xRadius: 3, yRadius: 3).fill()
        NSColor(hex: 0xD6D6D6).setFill()
        NSRect(x: 14, y: allPrograms.frame.minY - 3, width: paneWidth - 26, height: 1).fill()
        for y in separatorYs {
            NSColor(white: 0, alpha: 0.4).setFill()
            NSRect(x: paneWidth + 12, y: y, width: bounds.width - paneWidth - 26, height: 1).fill()
            NSColor(white: 1, alpha: 0.14).setFill()
            NSRect(x: paneWidth + 12, y: y + 1, width: bounds.width - paneWidth - 26, height: 1).fill()
        }
        toolbar.forEach { row in
            if !row.power { AeroDrawing.button(row.frame, active: false, hovered: false, pressed: false) }
        }
        let user = NSRect(x: paneWidth + (bounds.width - paneWidth - 58) / 2, y: 0, width: 58, height: 58)
        Retro.fill(user, [NSColor(white: 1, alpha: 0.65), NSColor(white: 1, alpha: 0.2)], radius: 5)
        if preservesAllAppsSnapshot {
            Retro.fill(user.insetBy(dx: 5, dy: 5), [NSColor(hex: 0xFFC447), NSColor(hex: 0xBA5C11)], radius: 3)
            if let image = AppResources.image(named: AppResources.userAccountSnapshotImage) {
                Retro.drawImage(image, in: user.insetBy(dx: 8, dy: 8))
            }
        } else {
            AeroDrawing.userPicture(in: user.insetBy(dx: 5, dy: 5))
        }
        NSColor(white: 1, alpha: 0.8).setStroke()
        NSBezierPath(roundedRect: user.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
    }
}

@MainActor
enum Vista7AllAppsSeparatorSelfTest {
    static func run() -> Int {
        SnapshotFixture.activate()
        let applications = (0..<32).map { index in
            let name = "Separator App " + String(index + 1)
            let icon = NSImage(systemSymbolName: "app", accessibilityDescription: name)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            return Win10StartMenuView.Application(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                                  name: name, icon: icon)
        }
        for (style, label) in [(StartMenuStyle.vista, "vista"), (.win7, "win7")] {
            var settings = SnapshotFixture.settings
            settings.startMenuStyleChoice = style
            let menu = AeroStartMenuView(settings: settings, applications: applications)
            menu.layoutSubtreeIfNeeded()
            guard let separatorDocumentY = menu.debugProgramSeparatorDocumentY(),
                  let initialSeparator = menu.debugProgramSeparatorRectInMenu() else {
                fputs("FAIL vista7 allapps separator selftest \(label) missing preferred separator\n", stderr)
                return 1
            }
            guard initialSeparator.intersects(menu.debugProgramViewportFrameInMenu()) else {
                fputs("FAIL vista7 allapps separator selftest \(label) separator outside viewport\n", stderr)
                return 1
            }
            let rowHeight = max(1, menu.debugProgramRows().first?.height ?? 1)
            for _ in 0..<3 {
                menu.debugScrollProgramList(by: rowHeight * 2, keepingCursorAt: NSPoint(x: 90, y: 100))
                guard menu.debugProgramSeparatorDocumentY() == separatorDocumentY,
                      let separator = menu.debugProgramSeparatorRectInMenu() else {
                    fputs("FAIL vista7 allapps separator selftest \(label) separator moved\n", stderr)
                    return 1
                }
                let viewport = menu.debugProgramViewportFrameInMenu()
                for row in menu.debugProgramRowFramesInMenu() where row.intersects(viewport) {
                    let titleMid = NSRect(x: row.minX, y: row.midY, width: row.width, height: 1)
                    guard !separator.intersects(titleMid) else {
                        fputs("FAIL vista7 allapps separator selftest \(label) separator intersects row mid\n", stderr)
                        return 1
                    }
                }
            }
            let allAppsMenu = AeroStartMenuView(settings: settings, allApps: true, applications: applications)
            allAppsMenu.layoutSubtreeIfNeeded()
            guard allAppsMenu.debugProgramSeparatorDocumentY() == nil,
                  allAppsMenu.debugProgramSeparatorRectInMenu() == nil else {
                fputs("FAIL vista7 allapps separator selftest \(label) all-apps separator remains\n", stderr)
                return 1
            }
        }
        print("PASS vista7 allapps separator selftest")
        return 0
    }
}

@MainActor
enum Vista7ScrollHoverSelfTest {
    static func run() -> Int {
        SnapshotFixture.activate()
        let applications = (0..<24).map { index in
            let name = "Scroll App " + String(index + 1)
            let icon = NSImage(systemSymbolName: "app", accessibilityDescription: name)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            return Win10StartMenuView.Application(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                                  name: name, icon: icon)
        }
        let cursor = NSPoint(x: 90, y: 100)
        var results: [String] = []
        for (style, label) in [(StartMenuStyle.vista, "vista"), (.win7, "win7")] {
            var settings = SnapshotFixture.settings
            settings.startMenuStyleChoice = style
            let menu = AeroStartMenuView(settings: settings, allApps: true, applications: applications)
            menu.layoutSubtreeIfNeeded()
            let rows = menu.debugProgramRows()
            guard rows.count >= 12,
                  rows[2].contains(NSPoint(x: cursor.x, y: cursor.y)) else {
                fputs("FAIL vista7 scroll-hover selftest " + label + " missing initial rows\n", stderr)
                return 1
            }
            menu.debugHoverProgram(atViewportPoint: cursor)
            guard menu.debugHoveredProgramRows() == [2] else {
                fputs("FAIL vista7 scroll-hover selftest " + label + " initial hover=\(menu.debugHoveredProgramRows())\n", stderr)
                return 1
            }
            for delta in [120, 120, 120] {
                menu.debugScrollProgramList(by: CGFloat(delta), keepingCursorAt: cursor)
                let offset = menu.debugProgramScrollOffset()
                let expected = rows.enumerated().first { _, row in
                    row.contains(NSPoint(x: cursor.x, y: cursor.y + offset)) }?.offset
                let hovered = menu.debugHoveredProgramRows()
                guard let expected, hovered == [expected], hovered.count <= 1 else {
                    fputs("FAIL vista7 scroll-hover selftest " + label + " offset=\(offset) expected=\(String(describing: expected)) hover=\(hovered)\n", stderr)
                    return 1
                }
            }
            results.append(label + "=pass")
        }
        print("PASS vista7 scroll-hover selftest \(results.joined(separator: " "))")
        return 0
    }
}

/// A desktop crop shared by the headless taskbar and menu snapshots.
@MainActor
final class AeroSnapshotView: NSView {
    private let vista: Bool
    init(settings: TaskbarSettings, apps: [AppEntry], menu: Bool = false, allApps: Bool = false) {
        let theme = Theme.make(settings)
        let overflow = theme.startStyle.overflow
        vista = theme.startStyle.wallpaper == "vista"
        let vertical = settings.edge.isVertical
        let barSize = vertical ? NSSize(width: TaskbarView.verticalWidth(for: settings), height: 800)
            : NSSize(width: menu ? 400 : 1000, height: TaskbarView.thickness(for: settings))
        let menuView: NSView? = menu ? StartMenuRendering.view(settings: settings, allApps: allApps,
                                                             preserveAllAppsSnapshot: allApps) : nil
        let above: CGFloat = menuView?.frame.height ?? (overflow.enabled && !vertical ? max(0, overflow.panelHeight - overflow.panelInset - barSize.height) : 0)
        let orbPadding: CGFloat = overflow.enabled && menu && !allApps ? overflow.menuPadding : 0
        super.init(frame: NSRect(x: 0, y: 0, width: barSize.width, height: above + barSize.height + orbPadding))
        if let menuView { addSubview(menuView) }
        let bar = TaskbarView(frame: NSRect(x: 0, y: above, width: barSize.width, height: barSize.height))
        bar.isPreview = true
        bar.settings = settings
        bar.apps = menu && !allApps ? Array(apps.prefix(2)) : apps
        bar.activePID = apps.first?.pid
        bar.clockText = "8:38 AM"
        bar.shortDateText = "10/9/2026"
        bar.inputText = "EN"
        bar.usesStartOverflowPanel = overflow.enabled && !vertical
        bar.reload()
        addSubview(bar)
        if overflow.enabled && !vertical {
            let orb = RetroButton(frame: NSRect(x: 0, y: above + barSize.height + overflow.panelInset - overflow.panelHeight,
                                                  width: overflow.panelWidth, height: overflow.panelHeight))
            orb.kind = .start
            orb.theme = theme
            orb.smoothing = theme.layoutStyle.forcedSmoothing || settings.fontSmoothing
            orb.title = L.t(theme.startStyle.label.key, settings.resolvedLanguage)
            addSubview(orb)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { AeroDrawing.wallpaper(bounds, vista: vista) }
}

/// Content identity for icon average colours. NSWorkspace hands out a fresh NSImage
/// for every `icon` access, so object identity alone never hits the cache.
private struct AverageColorKey: Hashable {
    let width: Int
    let height: Int
    let bytes: Data

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        bytes = (image.dataProvider?.data as Data?) ?? Data()
    }
}
