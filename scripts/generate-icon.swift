import AppKit

// Reproducible vector artwork; no downloaded artwork or external dependencies.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.24); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.065, alpha: 1).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.04, alpha: 1), NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)])!.draw(in: tile, angle: 60)
    // Two banks, a continuous arch, and its deck: a readable bridge at Dock sizes.
    let arch = NSBezierPath(); arch.move(to: NSPoint(x: 250, y: 342)); arch.line(to: NSPoint(x: 250, y: 445)); arch.curve(to: NSPoint(x: 774, y: 445), controlPoint1: NSPoint(x: 250, y: 790), controlPoint2: NSPoint(x: 774, y: 790)); arch.line(to: NSPoint(x: 774, y: 342))
    arch.lineWidth = 66; arch.lineCapStyle = .round
    NSColor.white.setStroke(); arch.stroke()
    let deck = NSBezierPath(); deck.move(to: NSPoint(x: 198, y: 406)); deck.line(to: NSPoint(x: 826, y: 406)); deck.lineWidth = 48; deck.lineCapStyle = .round; deck.stroke()
    let cables = NSBezierPath(); cables.move(to: NSPoint(x: 410, y: 660)); cables.line(to: NSPoint(x: 410, y: 426)); cables.move(to: NSPoint(x: 614, y: 660)); cables.line(to: NSPoint(x: 614, y: 426)); cables.lineWidth = 22; cables.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.7).setStroke(); cables.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(1024).write(to: root.appendingPathComponent("Resources/Brand/AppIcon-1024.png"))
