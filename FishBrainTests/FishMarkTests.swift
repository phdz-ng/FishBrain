import AppKit
import SwiftUI
import XCTest

@MainActor
final class FishMarkTests: XCTestCase {
    /// A rendered image as sRGB bytes, whatever color space the renderer used.
    private struct Pixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drawn)
        }

        func rgb(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
            let offset = (y * width + x) * 4
            let alpha = max(Double(bytes[offset + 3]) / 255, 0.0001)
            return (Double(bytes[offset]) / 255 / alpha, Double(bytes[offset + 1]) / 255 / alpha, Double(bytes[offset + 2]) / 255 / alpha)
        }
    }

    /// Renders at `scale` pixels per point, in the dark scheme the app runs in.
    private func render<V: View>(_ view: V, accent: AccentChoice = .default, scale: CGFloat = 4) throws -> Pixels {
        let renderer = ImageRenderer(content: view.environment(\.accentChoice, accent).preferredColorScheme(.dark))
        renderer.scale = scale
        return try Pixels(XCTUnwrap(renderer.cgImage))
    }

    /// The pixel at a point of the 200 x 320 design box, for a mark `height` points tall.
    private func color(_ pixels: Pixels, designX: Double, designY: Double, height: Double, scale: Double = 4) throws -> (r: Double, g: Double, b: Double) {
        let factor = height / 320 * scale
        return pixels.rgb(x: Int(Double(pixels.width) / 2 + (designX - 100) * factor), y: Int(designY * factor))
    }

    private func assertColor(_ actual: (r: Double, g: Double, b: Double), _ token: Token, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.r, token.red, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(actual.g, token.green, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(actual.b, token.blue, accuracy: 0.02, message, file: file, line: line)
    }

    func testTheHalvesFollowTheAccent() throws {
        for accent in AccentChoice.allCases {
            let rep = try render(FishMark().frame(height: 160), accent: accent)
            assertColor(try color(rep, designX: 60, designY: 120, height: 160), accent.light, "\(accent) left")
            assertColor(try color(rep, designX: 140, designY: 120, height: 160), accent.fill, "\(accent) right")
            // The tail has the same two halves.
            assertColor(try color(rep, designX: 88, designY: 268, height: 160), accent.light, "\(accent) tail left")
            assertColor(try color(rep, designX: 112, designY: 268, height: 160), accent.fill, "\(accent) tail right")
        }
    }

    func testTheSolidStyleIsOneColor() throws {
        let rep = try render(FishMark(style: .solid(Theme.Status.ok), showsEye: false).frame(height: 160))
        assertColor(try color(rep, designX: 60, designY: 120, height: 160), Theme.Status.ok, "left")
        assertColor(try color(rep, designX: 140, designY: 120, height: 160), Theme.Status.ok, "right")
        assertColor(try color(rep, designX: 106, designY: 78, height: 160), Theme.Status.ok, "where the eye would be")
    }

    func testTheEyeIsWhiteOnTheSplitUnlessLeftOut() throws {
        let with = try render(FishMark().frame(height: 160))
        assertColor(try color(with, designX: 100, designY: 78, height: 160), Theme.TextColor.primary, "eye")
        let without = try render(FishMark(showsEye: false).frame(height: 160))
        assertColor(try color(without, designX: 94, designY: 78, height: 160), AccentChoice.default.light, "no eye, left")
        assertColor(try color(without, designX: 106, designY: 78, height: 160), AccentChoice.default.fill, "no eye, right")
    }

    func testTheEyeIsHiddenBelowTwentyPoints() throws {
        XCTAssertTrue(FishMark.isCompact(height: 19.9))
        XCTAssertFalse(FishMark.isCompact(height: 20))
        XCTAssertFalse(FishMark.drawsEye(showsEye: true, height: 19.9))
        XCTAssertTrue(FishMark.drawsEye(showsEye: true, height: 20))
        XCTAssertFalse(FishMark.drawsEye(showsEye: false, height: 200))

        let big = try render(FishMark().frame(height: 20), scale: 16)
        assertColor(try color(big, designX: 100, designY: 78, height: 20, scale: 16), Theme.TextColor.primary, "eye at 20 pt")
        let small = try render(FishMark().frame(height: 19), scale: 16)
        let pixel = try color(small, designX: 94, designY: 78, height: 19, scale: 16)
        XCTAssertNotEqual(pixel.r, 1, accuracy: 0.05, "no eye at 19 pt")
    }

    func testTheCornersAreSharpWhenSmall() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 320)
        let tip = CGPoint(x: 100, y: 21)
        XCTAssertTrue(FishMarkShape(roundsCorners: false).path(in: rect).contains(tip))
        XCTAssertFalse(FishMarkShape(roundsCorners: true).path(in: rect).contains(tip))
    }

    func testTheShapeIsTheMarkFromTheDesign() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 320)
        let sharp = FishMarkShape(roundsCorners: false).path(in: rect).boundingRect
        XCTAssertEqual(sharp.minX, 22, accuracy: 0.5)
        XCTAssertEqual(sharp.maxX, 178, accuracy: 0.5)
        XCTAssertEqual(sharp.minY, 20, accuracy: 0.5)
        XCTAssertEqual(sharp.maxY, 302, accuracy: 0.5)
        let left = FishMarkShape(half: .left, roundsCorners: false).path(in: rect).boundingRect
        let right = FishMarkShape(half: .right, roundsCorners: false).path(in: rect).boundingRect
        XCTAssertEqual(left.maxX, 100, accuracy: 0.5)
        XCTAssertEqual(right.minX, 100, accuracy: 0.5)
    }

    func testItKeepsTheDesignAspectRatioInAnyFrame() {
        XCTAssertEqual(FishMark.aspectRatio, 200.0 / 320.0, accuracy: 0.0001)
        let wide = FishMarkShape(roundsCorners: false).path(in: CGRect(x: 0, y: 0, width: 400, height: 320)).boundingRect
        XCTAssertEqual(wide.midX, 200, accuracy: 0.5, "centered in a frame that is too wide")
        XCTAssertEqual(wide.height, 282, accuracy: 0.5, "scaled by the height, not stretched")
    }

    func testItIsHiddenFromVoiceOverUnlessLabeled() {
        XCTAssertTrue(FishMark.isHiddenFromVoiceOver(label: nil))
        XCTAssertFalse(FishMark.isHiddenFromVoiceOver(label: "FishBrain"))
    }
}
