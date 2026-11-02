#!/usr/bin/env swift
// Writes the FishBrain logo files: the SVG masters in docs/brand, their PNG exports (512 and 1024) and the
// GitHub social preview (1280 x 640).
//   swift Scripts/make-brand.swift path/to/Outfit-Bold.ttf [docs/brand]
// The wordmark is Outfit Bold (SIL Open Font License), converted to outlines here so the SVGs don't depend on
// installed fonts; the font file itself is not kept in the repository. The mark is the one in
// Shared/DesignSystem/Components/FishMark.swift and Scripts/make-icon.swift, in a 200 x 320 box.
import AppKit
import CoreText

let arguments = CommandLine.arguments.dropFirst()
guard let fontPath = arguments.first else {
    print("usage: swift Scripts/make-brand.swift path/to/Outfit-Bold.ttf [output directory]")
    exit(1)
}
let outputDir = URL(fileURLWithPath: arguments.dropFirst().first ?? "docs/brand")

let pale = "#FFA36B"
let deep = "#C2410C"
let ink = "#1F1A17"

func number(_ value: CGFloat) -> String {
    var text = String(format: "%.2f", Double(value))
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

/// A closed polygon with every corner rounded by `radius`, as SVG path data (y down).
func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> String {
    var path = ""
    for (index, corner) in points.enumerated() {
        let before = points[(index + points.count - 1) % points.count]
        let after = points[(index + 1) % points.count]
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let length = hypot(to.x - from.x, to.y - from.y)
            return CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
        }
        let u = unit(corner, before), v = unit(corner, after)
        let angle = acos(u.x * v.x + u.y * v.y)
        let reach = radius / tan(angle / 2)
        let start = CGPoint(x: corner.x + u.x * reach, y: corner.y + u.y * reach)
        let end = CGPoint(x: corner.x + v.x * reach, y: corner.y + v.y * reach)
        // Clockwise on screen (y down) is sweep 1.
        let cross = (corner.x - before.x) * (after.y - corner.y) - (corner.y - before.y) * (after.x - corner.x)
        path += (index == 0 ? "M" : "L") + "\(number(start.x)) \(number(start.y))"
        path += "A\(number(radius)) \(number(radius)) 0 0 \(cross > 0 ? 1 : 0) \(number(end.x)) \(number(end.y))"
    }
    return path + "Z"
}

/// The fish in its 200 x 320 design box: body and tail.
let fish = roundedPolygon([CGPoint(x: 100, y: 20), CGPoint(x: 178, y: 120), CGPoint(x: 100, y: 220), CGPoint(x: 22, y: 120)], radius: 10)
    + roundedPolygon([CGPoint(x: 100, y: 234), CGPoint(x: 130, y: 268), CGPoint(x: 100, y: 302), CGPoint(x: 70, y: 268)], radius: 6)
let eyeRadius: CGFloat = 14
let eyeCenter = CGPoint(x: 100, y: 78)
let eye = "<circle cx=\"100\" cy=\"78\" r=\"14\" fill=\"#FFFFFF\"/>"

/// The two-tone fish: `left` over the whole of it, `right` over the half right of the split.
func twoToneFish(left: String, right: String, eyeColor: String? = "#FFFFFF", id: String) -> String {
    var markup = """
    <defs><clipPath id="\(id)"><rect x="100" y="0" width="100" height="320"/></clipPath></defs>
    <path d="\(fish)" fill="\(left)"/>
    <path d="\(fish)" fill="\(right)" clip-path="url(#\(id))"/>
    """
    if let eyeColor { markup += "\n<circle cx=\"100\" cy=\"78\" r=\"14\" fill=\"\(eyeColor)\"/>" }
    return markup
}

