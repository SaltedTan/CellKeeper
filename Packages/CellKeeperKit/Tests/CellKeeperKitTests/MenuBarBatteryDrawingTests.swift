import CellKeeperKit
import CoreGraphics
import Foundation
import Testing

/// The battery drawn into a bitmap `scale` pixels to the point, kept as the
/// alpha of each pixel, the only thing a template image keeps. The tests
/// read areas, not single pixels or golden images, so antialiasing and font
/// rendering differences between toolchains do not matter; no text is
/// drawn.
private struct RenderedBattery {
    let scale: Int
    let width: Int
    let height: Int
    /// Row 0 is the top of the image.
    let alpha: [UInt8]

    init(_ battery: MenuBarBattery, scale: Int) {
        self.scale = scale
        width = Int(MenuBarBatteryDrawing.batteryWidth) * scale
        height = Int(MenuBarBatteryDrawing.height) * scale
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        MenuBarBatteryDrawing.drawBattery(battery, in: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        alpha = (0..<(width * height)).map { bytes[$0 * 4 + 3] }
    }

    /// The area drawn, in square points, by the pixels whose centres lie in
    /// `rect` (in points, origin at the bottom left).
    func coverage(in rect: CGRect) -> Double {
        let s = Double(scale)
        var total = 0.0
        for row in 0..<height {
            let y = (Double(height - 1 - row) + 0.5) / s
            for column in 0..<width where rect.contains(CGPoint(x: (Double(column) + 0.5) / s, y: y)) {
                total += Double(alpha[row * width + column]) / 255
            }
        }
        return total / (s * s)
    }
}

private func battery(_ percent: Int, _ glyph: MenuBarBattery.Glyph) -> MenuBarBattery {
    MenuBarBattery(percent: percent, glyph: glyph, percentageText: nil, attentionSymbol: nil)
}

/// The fill's area, 20 × 8 points, where the glyph is centred at (12, 9).
private let inside = MenuBarBatteryDrawing.inside

/// The inside to the left and to the right of `x`.
private func left(of x: CGFloat) -> CGRect {
    CGRect(x: inside.minX, y: inside.minY, width: x - inside.minX, height: inside.height)
}

private func right(of x: CGFloat) -> CGRect {
    CGRect(x: x, y: inside.minY, width: inside.maxX - x, height: inside.height)
}

/// What one rounded corner of the inside (radius 1.5) leaves out.
private let cornerLoss = 1.5 * 1.5 * (1 - Double.pi / 4)

/// The glyphs' areas in square points: the bolt's polygon, and the plug's
/// cord (2 × 2), body (4 × 6, corners of radius 1) and prongs (2 × 3 × 1).
private let boltArea = 14.0
private let plugBody = 24 - 4 * (1 - Double.pi / 4)
private let plugArea = 4 + plugBody + 6

/// How much more the glyph draws than no glyph in `rect`: negative where it
/// is cut out of the fill, positive where it is solid over the empty part.
private func glyphDelta(_ glyph: MenuBarBattery.Glyph, percent: Int, scale: Int, in rect: CGRect) -> Double {
    RenderedBattery(battery(percent, glyph), scale: scale).coverage(in: rect)
        - RenderedBattery(battery(percent, .none), scale: scale).coverage(in: rect)
}

@Suite("Menu bar battery drawing")
struct MenuBarBatteryDrawingTests {
    @Test("Without a glyph, only the fill is drawn inside, as wide as the charge", arguments: [1, 2])
    func fillFollowsCharge(scale: Int) {
        let charges: [(percent: Int, width: Double)] = [(0, 0), (1, 2), (20, 4), (50, 10), (64, 13), (100, 20)]
        for (percent, width) in charges {
            let rendered = RenderedBattery(battery(percent, .none), scale: scale)
            let corners: Double = width == 0 ? 0 : width == 20 ? 4 : 2
            let expected = width * 8 - corners * cornerLoss
            #expect(abs(rendered.coverage(in: inside) - expected) < 1, "\(percent)% at \(scale)×")
            // Nothing beyond the fill's end.
            #expect(rendered.coverage(in: right(of: inside.minX + width)) < 0.05, "\(percent)% at \(scale)×")
        }
    }

    @Test("The outline, the gap inside it and the nub are drawn on whole pixels", arguments: [1, 2])
    func outlineAndNub(scale: Int) {
        let rendered = RenderedBattery(battery(100, .none), scale: scale)
        // The outline's left side, a point wide.
        #expect(abs(rendered.coverage(in: CGRect(x: 0, y: 7, width: 1, height: 4)) - 4) < 0.05)
        // The point of space between the outline and a full fill.
        #expect(rendered.coverage(in: CGRect(x: 1, y: 6, width: 1, height: 6)) < 0.05)
        // The nub's first point, before its rounded side.
        #expect(abs(rendered.coverage(in: CGRect(x: 25, y: 7, width: 1, height: 4)) - 4) < 0.05)
    }

