import AppKit

/// A short message in the lower part of the screen ("Layout 1 saved"), gone after a moment.
@MainActor
final class Toast {
    static let shared = Toast()

    private let panel: NSPanel
    private let stack: NSStackView
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// Bumped by every message, so an older message's fade-out doesn't hide a newer one.
    private var generation = 0

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor.white.withAlphaComponent(0.75)
        detail.alignment = .center

        stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    /// Shows `text` (and a smaller `detail` line) on the screen with the mouse for about two seconds.
    func show(_ text: String, detail detailText: String? = nil) {
        title.stringValue = text
        detail.stringValue = detailText ?? ""
        detail.isHidden = detailText == nil

        let size = stack.fittingSize
        let visible = (Geometry.screen(containingCocoa: NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(size.width, 220), visible.width - 40)
        let frame = CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.minY + visible.height * 0.18).rounded(),
                           width: width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        generation += 1
        let shown = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard self.generation == shown else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self.generation == shown { self.panel.orderOut(nil) }
                }
            })
        }
    }
}
