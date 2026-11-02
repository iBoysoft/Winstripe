import AppKit

@MainActor
final class MixedStartMenuSceneView: NSView {
    private let scale: CGFloat
    private let barFrame: NSRect
    private let menuFrame: NSRect
    private let barImage: NSImage
    private let menuImage: NSImage

    init(screenSize: NSSize, barFrame: NSRect, menuFrame: NSRect,
         barImage: NSImage, menuImage: NSImage, scale: CGFloat = 0.5) {
        self.scale = scale
        self.barFrame = barFrame
        self.menuFrame = menuFrame
        self.barImage = barImage
        self.menuImage = menuImage
        super.init(frame: NSRect(x: 0, y: 0, width: screenSize.width * scale, height: screenSize.height * scale))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1).setFill()
        bounds.fill()
        barImage.draw(in: scaled(barFrame), from: NSRect(origin: .zero, size: barImage.size),
                      operation: .sourceOver, fraction: 1)
        menuImage.draw(in: scaled(menuFrame), from: NSRect(origin: .zero, size: menuImage.size),
                      operation: .sourceOver, fraction: 1)
    }

    private func scaled(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}
