#!/usr/bin/env swift
// Draws the FishBrain app icon at every size macOS needs and writes the asset catalog.
//   swift Scripts/make-icon.swift
// Frosted Midnight: a smoked-glass tile, a stack of flashcards in the indigo accent, and a fish on the
// front card. Everything is drawn from the 1024-point design, scaled per size so small sizes stay crisp.
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "FishBrain/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon into the current context, in a 1024 x 1024 coordinate space.
func drawIcon() {
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    color(0x16161A).setFill()
    tilePath.fill()
    ctx.restoreGState()

    // Smoked glass: dark vertical gradient, a faint indigo glow low on the right, a bright rim at the top.
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(colors: [color(0x34343C), color(0x1A1A20), color(0x0E0E12)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -90)
    NSGradient(colors: [color(0x5E5CE6, 0.34), color(0x5E5CE6, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(fromCenter: CGPoint(x: 800, y: 210), radius: 0, toCenter: CGPoint(x: 800, y: 210), radius: 520, options: [])
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: 100, y: 640, width: 824, height: 284), angle: -90)
    ctx.restoreGState()
    color(0xFFFFFF, 0.18).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184.5, yRadius: 184.5)
    rim.lineWidth = 3
    rim.stroke()

    // Three flashcards, each peeking out above the one in front.
    func card(_ rect: CGRect, top: UInt32, bottom: UInt32, alpha: CGFloat = 1) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 54, yRadius: 54)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        color(bottom, alpha).setFill()
        path.fill()
        ctx.restoreGState()
        ctx.saveGState()
        path.addClip()
        NSGradient(colors: [color(top, alpha), color(bottom, alpha)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: rect, angle: -90)
        ctx.restoreGState()
        color(0xFFFFFF, 0.28 * alpha).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 53, yRadius: 53)
        edge.lineWidth = 2
        edge.stroke()
    }
    let width: CGFloat = 520
    card(CGRect(x: 252, y: 440, width: width, height: 330), top: 0xB9B7FF, bottom: 0x8F8DF2, alpha: 0.55)
    card(CGRect(x: 232, y: 390, width: width + 40, height: 330), top: 0xA5A3FF, bottom: 0x7A78F0, alpha: 0.8)
    let front = CGRect(x: 212, y: 320, width: width + 80, height: 340)
    card(front, top: 0x8280F5, bottom: 0x5754E0)

    // A fish on the front card: body, tail and eye, in near-white.
    ctx.saveGState()
    ctx.translateBy(x: front.midX - 10, y: front.midY)
    let fish = NSBezierPath()
    fish.move(to: CGPoint(x: -150, y: 0))
    fish.curve(to: CGPoint(x: 70, y: 0), controlPoint1: CGPoint(x: -90, y: 100), controlPoint2: CGPoint(x: 10, y: 100))
    fish.curve(to: CGPoint(x: -150, y: 0), controlPoint1: CGPoint(x: 10, y: -100), controlPoint2: CGPoint(x: -90, y: -100))
    fish.close()
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: 55, y: 0))
    tail.line(to: CGPoint(x: 150, y: 78))
    tail.curve(to: CGPoint(x: 150, y: -78), controlPoint1: CGPoint(x: 118, y: 20), controlPoint2: CGPoint(x: 118, y: -20))
    tail.close()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    color(0xFFFFFF, 0.96).setFill()
    fish.fill()
    tail.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    color(0x5754E0).setFill()
    NSBezierPath(ovalIn: CGRect(x: -112, y: 20, width: 30, height: 30)).fill()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS needs 16, 32, 128, 256 and 512 points, each at 1x and 2x.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try render(pixels: slot.points * slot.scale).write(to: outputDir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: outputDir.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(outputDir.path)")
