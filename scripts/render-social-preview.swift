// Renders Resources/Logo/SocialPreview.png (1280×640), the GitHub social preview card.
// Usage: swift scripts/render-social-preview.swift
// The mark mirrors Resources/Logo/AppIcon.svg (design space 0…100), drawn white on the brand gradient.
import AppKit

let width = 1280, height = 640
let orange = NSColor(srgbRed: 1, green: 0x8A / 255, blue: 0x4C / 255, alpha: 1)   // #FF8A4C
let pink = NSColor(srgbRed: 1, green: 0x4D / 255, blue: 0x6D / 255, alpha: 1)     // #FF4D6D

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
// Draw in a top-left (SVG-like) coordinate system.
context.cgContext.translateBy(x: 0, y: CGFloat(height))
context.cgContext.scaleBy(x: 1, y: -1)

let canvas = NSRect(x: 0, y: 0, width: width, height: height)
// The context is flipped, so angle 90 runs top → bottom: orange at the top, pink at the bottom (as in the icon).
NSGradient(starting: orange, ending: pink)!.draw(in: canvas, angle: 90)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height / 2), angle: 90)    // soft sheen, fading downward

// The Snap Grid mark, 300 pt tall, vertically centred on the left.
let markSize: CGFloat = 300
let markOrigin = CGPoint(x: 130, y: (CGFloat(height) - markSize) / 2)
func pane(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    let s = markSize / 64   // panes span 18…82 of the 0…100 design space → 64 units
    let rect = NSRect(x: markOrigin.x + (x - 18) * s, y: markOrigin.y + (y - 18) * s, width: w * s, height: h * s)
    return NSBezierPath(roundedRect: rect, xRadius: 7 * s, yRadius: 7 * s)
}
NSColor.white.withAlphaComponent(0.35).setFill()
pane(52, 18, 30, 30).fill()
pane(52, 52, 30, 30).fill()
let shadow = NSShadow()
shadow.shadowColor = NSColor(srgbRed: 0xB0 / 255, green: 0x21 / 255, blue: 0x3F / 255, alpha: 0.35)
shadow.shadowOffset = NSSize(width: 0, height: 6)
shadow.shadowBlurRadius = 14
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
pane(18, 18, 30, 64).fill()
NSGraphicsContext.restoreGraphicsState()
// ↗ snap arrow in the bottom-right pane: M62 67 l7 -7, then v6 and h-6 from the tip.
let s = markSize / 64
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: markOrigin.x + (x - 18) * s, y: markOrigin.y + (y - 18) * s) }
let arrow = NSBezierPath()
arrow.move(to: p(62, 67)); arrow.line(to: p(69, 60))
arrow.move(to: p(69, 66)); arrow.line(to: p(69, 60)); arrow.line(to: p(63, 60))
arrow.lineWidth = 4 * s
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.white.setStroke()
arrow.stroke()

// Wordmark.
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    // Text draws upright only in an unflipped context, so flip back locally around the baseline.
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext.current!.cgContext
    cg.translateBy(x: point.x, y: point.y)
    cg.scaleBy(x: 1, y: -1)
    NSAttributedString(string: text, attributes: attributes).draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
}
let textX: CGFloat = 520
draw("Paneful", size: 112, weight: .bold, alpha: 1, at: CGPoint(x: textX, y: 308))
draw("Desktop Manager", size: 52, weight: .semibold, alpha: 0.92, at: CGPoint(x: textX + 4, y: 378))
draw("Snap windows. Tab any apps together.", size: 30, weight: .medium, alpha: 0.88, at: CGPoint(x: textX + 4, y: 446))
draw("Free & open source for macOS", size: 30, weight: .medium, alpha: 0.88, at: CGPoint(x: textX + 4, y: 488))

NSGraphicsContext.restoreGraphicsState()
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Resources/Logo/SocialPreview.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
