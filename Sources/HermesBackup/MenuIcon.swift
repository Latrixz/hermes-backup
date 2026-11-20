import AppKit

/// The menu bar icon: Hermes' silhouette (Resources/MenuIcon.png, from scripts/make-menu-icon.swift)
/// with a status badge cut into its bottom-right corner. A template image, so macOS tints it
/// for light and dark menu bars.
@MainActor
enum MenuIcon {
    private static var cache: [AppModel.Health: NSImage] = [:]

    static func image(for health: AppModel.Health) -> NSImage {
        if let hit = cache[health] { return hit }
        let made = draw(badge: badge(for: health))
        cache[health] = made
        return made
    }

    private static func badge(for health: AppModel.Health) -> String {
        switch health {
        case .good: return "clock.arrow.circlepath"
        case .busy: return "arrow.triangle.2.circlepath"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    private static func draw(badge: String) -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: false) { rect in
            if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
               let base = NSImage(contentsOf: url) {
                base.draw(in: rect)
            } else if let fallback = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil) {
                fallback.draw(in: rect)   // `swift run` has no app bundle
            }
            let d = rect.width * 0.46
            let spot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            let ctx = NSGraphicsContext.current
            ctx?.compositingOperation = .clear
            NSBezierPath(ovalIn: spot.insetBy(dx: -rect.width * 0.05, dy: -rect.width * 0.05)).fill()
            ctx?.compositingOperation = .sourceOver
            let config = NSImage.SymbolConfiguration(pointSize: d * 0.92, weight: .bold)
            if let symbol = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: spot.midX - s.width / 2, y: spot.midY - s.height / 2,
                                       width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hermes Backup"
        return image
    }
}
