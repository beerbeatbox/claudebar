// Renders the DMG installer window background (600x400 pt) at 1x and 2x.
//
// Usage: swift scripts/make_dmg_background.swift <output-dir>
// Writes <output-dir>/dmg-bg.png and <output-dir>/dmg-bg@2x.png; make_dmg.sh
// combines them into a Retina TIFF with tiffutil.
//
// Layout must match the create-dmg flags in make_dmg.sh:
// window 600x400, icons 128 pt centered at (150,185) and (450,185)
// (top-left origin). AppKit draws bottom-left, so those land at y=215 here.

import AppKit

let width: CGFloat = 600
let height: CGFloat = 400
let appCenter = NSPoint(x: 150, y: 215)
let dropCenter = NSPoint(x: 450, y: 215)

let coral = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
let amber = NSColor(srgbRed: 233 / 255, green: 180 / 255, blue: 104 / 255, alpha: 1)
let ink = NSColor(srgbRed: 74 / 255, green: 56 / 255, blue: 44 / 255, alpha: 1)
let mutedInk = NSColor(srgbRed: 138 / 255, green: 122 / 255, blue: 108 / 255, alpha: 1)

func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded),
          let rounded = NSFont(descriptor: descriptor, size: size)
    else { return base }
    return rounded
}

func sparkle(at center: NSPoint, radius r: CGFloat) -> NSBezierPath {
    let c = r * 0.18
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + r))
    path.curve(to: NSPoint(x: center.x + r, y: center.y),
               controlPoint1: NSPoint(x: center.x + c, y: center.y + c),
               controlPoint2: NSPoint(x: center.x + c, y: center.y + c))
    path.curve(to: NSPoint(x: center.x, y: center.y - r),
               controlPoint1: NSPoint(x: center.x + c, y: center.y - c),
               controlPoint2: NSPoint(x: center.x + c, y: center.y - c))
    path.curve(to: NSPoint(x: center.x - r, y: center.y),
               controlPoint1: NSPoint(x: center.x - c, y: center.y - c),
               controlPoint2: NSPoint(x: center.x - c, y: center.y - c))
    path.curve(to: NSPoint(x: center.x, y: center.y + r),
               controlPoint1: NSPoint(x: center.x - c, y: center.y + c),
               controlPoint2: NSPoint(x: center.x - c, y: center.y + c))
    path.close()
    return path
}

func drawCenteredText(_ text: NSAttributedString, centerX: CGFloat, baselineY: CGFloat) {
    let size = text.size()
    text.draw(at: NSPoint(x: centerX - size.width / 2, y: baselineY))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Warm cream gradient, light at the top.
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.969, green: 0.910, blue: 0.863, alpha: 1),
        ending: NSColor(srgbRed: 0.992, green: 0.973, blue: 0.949, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Soft decorative blobs in the corners.
    coral.withAlphaComponent(0.06).setFill()
    NSBezierPath(ovalIn: NSRect(x: -70, y: 270, width: 220, height: 220)).fill()
    coral.withAlphaComponent(0.07).setFill()
    NSBezierPath(ovalIn: NSRect(x: 440, y: -100, width: 260, height: 260)).fill()
    amber.withAlphaComponent(0.10).setFill()
    NSBezierPath(ovalIn: NSRect(x: 490, y: 320, width: 140, height: 140)).fill()

    // White plates behind the two icon spots.
    for center in [appCenter, dropCenter] {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 14
        shadow.set()
        NSColor.white.withAlphaComponent(0.80).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 86, y: center.y - 86,
                                    width: 172, height: 172)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // Dashed ring around the Applications spot: "drop it here".
    let ring = NSBezierPath(ovalIn: NSRect(x: dropCenter.x - 96, y: dropCenter.y - 96,
                                           width: 192, height: 192))
    ring.lineWidth = 2
    ring.setLineDash([4, 6], count: 2, phase: 0)
    coral.withAlphaComponent(0.45).setStroke()
    ring.stroke()

    // Dotted arrow between the icons.
    let arrowStart = NSPoint(x: appCenter.x + 98, y: appCenter.y)
    let arrowEnd = NSPoint(x: dropCenter.x - 110, y: dropCenter.y)
    let line = NSBezierPath()
    line.move(to: arrowStart)
    line.line(to: arrowEnd)
    line.lineWidth = 4
    line.lineCapStyle = .round
    line.setLineDash([0.1, 10], count: 2, phase: 0)
    coral.setStroke()
    line.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: arrowEnd.x + 14, y: arrowEnd.y))
    head.line(to: NSPoint(x: arrowEnd.x - 1, y: arrowEnd.y + 9))
    head.line(to: NSPoint(x: arrowEnd.x - 1, y: arrowEnd.y - 9))
    head.close()
    coral.setFill()
    head.fill()

    // Sparkles, kept clear of the icon plates and labels.
    coral.withAlphaComponent(0.55).setFill()
    sparkle(at: NSPoint(x: 300, y: 252), radius: 7).fill()
    amber.withAlphaComponent(0.75).setFill()
    sparkle(at: NSPoint(x: 273, y: 282), radius: 4).fill()
    sparkle(at: NSPoint(x: 330, y: 285), radius: 5).fill()
    coral.withAlphaComponent(0.40).setFill()
    sparkle(at: NSPoint(x: 56, y: 90), radius: 6).fill()
    sparkle(at: NSPoint(x: 552, y: 358), radius: 6).fill()
    amber.withAlphaComponent(0.55).setFill()
    sparkle(at: NSPoint(x: 540, y: 86), radius: 5).fill()

    // Title: "Claude" in ink, "Bar" in coral.
    let titleFont = roundedFont(size: 30, weight: .heavy)
    let title = NSMutableAttributedString(
        string: "Claude", attributes: [.font: titleFont, .foregroundColor: ink])
    title.append(NSAttributedString(
        string: "Bar", attributes: [.font: titleFont, .foregroundColor: coral]))
    drawCenteredText(title, centerX: width / 2, baselineY: 338)

    let subtitle = NSAttributedString(
        string: "Drag the app into the Applications folder to install",
        attributes: [.font: roundedFont(size: 13, weight: .medium),
                     .foregroundColor: mutedInk])
    drawCenteredText(subtitle, centerX: width / 2, baselineY: 315)

    return rep
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make_dmg_background.swift <output-dir>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

for (scale, name) in [(CGFloat(1), "dmg-bg.png"), (CGFloat(2), "dmg-bg@2x.png")] {
    let rep = render(scale: scale)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent(name))
}
