import CoreGraphics
import CoreText
import Foundation

/// How the Battery style's image is drawn (D113), in Core Graphics only, so
/// tests can render it and read its pixels. The app wraps it in a template
/// image (`MenuBarIconImage`), which the menu bar colours for its light,
/// dark or tinted appearance, and draws the attention symbol, an SF Symbol,
/// where ``Layout`` puts it.
///
/// Coordinates are points, with the origin at the bottom left. Everything
/// is drawn in black: a template image keeps only its alpha. Every function
/// here uses only its arguments and what it makes itself, because AppKit
/// may call an image's drawing handler on whatever thread draws the image.
public enum MenuBarBatteryDrawing {
    /// The image's height: the battery and the text centred, and room for
    /// the attention symbol, the tallest part, in a 22-point menu bar.
    public static let height: CGFloat = 18
    /// The battery's outline, without the nub; about the size of macOS's own
    /// battery icon in the menu bar. Whole points, so a 1-point line on
    /// half points is crisp at 1× and 2×.
    public static let body = CGRect(x: 0, y: 3, width: 24, height: 12)
    static let lineWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 3.5
    /// The nub: a gap of a point after the body, rounded on its outer side.
    public static let nub = CGRect(x: body.maxX + 1, y: 7, width: 1.5, height: 4)
    /// The fill's area: inside the outline with a point of space around it.
    /// The glyph is centred in it.
    public static let inside = body.insetBy(dx: 2, dy: 2)
    public static let insideRadius: CGFloat = 1.5
    /// The narrowest fill above 0%: two pixels at 1×.
    public static let minimumFill: CGFloat = 2
    /// The battery's width, with its nub.
    public static let batteryWidth = ceil(nub.maxX)
    /// The space between the percentage and the battery, and between the
    /// battery and the attention symbol.
    public static let gap: CGFloat = 4

    /// Where the parts of one image go, from left to right: the percentage
    /// at 0, the battery, and the attention symbol.
    public struct Layout: Sendable, Equatable {
        public var batteryX: CGFloat
        /// Nil without an attention symbol.
        public var symbolX: CGFloat?
        public var size: CGSize

        public init(batteryX: CGFloat, symbolX: CGFloat?, size: CGSize) {
            self.batteryX = batteryX
            self.symbolX = symbolX
            self.size = size
        }
    }

    /// The layout for a percentage `textWidth` points wide (0 for none) and
    /// a symbol `symbolWidth` points wide (0 for none), each rounded up to
    /// whole points so the battery stays on whole points.
    public static func layout(textWidth: CGFloat, symbolWidth: CGFloat) -> Layout {
        let text = ceil(textWidth), symbol = ceil(symbolWidth)
        let batteryX = text > 0 ? text + gap : 0
        let batteryEnd = batteryX + batteryWidth
        guard symbol > 0 else {
            return Layout(batteryX: batteryX, symbolX: nil, size: CGSize(width: batteryEnd, height: height))
        }
        let symbolX = batteryEnd + gap
        return Layout(batteryX: batteryX, symbolX: symbolX, size: CGSize(width: symbolX + symbol, height: height))
    }

    /// The percentage as a line of text in `font`.
    public static func line(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    }

    /// The line's width, for ``layout(textWidth:symbolWidth:)``.
    public static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draws the percentage, if any, in `font`, and the battery, where
    /// `layout` puts them. The attention symbol is the caller's.
    public static func draw(_ battery: MenuBarBattery, font: CTFont, layout: Layout, in context: CGContext) {
        if let text = battery.percentageText {
            drawText(line(text, font: font), capHeight: CTFontGetCapHeight(font), in: context)
        }
        context.saveGState()
        context.translateBy(x: layout.batteryX, y: 0)
        drawBattery(battery, in: context)
        context.restoreGState()
    }

