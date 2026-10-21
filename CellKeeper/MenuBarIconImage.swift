import AppKit
import CellKeeperKit
import CoreText

/// The Battery style's image (D113): a template image CellKeeper draws
/// itself, so the menu bar gives it the colour of its light, dark or tinted
/// appearance as it does its own icons. It holds, from left to right, the
/// percentage, a rounded battery with a terminal nub whose fill follows the
/// charge, and a symbol for a state that needs attention, each shown only
/// when ``MenuBarBattery`` has it. The glyph inside the battery is cut out
/// of the fill and solid over the empty part, so it stays legible at any
/// charge. Everything is drawn into the one image, so the status item keeps
/// a single element with the app's VoiceOver label, as before.
@MainActor
enum MenuBarIconImage {
    /// One image per battery: the fill is in whole percent, so a reading
    /// that changes nothing shown reuses the image, and the status item is
    /// not redrawn.
    private static var cache: [MenuBarBattery: NSImage] = [:]
    /// More than the batteries a session normally shows at once (the
    /// charge moves a few percent an hour); emptied when full.
    private static let cacheLimit = 32

    static func image(for battery: MenuBarBattery) -> NSImage {
        if let cached = cache[battery] { return cached }
        if cache.count >= cacheLimit { cache.removeAll() }
        let image = BatteryDrawing.image(for: battery)
        cache[battery] = image
        return image
    }
}

/// The drawing, outside the main actor: AppKit may call an image's drawing
/// handler on whatever thread draws the image, so the handler uses only the
/// values it captures and what it makes itself.
private enum BatteryDrawing {
    /// The image's height, in points: the battery and the text centred, and
    /// room for the attention symbol, the tallest part, in a 22-point menu
    /// bar.
    static let height: CGFloat = 18
    /// The battery's outline, without the nub; about the size of macOS's own
    /// battery icon in the menu bar. Whole points, so a 1-point line on
    /// half points is crisp at 1× and 2×.
    static let body = CGRect(x: 0, y: 3, width: 24, height: 12)
    static let lineWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 3.5
    /// The nub: a gap of a point after the body, rounded on its outer side.
    static let nub = CGRect(x: body.maxX + 1, y: 7, width: 1.5, height: 4)
    /// The fill's area: inside the outline with a point of space around it.
    static let inside = body.insetBy(dx: 2, dy: 2)
    static let insideRadius: CGFloat = 1.5
    /// The narrowest fill above 0%: two pixels at 1×.
    static let minimumFill: CGFloat = 2
    static let batteryWidth = ceil(nub.maxX)
    /// The space between the percentage and the battery, and between the
    /// battery and the attention symbol.
    static let gap: CGFloat = 4

    /// The menu bar's font with digits of equal width, so the percentage
    /// does not change width as the charge changes (only with the number of
    /// digits).
    static var percentageFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    static func attentionImage(named name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular))
    }

    static func line(_ text: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: percentageFont]))
    }

    static func image(for battery: MenuBarBattery) -> NSImage {
        let textWidth = battery.percentageText.map { ceil(CTLineGetTypographicBounds(line($0), nil, nil, nil)) } ?? 0
        let symbolWidth = battery.attentionSymbol.flatMap(attentionImage(named:)).map { ceil($0.size.width) } ?? 0
        let batteryX = textWidth > 0 ? textWidth + gap : 0
        let symbolX = batteryX + batteryWidth + gap
        let width = symbolWidth > 0 ? symbolX + symbolWidth : batteryX + batteryWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if let text = battery.percentageText {
                drawText(text, in: context)
            }
            context.saveGState()
            context.translateBy(x: batteryX, y: 0)
            drawBattery(battery, in: context)
            context.restoreGState()
            if let name = battery.attentionSymbol, let symbol = attentionImage(named: name) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: symbolX, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The percentage, its capitals centred on the battery, on a whole-point
    /// baseline.
    static func drawText(_ text: String, in context: CGContext) {
        let baseline = (body.midY - percentageFont.capHeight / 2).rounded()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(line(text), context)
    }

    static func drawBattery(_ battery: MenuBarBattery, in context: CGContext) {
        context.setFillColor(.black)
        context.setStrokeColor(.black)

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
        context.saveGState()
        context.addPath(glyph)
        context.clip()
        context.setBlendMode(.clear)
        context.fill(filled)
        context.setBlendMode(.normal)
        context.fill(empty)
        context.restoreGState()
    }

    /// The bolt or the plug, drawn for CellKeeper, inside the fill's area.
    static func glyphPath(_ glyph: MenuBarBattery.Glyph, centre c: CGPoint) -> CGPath? {
        switch glyph {
        case .none:
            return nil
        case .bolt:
            // 6 × 8 points, the fill's height: a top stroke down to the
            // left, a step to the right, a bottom stroke down to the left,
            // and back up the other side.
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