func svg(width: CGFloat, height: CGFloat, viewBox: String, title: String, body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(number(width))" height="\(number(height))" viewBox="\(viewBox)" role="img" aria-label="\(title)">
    <title>\(title)</title>
    \(body)
    </svg>

    """
}

// MARK: Wordmark outlines

/// "Fish" and "Brain" as SVG path data in a y-down space, with the baseline at y = 0 and the left edge at x = 0.
func wordmark(fontAt path: String, size: CGFloat) -> (fish: String, brain: String, width: CGFloat, capHeight: CGFloat) {
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor]
    guard let descriptor = descriptors?.first else { fatalError("Cannot read the font at \(path)") }
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "FishBrain", attributes: [.font: font]))
    var fishData = "", brainData = ""
    var glyphIndex = 0
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        for (glyph, position) in zip(glyphs, positions) {
            guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { glyphIndex += 1; continue }
            var data = ""
            outline.applyWithBlock { element in
                let p = element.pointee.points
                func at(_ i: Int) -> String { "\(number(position.x + p[i].x)) \(number(-p[i].y))" }
                switch element.pointee.type {
                case .moveToPoint: data += "M\(at(0))"
                case .addLineToPoint: data += "L\(at(0))"
                case .addQuadCurveToPoint: data += "Q\(at(0)) \(at(1))"
                case .addCurveToPoint: data += "C\(at(0)) \(at(1)) \(at(2))"
                case .closeSubpath: data += "Z"
                @unknown default: break
                }
            }
            if glyphIndex < 4 { fishData += data } else { brainData += data }
            glyphIndex += 1
        }
    }
    return (fishData, brainData, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTFontGetCapHeight(font))
}

let text = wordmark(fontAt: fontPath, size: 200)

/// The mark beside the word "FishBrain": the mark's own box (22 to 178 across, 20 to 302 down) on the left, the
/// cap height of the word centered on the mark's body.
func lockup(fishColor: String, brainColor: String) -> String {
    let gap: CGFloat = 52
    let textX = 178 + gap
    let baseline = 161 + text.capHeight / 2
    let width = textX + text.width - 22
    return svg(width: width, height: 282, viewBox: "22 20 \(number(width)) 282", title: "FishBrain", body: """
    \(twoToneFish(left: pale, right: deep, id: "right"))
    <g transform="translate(\(number(textX)) \(number(baseline)))">
    <path d="\(text.fish)" fill="\(fishColor)"/>
    <path d="\(text.brain)" fill="\(brainColor)"/>
    </g>
    """)
}

// MARK: Files

func write(_ name: String, _ contents: String) throws {
    try contents.write(to: outputDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

try write("fishbrain-mark.svg", svg(width: 200, height: 320, viewBox: "0 0 200 320", title: "FishBrain",
                                    body: twoToneFish(left: pale, right: deep, id: "right")))

// One color, with the eye cut through so it works on any background.
let eyeHole = "M86 78a14 14 0 1 0 28 0a14 14 0 1 0 -28 0Z"
try write("fishbrain-mark-mono.svg", svg(width: 200, height: 320, viewBox: "0 0 200 320", title: "FishBrain",
                                         body: "<path d=\"\(fish)\(eyeHole)\" fill=\"currentColor\" fill-rule=\"evenodd\"/>"))

// The Counterchange tile: the app icon's design, edge to edge. The fish is 68% of the tile's height.
let tile: CGFloat = 824
let fishScale = tile * 0.68 / 320
try write("fishbrain-icon.svg", svg(width: tile, height: tile, viewBox: "0 0 \(number(tile)) \(number(tile))", title: "FishBrain", body: """
    <defs>
    <clipPath id="tile"><rect width="824" height="824" rx="186"/></clipPath>
    <clipPath id="right"><rect x="100" y="0" width="100" height="320"/></clipPath>
    </defs>
    <g clip-path="url(#tile)">
    <rect width="824" height="824" fill="\(pale)"/>
    <rect x="412" width="412" height="824" fill="\(deep)"/>
    </g>
    <rect x="1.5" y="1.5" width="821" height="821" rx="184.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.22" stroke-width="3"/>
    <g transform="translate(412 412) scale(\(number(fishScale))) translate(-100 -160)">
    <path d="\(fish)" fill="\(deep)"/>
    <path d="\(fish)" fill="\(pale)" clip-path="url(#right)"/>
    \(eye)
    </g>
    """))

try write("fishbrain-lockup.svg", lockup(fishColor: ink, brainColor: deep))
try write("fishbrain-lockup-dark.svg", lockup(fishColor: "#FFFFFF", brainColor: pale))

// MARK: PNG exports

func draw(_ svgName: String, into pixelsWide: Int, _ pixelsHigh: Int, background: NSColor? = nil, inset: NSRect? = nil) throws -> Data {
    let image = try { () throws -> NSImage in
        guard let image = NSImage(contentsOf: outputDir.appendingPathComponent(svgName)) else { fatalError("Cannot read \(svgName)") }
        return image
    }()
    // Tagged sRGB up front, so the hex colors are stored as they are written.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    if let background {
        background.setFill()
        NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh).fill()
    }
    image.draw(in: inset ?? NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The pixel size at which the longer side of the SVG is `longSide`.
func size(of svgName: String, longSide: Int) -> (Int, Int) {
    let natural = NSImage(contentsOf: outputDir.appendingPathComponent(svgName))!.size
    let scale = CGFloat(longSide) / max(natural.width, natural.height)
    return (Int((natural.width * scale).rounded()), Int((natural.height * scale).rounded()))
}

for name in ["fishbrain-mark", "fishbrain-icon", "fishbrain-lockup", "fishbrain-lockup-dark"] {
    for longSide in [512, 1024] {
        let (width, height) = size(of: "\(name).svg", longSide: longSide)
        try draw("\(name).svg", into: width, height).write(to: outputDir.appendingPathComponent("\(name)-\(longSide).png"))
    }
}

// The social preview: the lockup, 60% of the width, centered on the app's cream.
let natural = NSImage(contentsOf: outputDir.appendingPathComponent("fishbrain-lockup.svg"))!.size
let lockupWidth: CGFloat = 1280 * 0.6
let lockupHeight = lockupWidth * natural.height / natural.width
try draw("fishbrain-lockup.svg", into: 1280, 640,
         background: NSColor(srgbRed: 1, green: 0xF4 / 255, blue: 0xEC / 255, alpha: 1),
         inset: NSRect(x: (1280 - lockupWidth) / 2, y: (640 - lockupHeight) / 2, width: lockupWidth, height: lockupHeight))
    .write(to: outputDir.appendingPathComponent("social-preview.png"))
print("Wrote the logo files to \(outputDir.path)")
