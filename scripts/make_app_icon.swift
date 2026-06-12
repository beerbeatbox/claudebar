// Renders the ClaudeBar app icon ("Ring" design: white progress ring with a
// Claude-style spark on a coral gradient) into the macOS AppIcon.appiconset.
//
// Usage: swift scripts/make_app_icon.swift
//
// Draws vector geometry at every required size (16…1024) instead of
// downsampling a master, so small sizes stay crisp. Filenames match the
// existing Contents.json, which is left untouched.

import AppKit

// Geometry is authored on a 1024 pt canvas (Apple's macOS icon grid:
// 824 pt rounded rect centered, ~185 pt corner radius) and scaled per size.
let canvas: CGFloat = 1024
let inset: CGFloat = 100
let corner: CGFloat = 184

func spark(at center: NSPoint, rays: [CGFloat], width: CGFloat, jitter: [CGFloat]) -> NSBezierPath {
    let path = NSBezierPath()
    for (i, length) in rays.enumerated() {
        let angle = (CGFloat(i) / CGFloat(rays.count)) * 2 * .pi + jitter[i % jitter.count]
        let dir = NSPoint(x: cos(angle), y: sin(angle))
        let perp = NSPoint(x: -dir.y, y: dir.x)
        path.move(to: NSPoint(x: center.x + perp.x * width, y: center.y + perp.y * width))
        path.line(to: NSPoint(x: center.x + dir.x * length, y: center.y + dir.y * length))
        path.line(to: NSPoint(x: center.x - perp.x * width, y: center.y - perp.y * width))
        path.close()
    }
    return path
}

func drawIcon() {
    let badge = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset,
                            width: canvas - 2 * inset, height: canvas - 2 * inset),
        xRadius: corner, yRadius: corner)
    badge.addClip()

    NSGradient(starting: NSColor(srgbRed: 0.580, green: 0.247, blue: 0.137, alpha: 1),
               ending: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: 90)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10),
               ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 0, y: canvas / 2, width: canvas, height: canvas / 2), angle: -90)

    let center = NSPoint(x: 512, y: 512)
    let radius: CGFloat = 244

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius,
                    startAngle: 0, endAngle: 360, clockwise: false)
    track.lineWidth = 84
    NSColor.white.withAlphaComponent(0.25).setStroke()
    track.stroke()

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: radius,
                       startAngle: 90, endAngle: 180, clockwise: true)
    progress.lineWidth = 84
    progress.lineCapStyle = .round
    NSColor.white.setStroke()
    progress.stroke()

    let centerSpark = spark(
        at: center,
        rays: [116, 88, 116, 88, 116, 88, 116, 88],
        width: 16,
        jitter: [0.04, -0.03, 0.04, -0.03, 0.04, -0.03, 0.04, -0.03])
    NSColor.white.setFill()
    centerSpark.fill()
    NSColor.white.setStroke()
    centerSpark.lineWidth = 14
    centerSpark.lineJoinStyle = .round
    centerSpark.stroke()
}

func render(size: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / canvas)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()

    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconsetDir = URL(fileURLWithPath: "macos/Runner/Assets.xcassets/AppIcon.appiconset",
                     isDirectory: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(size: size, to: iconsetDir.appendingPathComponent("app_icon_\(size).png"))
    print("app_icon_\(size).png")
}
