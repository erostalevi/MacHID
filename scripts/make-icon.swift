// Draws the MacHID app icon and writes Resources/AppIcon.icns.  Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024
    // macOS icon grid: 824 pt tile centered in 1024.
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [NSColor(red: 0.42, green: 0.26, blue: 0.95, alpha: 1).cgColor,
                                                      NSColor(red: 0.12, green: 0.55, blue: 0.98, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 400 * u, y: 800 * u), startRadius: 0, endCenter: CGPoint(x: 400 * u, y: 800 * u), endRadius: 520 * u, options: [])
    // Mouse body: a glass capsule.
    let body = CGRect(x: 372 * u, y: 200 * u, width: 280 * u, height: 440 * u)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 140 * u, cornerHeight: 140 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(bodyPath); ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(bodyPath); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(10 * u); ctx.strokePath()
    // Button split and scroll wheel.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(8 * u)
    ctx.move(to: CGPoint(x: 512 * u, y: 640 * u)); ctx.addLine(to: CGPoint(x: 512 * u, y: 470 * u)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 372 * u, y: 470 * u)); ctx.addLine(to: CGPoint(x: 652 * u, y: 470 * u)); ctx.strokePath()
    let wheel = CGPath(roundedRect: CGRect(x: 490 * u, y: 510 * u, width: 44 * u, height: 96 * u), cornerWidth: 22 * u, cornerHeight: 22 * u, transform: nil)
    ctx.addPath(wheel); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    // Radio waves from the top: the device is "talking".
    ctx.setLineCap(.round)
    for (i, radius) in [120.0, 190.0, 260.0].enumerated() {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95 - 0.22 * Double(i)).cgColor)
        ctx.setLineWidth(26 * u)
        ctx.addArc(center: CGPoint(x: 512 * u, y: 640 * u), radius: CGFloat(radius) * u, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.addPath(tilePath); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(3 * u); ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let work = URL(fileURLWithPath: "/private/tmp/machid-icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: work.deletingLastPathComponent())
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: work.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: work.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", work.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print("wrote", out.path, "status", p.terminationStatus)
