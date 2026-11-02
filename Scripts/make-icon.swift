#!/usr/bin/env swift
// Draws the FishBrain app icon at every size macOS needs and writes the asset catalog.
//   swift Scripts/make-icon.swift
// Counterchange: a rounded tile split down the middle, pale orange on the left and deep orange on the right,
// with the FishBrain fish centered on the split and its two halves swapped against the tile behind them.
// Everything is drawn from the 1024-point design, scaled per size; at 16 and 32 pixels the mark is simplified
// (no eye and sharp corners at 16, a larger eye at 32) so it stays readable. The icon is always Orange.
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "FishBrain/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let pale = color(0xFFA36B)
let deep = color(0xC2410C)

/// A closed polygon with every corner rounded by `radius` (sharp when it is 0), in the fish's design box.
func lozenge(_ corners: [CGPoint], radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    guard radius > 0 else {
        path.move(to: corners[0])
        corners.dropFirst().forEach { path.line(to: $0) }
        path.close()
        return path
    }
    let last = corners[corners.count - 1]
    path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
    for (index, corner) in corners.enumerated() {
        path.appendArc(from: corner, to: corners[(index + 1) % corners.count], radius: radius)
    }
    path.close()
    return path
}

/// Draws the icon into the current context, in a 1024 x 1024 coordinate space. `pixels` is the size it will be
/// scaled to, used to simplify the mark at the smallest sizes.
func drawIcon(pixels: Int) {
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    let rightHalf = CGRect(x: tile.midX, y: -1000, width: 3000, height: 3000)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    deep.setFill()
    tilePath.fill()
    ctx.restoreGState()

    // The tile: pale on the left, deep on the right, split exactly at the center, no gradient.
    ctx.saveGState()
    tilePath.addClip()
    pale.setFill()
    tile.fill()
    ctx.clip(to: rightHalf)
    deep.setFill()
    tile.fill()
    ctx.restoreGState()
    color(0xFFFFFF, 0.22).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184.5, yRadius: 184.5)
    rim.lineWidth = 3
    rim.stroke()

    // The fish, in its 200 x 320 design box (y down), 68% of the tile's height and centered on the split.
    // Its halves are swapped against the tile: deep over the pale side, pale over the deep side.
    let scale = tile.height * 0.68 / 320
    ctx.saveGState()
    ctx.translateBy(x: tile.midX, y: tile.midY)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -100, y: -160)
    let rounded = pixels > 16
    let body = lozenge([CGPoint(x: 100, y: 20), CGPoint(x: 178, y: 120), CGPoint(x: 100, y: 220), CGPoint(x: 22, y: 120)], radius: rounded ? 10 : 0)
    let tail = lozenge([CGPoint(x: 100, y: 234), CGPoint(x: 130, y: 268), CGPoint(x: 100, y: 302), CGPoint(x: 70, y: 268)], radius: rounded ? 6 : 0)
    deep.setFill()
    body.fill()
    tail.fill()
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 100, y: 0, width: 100, height: 320))
    pale.setFill()
    body.fill()
    tail.fill()
    ctx.restoreGState()
    if pixels > 16 {
        let radius: CGFloat = pixels <= 32 ? 18 : 14
        color(0xFFFFFF).setFill()
        NSBezierPath(ovalIn: CGRect(x: 100 - radius, y: 78 - radius, width: radius * 2, height: radius * 2)).fill()
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    // Tagged sRGB up front, so the hex colors are stored as they are written and the PNG carries the profile.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    drawIcon(pixels: pixels)
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
