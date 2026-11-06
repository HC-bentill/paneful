import AppKit

/// Converts between Cocoa coordinates (origin bottom-left of the primary screen, y up)
/// and AX / CoreGraphics coordinates (origin top-left of the primary screen, y down).
@MainActor
enum Geometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func axPoint(fromCocoa point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func screen(containingCocoa point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// The screen that shows most of an AX-space rect.
    static func screen(forAX rect: CGRect) -> NSScreen? {
        let cocoa = toCocoa(rect)
        return NSScreen.screens.max { a, b in
            a.frame.intersection(cocoa).area < b.frame.intersection(cocoa).area
        } ?? NSScreen.main
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