    @Test("At 100% the glyph is still visible: cut out of the full fill", arguments: [1, 2])
    func cutOutOfFullFill(scale: Int) {
        #expect(abs(glyphDelta(.bolt, percent: 100, scale: scale, in: inside) + boltArea) < 1)
        #expect(abs(glyphDelta(.plug, percent: 100, scale: scale, in: inside) + plugArea) < 1)
        // The glyph removes a fifth of the full fill or more, so it shows.
        let full = RenderedBattery(battery(100, .none), scale: scale).coverage(in: inside)
        let withBolt = RenderedBattery(battery(100, .bolt), scale: scale).coverage(in: inside)
        #expect(withBolt < full - 0.8 * boltArea)
    }

    @Test("Over an empty battery the glyph is solid", arguments: [1, 2])
    func solidOverEmpty(scale: Int) {
        #expect(abs(glyphDelta(.bolt, percent: 0, scale: scale, in: inside) - boltArea) < 1)
        #expect(abs(glyphDelta(.plug, percent: 0, scale: scale, in: inside) - plugArea) < 1)
    }

    @Test("Across a partial fill, the glyph is cut out where filled and solid where empty", arguments: [1, 2])
    func partialFill(scale: Int) {
        // At 50% the fill ends at x = 12, through the glyph's centre: the
        // bolt is symmetric about it; the plug has its cord and 2.5 points
        // of its body on the left, 1.5 points and the prongs on the right.
        let edge = inside.minX + 10
        #expect(abs(glyphDelta(.bolt, percent: 50, scale: scale, in: left(of: edge)) + boltArea / 2) < 1)
        #expect(abs(glyphDelta(.bolt, percent: 50, scale: scale, in: right(of: edge)) - boltArea / 2) < 1)
        let plugLeft = 4 + 2.5 * 6 - 2 * (1 - Double.pi / 4)
        #expect(abs(glyphDelta(.plug, percent: 50, scale: scale, in: left(of: edge)) + plugLeft) < 1)
        #expect(abs(glyphDelta(.plug, percent: 50, scale: scale, in: right(of: edge)) - (plugArea - plugLeft)) < 1)
        // At 64% the fill ends at x = 15: the bolt (x 9–15) is all cut out;
        // the plug's prongs reach 1.5 points past it.
        let edge64 = inside.minX + 13
        #expect(abs(glyphDelta(.bolt, percent: 64, scale: scale, in: left(of: edge64)) + boltArea) < 1)
        #expect(abs(glyphDelta(.bolt, percent: 64, scale: scale, in: right(of: edge64))) < 0.05)
        #expect(abs(glyphDelta(.plug, percent: 64, scale: scale, in: right(of: edge64)) - 3) < 0.5)
    }

    @Test("No glyph draws nothing over the empty part, at any charge", arguments: [1, 2])
    func noGlyph(scale: Int) {
        #expect(RenderedBattery(battery(0, .none), scale: scale).coverage(in: inside) < 0.05)
        #expect(RenderedBattery(battery(50, .none), scale: scale).coverage(in: right(of: inside.minX + 10)) < 0.05)
    }

    @Test("The layout puts the battery after the percentage and the symbol after the battery, on whole points")
    func layout() {
        let bare = MenuBarBatteryDrawing.layout(textWidth: 0, symbolWidth: 0)
        #expect(bare == MenuBarBatteryDrawing.Layout(batteryX: 0, symbolX: nil, size: CGSize(width: 27, height: 18)))
        let text = MenuBarBatteryDrawing.layout(textWidth: 28.2, symbolWidth: 0)
        #expect(text == MenuBarBatteryDrawing.Layout(batteryX: 33, symbolX: nil, size: CGSize(width: 60, height: 18)))
        let both = MenuBarBatteryDrawing.layout(textWidth: 28.2, symbolWidth: 16.4)
        #expect(both == MenuBarBatteryDrawing.Layout(batteryX: 33, symbolX: 64, size: CGSize(width: 81, height: 18)))
        let symbolOnly = MenuBarBatteryDrawing.layout(textWidth: 0, symbolWidth: 10)
        #expect(symbolOnly == MenuBarBatteryDrawing.Layout(batteryX: 0, symbolX: 31, size: CGSize(width: 41, height: 18)))
    }
}
