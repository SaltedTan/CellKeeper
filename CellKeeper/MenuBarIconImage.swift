import AppKit
import CellKeeperKit

/// The Battery style's image (D113): a template image CellKeeper draws
/// itself (``MenuBarBatteryDrawing``, Kit, where its pixels are tested), so
/// the menu bar gives it the colour of its light, dark or tinted appearance
/// as it does its own icons. It holds, from left to right, the percentage,
/// a rounded battery with a terminal nub whose fill follows the charge, and
/// a symbol for a state that needs attention, each shown only when
/// ``MenuBarBattery`` has it. Everything is drawn into the one image, so the
/// status item keeps a single element with the app's VoiceOver label, as
/// before.
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
        let image = BatteryImage.image(for: battery)
        cache[battery] = image
        return image
    }
}

/// The image, outside the main actor: AppKit may call an image's drawing
/// handler on whatever thread draws the image, so the handler uses only the
/// values it captures and what it makes itself.
private enum BatteryImage {
    /// The menu bar's font with digits of equal width, so the percentage
    /// does not change width as the charge changes (only with the number of
    /// digits).
    static var percentageFont: CTFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular) as CTFont
    }

    static func attentionImage(named name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular))
    }

    static func image(for battery: MenuBarBattery) -> NSImage {
        let textWidth = battery.percentageText.map { MenuBarBatteryDrawing.width(of: MenuBarBatteryDrawing.line($0, font: percentageFont)) } ?? 0
        let symbolWidth = battery.attentionSymbol.flatMap(attentionImage(named:))?.size.width ?? 0
        let layout = MenuBarBatteryDrawing.layout(textWidth: textWidth, symbolWidth: symbolWidth)
        let image = NSImage(size: layout.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            MenuBarBatteryDrawing.draw(battery, font: percentageFont, layout: layout, in: context)
            if let symbolX = layout.symbolX, let name = battery.attentionSymbol, let symbol = attentionImage(named: name) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: symbolX, y: ((layout.size.height - size.height) / 2).rounded(), width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