    /// The percentage at the left, its capitals centred on the battery, on
    /// a whole-point baseline.
    static func drawText(_ line: CTLine, capHeight: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: (body.midY - capHeight / 2).rounded())
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The battery with its left edge at x = 0: the outline, the nub, the
    /// fill for the charge, and the glyph, cut out of the fill and solid
    /// over the empty part, so it stays legible at any charge.
    public static func drawBattery(_ battery: MenuBarBattery, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let black = CGColor(gray: 0, alpha: 1)
        context.setFillColor(black)
        context.setStrokeColor(black)

        let outline = body.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.addPath(CGPath(roundedRect: outline, cornerWidth: cornerRadius - lineWidth / 2, cornerHeight: cornerRadius - lineWidth / 2, transform: nil))
        context.setLineWidth(lineWidth)
        context.strokePath()

        // Square on the body's side, rounded on the outer one.
        let nubRadius = nub.width / 2
        let nubPath = CGMutablePath()
        nubPath.move(to: CGPoint(x: nub.minX, y: nub.minY))
        nubPath.addLine(to: CGPoint(x: nub.maxX - nubRadius, y: nub.minY))
        nubPath.addArc(tangent1End: CGPoint(x: nub.maxX, y: nub.minY), tangent2End: CGPoint(x: nub.maxX, y: nub.midY), radius: nubRadius)
        nubPath.addArc(tangent1End: CGPoint(x: nub.maxX, y: nub.maxY), tangent2End: CGPoint(x: nub.maxX - nubRadius, y: nub.maxY), radius: nubRadius)
        nubPath.addLine(to: CGPoint(x: nub.minX, y: nub.maxY))
        nubPath.closeSubpath()
        context.addPath(nubPath)
        context.fillPath()

        // The fill: the inside's rounded shape, cut straight at the charge.
        let fillWidth = CGFloat(battery.fillWidth(in: Double(inside.width), minimum: Double(minimumFill)))
        let filled = CGRect(x: inside.minX, y: inside.minY, width: fillWidth, height: inside.height)
        let empty = CGRect(x: filled.maxX, y: inside.minY, width: inside.maxX - filled.maxX, height: inside.height)
        context.saveGState()
        context.addPath(CGPath(roundedRect: inside, cornerWidth: insideRadius, cornerHeight: insideRadius, transform: nil))
        context.clip()
        context.fill(filled)
        context.restoreGState()

        // The glyph: cut out of the fill, solid over the empty part.
        guard let glyph = glyphPath(battery.glyph, centre: CGPoint(x: inside.midX, y: inside.midY)) else { return }
        context.addPath(glyph)
        context.clip()
        context.setBlendMode(.clear)
        context.fill(filled)
        context.setBlendMode(.normal)
        context.fill(empty)
    }

    /// The bolt or the plug, drawn for CellKeeper, inside the fill's area.
    static func glyphPath(_ glyph: MenuBarBattery.Glyph, centre c: CGPoint) -> CGPath? {
        switch glyph {
        case .none:
            return nil
        case .bolt:
            // 6 × 8 points, the fill's height, 14 square points: a top
            // stroke down to the left, a step to the right, a bottom stroke
            // down to the left, and back up the other side.
            let path = CGMutablePath()
            path.addLines(between: [
                CGPoint(x: c.x + 1.25, y: c.y + 4),
                CGPoint(x: c.x - 3, y: c.y - 0.5),
                CGPoint(x: c.x - 0.5, y: c.y - 0.5),
                CGPoint(x: c.x - 1.25, y: c.y - 4),
                CGPoint(x: c.x + 3, y: c.y + 0.5),
                CGPoint(x: c.x + 0.5, y: c.y + 0.5),
            ])
            path.closeSubpath()
            return path
        case .plug:
            // 9 × 6 points, pointing at the nub: a cord, a body and two
            // prongs, side by side without overlapping.
            let path = CGMutablePath()
            path.addRect(CGRect(x: c.x - 4.5, y: c.y - 1, width: 2, height: 2))
            path.addRoundedRect(in: CGRect(x: c.x - 2.5, y: c.y - 3, width: 4, height: 6), cornerWidth: 1, cornerHeight: 1)
            path.addRect(CGRect(x: c.x + 1.5, y: c.y + 1, width: 3, height: 1))
            path.addRect(CGRect(x: c.x + 1.5, y: c.y - 2, width: 3, height: 1))
            return path
        }
    }
}
