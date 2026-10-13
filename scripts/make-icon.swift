import AppKit
import SwiftUI

// Asset generation only: no app is launched and no user data is accessed.
// Usage: swift scripts/make-icon.swift Resources  →  Resources/AppIcon.iconset + Resources/AppIcon.icns
// Design: a two-slot switch on a warm clay tile. The knob is the active account, the ring is the
// other one, and the soft trail reads as the knob having just slid across. 1024 grid, 824 body (Apple macOS template).
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}
func capsule(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

/// Shadow offsets and blur ignore the CTM, so `s` scales them to the output size.
func draw(_ ctx: CGContext, s: CGFloat) {
    let tile = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: rgb(0, 0.30))
    ctx.addPath(tile); ctx.setFillColor(rgb(0xC9653F)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xEA9068), rgb(0xB24B27)]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.12), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: 330, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 330, y: 900), endRadius: 620, options: [])
    ctx.addPath(tile); ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(5); ctx.strokePath()
    ctx.restoreGState()

    let track = capsule(CGRect(x: 204, y: 360, width: 616, height: 304))
    ctx.addPath(track); ctx.setFillColor(rgb(0x6E240E, 0.34)); ctx.fillPath()
    ctx.saveGState(); ctx.addPath(track); ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: rgb(0x3A0F03, 0.6))
    let outside = CGMutablePath(); outside.addRect(CGRect(x: -1024, y: -1024, width: 3072, height: 3072)); outside.addPath(track)
    ctx.addPath(outside); ctx.setFillColor(rgb(0)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(track); ctx.clip(); ctx.addPath(track); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(6); ctx.strokePath(); ctx.restoreGState()

    let knob = CGPoint(x: 668, y: 512), knobRadius: CGFloat = 124
    ctx.saveGState(); ctx.addPath(capsule(CGRect(x: 232, y: knob.y - knobRadius, width: knob.x - 232, height: 2 * knobRadius))); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFF1E6, 0), rgb(0xFFF1E6, 0.26)]), start: CGPoint(x: 260, y: 0), end: CGPoint(x: knob.x, y: 0), options: [])
    ctx.restoreGState()
    ctx.addPath(circle(CGPoint(x: 356, y: 512), 52)); ctx.setStrokeColor(rgb(0xFFF4EC, 0.7)); ctx.setLineWidth(24); ctx.strokePath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: rgb(0x420F02, 0.5))
    ctx.addPath(circle(knob, knobRadius)); ctx.setFillColor(rgb(0xFFF8F3)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(circle(knob, knobRadius)); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xF2DDCF)]), start: CGPoint(x: 0, y: knob.y + knobRadius), end: CGPoint(x: 0, y: knob.y - knobRadius), options: [])
    ctx.restoreGState()
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let s = CGFloat(pixels) / 1024
        graphics.cgContext.scaleBy(x: s, y: s)
        draw(graphics.cgContext, s: s)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 { exit(iconutil.terminationStatus) }
