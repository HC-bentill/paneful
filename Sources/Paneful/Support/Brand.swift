import AppKit

/// Paneful's "Snap Grid" brand mark. Sources of truth live in Resources/Logo (see CLAUDE.md → Brand).
@MainActor
enum Brand {
    /// The menu-bar glyph as a template image: the bundled MenuBarIcon.png, or the same shapes drawn in code
    /// when Paneful runs without its app bundle (`swift run`).
    static func menuBarIcon() -> NSImage {
        let image = NSImage(named: "MenuBarIcon") ?? drawnMenuBarIcon()
        image.isTemplate = true
        image.accessibilityDescription = "Paneful"
        return image
    }

    /// Mirrors Resources/Logo/MenuBarIcon.svg (24-unit view box drawn at 18 pt): a tall left pane filled at 35%
    /// and two outlined squares on the right.
    private static func drawnMenuBarIcon() -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let scale: CGFloat = 18 / 24
            func pane(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
                let path = NSBezierPath(roundedRect: NSRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale),
                                        xRadius: 1.6 * scale, yRadius: 1.6 * scale)
                path.lineWidth = 1.8 * scale
                return path
            }
            let left = pane(3, 3, 8, 18)
            NSColor.black.withAlphaComponent(0.35).setFill()
            left.fill()
            NSColor.black.setStroke()
            left.stroke()
            pane(13, 3, 8, 8).stroke()
            pane(13, 13, 8, 8).stroke()
            return true
        }
    }
}
