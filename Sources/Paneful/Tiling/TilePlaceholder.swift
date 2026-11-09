import AppKit

/// Dark tiles with an app's icon and name that hold a slot in the auto-tiling layout: while an app is still
/// launching, and for a moment while a new window moves into its tile (so the jump isn't seen).
@MainActor
final class TilePlaceholders {
    @MainActor
    private final class Placeholder {
        let panel: NSPanel
        let icon = NSImageView()
        let name = NSTextField(labelWithString: "")
        let status = NSTextField(labelWithString: "")
        /// Bumped every time it's shown, so a fade started earlier can't hide it again.
        var generation = 0

        init() {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 12
            tile.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
            tile.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
            tile.layer?.borderWidth = 1

            icon.imageScaling = .scaleProportionallyUpOrDown
            name.font = .systemFont(ofSize: 15, weight: .semibold)
            name.textColor = .white
            name.lineBreakMode = .byTruncatingTail
            status.font = .systemFont(ofSize: 12)
            status.textColor = NSColor(white: 1, alpha: 0.55)
            let stack = NSStackView(views: [icon, name, status])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(stack)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 64),
                icon.heightAnchor.constraint(equalToConstant: 64),
                stack.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualTo: tile.widthAnchor, constant: -24),
            ])
            panel.contentView = tile
        }
    }

    private var shown: [TileItem: Placeholder] = [:]

    /// Shows (or moves) the placeholder for `key` over a tile (AX coordinates) until `hide` is called.
    func show(_ key: TileItem, frame: CGRect, app: NSRunningApplication?, title: String?, status: String) {
        let placeholder = shown[key] ?? Placeholder()
        shown[key] = placeholder
        placeholder.generation += 1
        placeholder.icon.image = app?.icon
        placeholder.name.stringValue = title.flatMap { $0.isEmpty ? nil : $0 } ?? app?.localizedName ?? "Window"
        placeholder.status.stringValue = status
        let cocoa = Geometry.toCocoa(frame).insetBy(dx: 4, dy: 4)
        if !placeholder.panel.frame.isClose(to: cocoa, tolerance: 0.5) {
            placeholder.panel.setFrame(cocoa, display: true)
        }
        placeholder.panel.alphaValue = 1
        if !placeholder.panel.isVisible { placeholder.panel.orderFrontRegardless() }
    }

    /// Shows the placeholder briefly while a window moves into its tile, then fades it out.
    func flash(_ key: TileItem, frame: CGRect, app: NSRunningApplication?, title: String?) {
        show(key, frame: frame, app: app, title: title, status: "")
        hide(key, after: 0.55)
    }

    func hide(_ key: TileItem, after delay: TimeInterval = 0) {
        guard let placeholder = shown[key] else { return }
        let generation = placeholder.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard placeholder.generation == generation else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    placeholder.panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard let self, placeholder.generation == generation else { return }
                        placeholder.panel.orderOut(nil)
                        self.shown = self.shown.filter { $0.value !== placeholder }
                    }
                })
            }
        }
    }

    func hideAll() {
        for (_, placeholder) in shown {
            placeholder.generation += 1
            placeholder.panel.orderOut(nil)
        }
        shown.removeAll()
    }

    /// Placeholders still on screen (or fading), so the tiler can drop ones whose tile is gone.
    var keys: [TileItem] { Array(shown.keys) }
}
