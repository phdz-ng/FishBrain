#!/usr/bin/env swift
// Draws the FishBrain app icon at every size macOS needs and writes the asset catalog, plus the layers and
// description of the Icon Composer icon used on macOS 26.
//   swift Scripts/make-icon.swift
// Counterchange: a rounded tile split down the middle, pale orange on the left and deep orange on the right,
// with the FishBrain fish centered on the split and its two halves swapped against the tile behind them.
// Everything is drawn from the 1024-point design, scaled per size; at 16 and 32 pixels the mark is simplified
// (no eye and sharp corners at 16, a larger eye at 32) so it stays readable. The icon is always Orange.
// The asset catalog is the icon for macOS 14 to 25. On macOS 26 AppIcon.icon takes over, and the system
// picks its Default, Dark, Clear or Tinted style: the layers are drawn here, full bleed, and the system
// rounds the tile and adds its own glass.
import AppKit

let arguments = CommandLine.arguments.dropFirst()
let outputDir = URL(fileURLWithPath: arguments.first ?? "FishBrain/Assets.xcassets/AppIcon.appiconset")
let iconDir = URL(fileURLWithPath: arguments.dropFirst().first ?? "FishBrain/AppIcon.icon")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let pale = color(0xFFA36B)
let deep = color(0xC2410C)
let darkPale = color(0x3D2418)

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

enum Half {
    case left, right

    /// The half of the fish's 200 x 320 design box on this side of the split at x = 100.
    var box: CGRect { CGRect(x: self == .left ? -1000 : 100, y: -1000, width: self == .left ? 1100 : 1000, height: 3000) }
}

/// Runs `draw` in the fish's 200 x 320 design box (y down), 68% of `height` tall and centered at (`centerX`, 512)
/// in the 1024 x 1024 space, optionally clipped to one half.
func inFishSpace(centerX: CGFloat, height: CGFloat, half: Half? = nil, _ draw: () -> Void) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: 512)
    let scale = height * 0.68 / 320
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -100, y: -160)
    if let half { ctx.clip(to: half.box) }
    draw()
    ctx.restoreGState()
}

/// Fills the fish's body and tail, in the design box.
func fillFish(_ fill: NSColor, pixels: Int = 1024) {
    let rounded = pixels > 16
    fill.setFill()
    lozenge([CGPoint(x: 100, y: 20), CGPoint(x: 178, y: 120), CGPoint(x: 100, y: 220), CGPoint(x: 22, y: 120)], radius: rounded ? 10 : 0).fill()
    lozenge([CGPoint(x: 100, y: 234), CGPoint(x: 130, y: 268), CGPoint(x: 100, y: 302), CGPoint(x: 70, y: 268)], radius: rounded ? 6 : 0).fill()
}

/// The eye on the split, in the design box: white, or with `cut` a hole through what is under it. None at 16 pixels.
func drawEye(pixels: Int = 1024, cut: Bool = false) {
    guard pixels > 16 else { return }
    let radius: CGFloat = pixels <= 32 ? 18 : 14
    if cut {
        NSGraphicsContext.current!.compositingOperation = .clear
    } else {
        color(0xFFFFFF).setFill()
    }
    NSBezierPath(ovalIn: CGRect(x: 100 - radius, y: 78 - radius, width: radius * 2, height: radius * 2)).fill()
}

/// Draws the icon into the current context, in a 1024 x 1024 coordinate space. `pixels` is the size it will be
/// scaled to, used to simplify the mark at the smallest sizes.
func drawIcon(pixels: Int) {
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

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
    ctx.clip(to: CGRect(x: tile.midX, y: -1000, width: 3000, height: 3000))
    deep.setFill()
    tile.fill()
    ctx.restoreGState()
    color(0xFFFFFF, 0.22).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184.5, yRadius: 184.5)
    rim.lineWidth = 3
    rim.stroke()

    // The fish, centered on the split. Its halves are swapped against the tile: deep over the pale side, pale
    // over the deep side. The whole fish goes down in deep first, so the seam never shows the tile through.
    inFishSpace(centerX: tile.midX, height: tile.height) {
        fillFish(deep, pixels: pixels)
        drawEye(pixels: pixels)
    }
    inFishSpace(centerX: tile.midX, height: tile.height, half: .right) {
        fillFish(pale, pixels: pixels)
        drawEye(pixels: pixels)
    }
}

