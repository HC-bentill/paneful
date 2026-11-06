import AppKit

/// The translucent, blurred rectangle shown while dragging, marking where the window will land.
@MainActor
final class PreviewWindow {
    enum Style: Equatable {
        /// Releasing snaps the window into this rect.
        case snap
        /// Over a tab drop zone, waiting for the short hold that confirms it.
        case tabHold
        /// Releasing adds the window to this group as a tab.
        case tabReady
    }

    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let badge = NSView()
    private let label = NSTextField(labelWithString: "")
    private var style: Style?

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

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 2
        panel.contentView = effect

        // "Hold / Release to add as a tab" pill, shown for tab drop zones only.
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 13
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        effect.addSubview(badge)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 26),
            badge.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            badge.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
        ])
    }

    /// Shows (or animates) the preview to a rect in Cocoa coordinates.
    func show(_ cocoaRect: CGRect, style: Style = .snap) {
        apply(style)
        let target = cocoaRect.insetBy(dx: 6, dy: 6)
        if !panel.isVisible {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else if !panel.frame.isClose(to: target, tolerance: 1) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        style = nil
    }

    private func apply(_ newStyle: Style) {
        guard newStyle != style else { return }
        style = newStyle
        let accent = NSColor.controlAccentColor
        switch newStyle {
        case .snap:
            badge.isHidden = true
            effect.layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
            effect.layer?.backgroundColor = nil
        case .tabHold:
            badge.isHidden = false
            label.stringValue = "Hold to add as a tab"
            badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            effect.layer?.borderColor = accent.withAlphaComponent(0.45).cgColor
            effect.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        case .tabReady:
            badge.isHidden = false
            label.stringValue = "Release to add as a tab"
            badge.layer?.backgroundColor = accent.cgColor
            effect.layer?.borderColor = accent.cgColor
            effect.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        }
    }
}
