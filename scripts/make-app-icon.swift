// Renders the Winstripe app icon: a Big Sur-style squircle with a retro desktop, a classic gray
// taskbar and an original four-quadrant Start orb in the wordmark palette (not the Microsoft logo).
// Every size is drawn from vectors at its own pixel size; small sizes drop fine detail.
//
// Usage: swift scripts/make-app-icon.swift [output-appiconset-dir] [preview.png]
// Default output: Sources/Winstripe/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let palette: [NSColor] = [0xE53935, 0xFBC02D, 0x43A047, 0x1E88E5].map {
    NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
}
func rgb(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Superellipse (n = 5) close to Apple's continuous-corner icon shape.
func squircle(_ r: NSRect) -> NSBezierPath {
    let p = NSBezierPath(), n = 5.0, steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = NSPoint(x: r.midX + CGFloat(x) * r.width / 2, y: r.midY + CGFloat(y) * r.height / 2)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

/// Classic 3D bevel: light top/left, dark bottom/right.
func bevel(_ r: NSRect, _ w: CGFloat, raised: Bool, face: NSColor = rgb(0xC3C7CB)) {
    face.setFill(); r.fill()
    let light = raised ? NSColor.white : rgb(0x6B6F73), dark = raised ? rgb(0x4A4E52) : NSColor.white
    light.setFill()
    NSRect(x: r.minX, y: r.maxY - w, width: r.width, height: w).fill()
    NSRect(x: r.minX, y: r.minY, width: w, height: r.height).fill()
    dark.setFill()
    NSRect(x: r.minX, y: r.minY, width: r.width, height: w).fill()
    NSRect(x: r.maxX - w, y: r.minY, width: w, height: r.height).fill()
}

/// Four colored quadrants of a circle separated by a light cross gap, slightly rotated.
func orb(center c: NSPoint, radius: CGFloat, gap: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: -12); t.concat()
    for (i, color) in palette.enumerated() {
        let start = CGFloat(90 * i)
        let p = NSBezierPath()
        p.move(to: .zero)
        p.appendArc(withCenter: .zero, radius: radius, startAngle: start, endAngle: start + 90)
        p.close()
        color.setFill(); p.fill()
    }
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(x: -radius - 1, y: -gap / 2, width: 2 * radius + 2, height: gap).fill()
    NSRect(x: -gap / 2, y: -radius - 1, width: gap, height: 2 * radius + 2).fill()
    let rim = NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
    rim.lineWidth = max(1, radius * 0.06); NSColor(white: 0, alpha: 0.18).setStroke(); rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let detail = pixels >= 128 ? 2 : (pixels >= 64 ? 1 : 0)

    // Big Sur grid: 824 pt body centered, shadow below.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.32)
    shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 24; shadow.set()
    rgb(0x1D5E8C).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Desktop: retro teal-blue sky.
    NSGradient(colors: [rgb(0x5BC0EB), rgb(0x2A86BA), rgb(0x1B4F7A)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -90)
    // Soft glare.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 40, y: 560, width: 760, height: 520)), relativeCenterPosition: .zero)

    let barH: CGFloat = detail == 0 ? 430 : 210
    let bar = NSRect(x: body.minX, y: body.minY, width: body.width, height: barH)
    if detail > 0 {
        // A classic window on the desktop.
        let win = NSRect(x: 250, y: 420, width: 520, height: 380)
        NSGraphicsContext.saveGraphicsState()
        let ws = NSShadow(); ws.shadowColor = NSColor(white: 0, alpha: 0.35); ws.shadowOffset = NSSize(width: 0, height: -10); ws.shadowBlurRadius = 18; ws.set()
        rgb(0xC3C7CB).setFill(); win.fill()
        NSGraphicsContext.restoreGraphicsState()
        bevel(win, 8, raised: true)
        let title = NSRect(x: win.minX + 16, y: win.maxY - 74, width: win.width - 32, height: 58)
        NSGradient(colors: [rgb(0x0A246A), rgb(0x3A6EA5)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: title, angle: 0)
        if detail > 1 {
            for i in 0..<3 {
                bevel(NSRect(x: title.maxX - 52 - CGFloat(i) * 50, y: title.minY + 10, width: 40, height: 38), 4, raised: true)
            }
            let well = NSRect(x: win.minX + 16, y: win.minY + 16, width: win.width - 32, height: title.minY - win.minY - 32)
            bevel(well, 6, raised: false, face: .white)
            for (i, color) in palette.enumerated() {
                color.withAlphaComponent(0.9).setFill()
                NSRect(x: well.minX + 28, y: well.maxY - 56 - CGFloat(i) * 52, width: CGFloat([300, 220, 340, 180][i]), height: 22).fill()
            }
        }
    }

    // Taskbar.
    rgb(0xC3C7CB).setFill(); bar.fill()
    NSColor.white.setFill(); NSRect(x: bar.minX, y: bar.maxY - 10, width: bar.width, height: 10).fill()
    rgb(0xDFE2E5).setFill(); NSRect(x: bar.minX, y: bar.maxY - 18, width: bar.width, height: 8).fill()
    let pad: CGFloat = 26, btnH = barH - 18 - 2 * pad + (detail == 0 ? 10 : 0)
    let start = detail == 0
        ? NSRect(x: bar.midX - 250, y: bar.minY + 50, width: 500, height: barH - 18 - 80)
        : NSRect(x: bar.minX + 92, y: bar.minY + pad + 6, width: 250, height: btnH)
    bevel(start, detail == 0 ? 22 : 9, raised: true)
    let orbR = min(start.height * 0.36, start.width * 0.3)
    orb(center: NSPoint(x: detail == 0 ? start.midX : start.minX + 30 + orbR, y: start.midY), radius: detail == 0 ? 135 : orbR,
        gap: detail == 0 ? 30 : max(8, orbR * 0.13))
    if detail > 0 {
        // "Start" stand-in: three bars, not text, so it reads at any size and in any language.
        rgb(0x2B2F33).setFill()
        let tx = start.minX + 50 + 2 * orbR
        for (i, w) in [CGFloat(96), 70, 84].enumerated() where detail > 1 || i == 0 {
            NSRect(x: tx, y: start.midY + 18 - CGFloat(i) * 22 - (detail > 1 ? 0 : -18), width: w * (detail > 1 ? 1 : 1.1), height: 12).fill()
        }
        // A pressed task button and a tray well.
        let task = NSRect(x: start.maxX + 22, y: start.minY, width: 210, height: start.height)
        bevel(task, 8, raised: false, face: rgb(0xD9DCDF))
        palette[3].setFill(); NSRect(x: task.minX + 24, y: task.midY - 22, width: 44, height: 44).fill()
        if detail > 1 { rgb(0x2B2F33).setFill(); NSRect(x: task.minX + 84, y: task.midY - 6, width: 100, height: 12).fill() }
        let tray = NSRect(x: bar.maxX - 92 - 120, y: start.minY, width: 120, height: start.height)
        bevel(tray, 6, raised: false)
        palette[2].setFill(); NSBezierPath(ovalIn: NSRect(x: tray.minX + 20, y: tray.midY - 13, width: 26, height: 26)).fill()
        palette[0].setFill(); NSBezierPath(ovalIn: NSRect(x: tray.minX + 62, y: tray.midY - 13, width: 26, height: 26)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Thin rim for definition on light backgrounds.
    shape.lineWidth = 3; NSColor(white: 0, alpha: 0.12).setStroke(); shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "Sources/Winstripe/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(pixels: points * scale).representation(using: .png, properties: [:])!
        try data.write(to: out.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("Contents.json"))
if args.count > 2 {
    try drawIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
}
print("wrote \(images.count) icons to \(out.path)")
