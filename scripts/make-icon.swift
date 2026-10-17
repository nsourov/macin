import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = tile.width * 0.225
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let colors = [rgb(0x34D399), rgb(0x10B981), rgb(0x0F766E)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.20).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

let center = CGPoint(x: size / 2, y: size / 2)

let screen = CGRect(x: center.x - 270, y: center.y - 135, width: 540, height: 350)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 40, cornerHeight: 40, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.22).cgColor)
ctx.addPath(screenPath)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()

let base = CGRect(x: center.x - 340, y: screen.minY - 52, width: 680, height: 40)
let basePath = CGMutablePath()
basePath.move(to: CGPoint(x: base.minX, y: base.maxY))
basePath.addLine(to: CGPoint(x: base.maxX, y: base.maxY))
basePath.addLine(to: CGPoint(x: base.maxX - 14, y: base.minY + 16))
basePath.addQuadCurve(to: CGPoint(x: base.maxX - 40, y: base.minY), control: CGPoint(x: base.maxX - 22, y: base.minY))
basePath.addLine(to: CGPoint(x: base.minX + 40, y: base.minY))
basePath.addQuadCurve(to: CGPoint(x: base.minX + 14, y: base.minY + 16), control: CGPoint(x: base.minX + 22, y: base.minY))
basePath.closeSubpath()
ctx.addPath(basePath)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.setFillColor(rgb(0x0F766E, 0.35))
ctx.addPath(CGPath(roundedRect: CGRect(x: center.x - 60, y: base.maxY - 14, width: 120, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
ctx.fillPath()

let pulse: [CGPoint] = [
    CGPoint(x: screen.minX + 60, y: screen.midY),
    CGPoint(x: screen.minX + 170, y: screen.midY),
    CGPoint(x: screen.minX + 215, y: screen.midY + 90),
    CGPoint(x: screen.minX + 270, y: screen.midY - 95),
    CGPoint(x: screen.minX + 315, y: screen.midY + 30),
    CGPoint(x: screen.minX + 345, y: screen.midY),
    CGPoint(x: screen.maxX - 60, y: screen.midY)
]
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(34)
ctx.setStrokeColor(rgb(0x059669))
ctx.addLines(between: pulse)
ctx.strokePath()

func sparkle(at p: CGPoint, radius r: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: p.x, y: p.y + r))
    path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: p)
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: p)
    path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: p)
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: p)
    ctx.addPath(path)
    ctx.fillPath()
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor.black.withAlphaComponent(0.18).cgColor)
ctx.setFillColor(rgb(0xFDE68A))
sparkle(at: CGPoint(x: screen.maxX - 10, y: screen.maxY + 10), radius: 92)
ctx.setFillColor(NSColor.white.cgColor)
sparkle(at: CGPoint(x: screen.maxX + 70, y: screen.maxY + 105), radius: 40)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