/// Renders `draw` into a transparent bitmap `pixels` wide and high, scaled from the 1024-point design.
func render(pixels: Int, _ draw: () -> Void) -> Data {
    // Tagged sRGB up front, so the hex colors are stored as they are written and the PNG carries the profile.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS needs 16, 32, 128, 256 and 512 points, each at 1x and 2x.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try render(pixels: slot.points * slot.scale) { drawIcon(pixels: slot.points * slot.scale) }.write(to: outputDir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: outputDir.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(outputDir.path)")

// The Icon Composer icon for macOS 26: full-bleed layers (the system rounds the tile) and icon.json.
// Default and Dark use the colored layers (Dark swaps in the dark left tile half). Clear and Tinted drop the tile
// and the eye, and the system turns the fish into glass or tint: the deep left half comes out darker than the
// pale right half, and the left is also faded. icon.json has no separate Clear appearance: Clear and Tinted share
// the "tinted" settings, so Clear gets the Tinted strengths.
let layerDir = iconDir.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)
func writeLayer(_ name: String, _ draw: @escaping () -> Void) throws {
    try render(pixels: 1024, draw).write(to: layerDir.appendingPathComponent(name))
}
try writeLayer("tile-left.png") {
    pale.setFill()
    CGRect(x: 0, y: 0, width: 512, height: 1024).fill()
}
try writeLayer("tile-left-dark.png") {
    darkPale.setFill()
    CGRect(x: 0, y: 0, width: 512, height: 1024).fill()
}
try writeLayer("tile-right.png") {
    deep.setFill()
    CGRect(x: 512, y: 0, width: 512, height: 1024).fill()
}
// The fish halves have the eye cut out, so Clear and Tinted show a hole there; Default and Dark put the white
// eye back in a layer of its own, which Clear and Tinted hide.
try writeLayer("fish-left.png") { inFishSpace(centerX: 512, height: 1024, half: .left) { fillFish(deep); drawEye(cut: true) } }
try writeLayer("fish-right.png") { inFishSpace(centerX: 512, height: 1024, half: .right) { fillFish(pale); drawEye(cut: true) } }
try writeLayer("eye.png") { inFishSpace(centerX: 512, height: 1024) { drawEye() } }

func srgb(_ hex: UInt32) -> String {
    let c = color(hex)
    return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
}
/// A layer that is hidden in the given appearances (or, with `onlyIn`, shown in only those) and optionally faded in
/// Tinted. A specialization list starts with the entry for every other appearance, then one per appearance.
func layer(_ name: String, image: String, hiddenIn hidden: [String] = [], onlyIn only: [String] = [], tintedOpacity: Double? = nil) -> [String: Any] {
    var layer: [String: Any] = ["name": name, "image-name": image, "glass": false]
    if !only.isEmpty {
        layer["hidden-specializations"] = [["value": true]] + only.map { ["appearance": $0, "value": false] as [String: Any] }
    } else if !hidden.isEmpty {
        layer["hidden-specializations"] = [["value": false]] + hidden.map { ["appearance": $0, "value": true] as [String: Any] }
    }
    if let tintedOpacity {
        layer["opacity-specializations"] = [["value": 1.0], ["appearance": "tinted", "value": tintedOpacity] as [String: Any]]
    }
    return layer
}
let layers: [[String: Any]] = [
    layer("tile-left", image: "tile-left.png", hiddenIn: ["dark", "tinted"]),
    layer("tile-left-dark", image: "tile-left-dark.png", onlyIn: ["dark"]),
    layer("tile-right", image: "tile-right.png", hiddenIn: ["tinted"]),
    layer("fish-left", image: "fish-left.png", tintedOpacity: 0.55),
    layer("fish-right", image: "fish-right.png"),
    layer("eye", image: "eye.png", hiddenIn: ["tinted"]),
]
let description: [String: Any] = [
    "fill": ["solid": srgb(0xFFA36B)],
    "groups": [["layers": Array(layers.reversed()), "shadow": ["kind": "none", "opacity": 0], "translucency": ["enabled": false, "value": 0]]],
    "supported-platforms": ["squares": ["macOS"]],
]
try JSONSerialization.data(withJSONObject: description, options: [.prettyPrinted, .sortedKeys]).write(to: iconDir.appendingPathComponent("icon.json"))
print("Wrote \(iconDir.path)")
