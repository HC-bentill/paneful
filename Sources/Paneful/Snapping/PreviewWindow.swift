import AppKit

/// The translucent, blurred rectangle shown while dragging, marking where the window will land.
@MainActor
final class PreviewWindow {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 2
        effect.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        panel.contentView = effect
    }

    /// Shows (or animates) the preview to a rect in Cocoa coordinates.
    func show(_ cocoaRect: CGRect) {
        let target = cocoaRect.insetBy(dx: 6, dy: 6)
        if !panel.isVisible {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else if !panel.frame.isClose(to: target, tolerance: 1) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
