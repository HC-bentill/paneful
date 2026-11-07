import AppKit

/// What letting go of a dragged tab would do.
enum TabDragIntent: Equatable {
    /// Dragging sideways. `moved` is false while the tab is still over its own slot.
    case reorder(moved: Bool)
    /// Pulled far enough up or down out of the bar: letting go makes it a separate window again.
    case pullOut

    var message: String {
        switch self {
        case .reorder(moved: false): "Drag sideways to reorder, or down to pull out"
        case .reorder(moved: true): "Release to move the tab here"
        case .pullOut: "Release to pull out of the group"
        }
    }

    /// "Release to…" states use the accent colour, like "Release to add as a tab".
    var isReady: Bool { self != .reorder(moved: false) }
}

/// The pill shown under a tab bar while a tab is dragged, saying what letting go will do.
/// It matches the "Hold / Release to add as a tab" badge of the drag-to-tab preview.
@MainActor
final class TabDragHint {
    static let shared = TabDragHint()

    private static let height: CGFloat = 26
    private let panel: NSPanel
    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")
    private var intent: TabDragIntent?
    /// The tab bar showing the hint, so another bar hiding doesn't take it away.
    private var owner: ObjectIdentifier?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.height),
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

        pill.wantsLayer = true
        pill.layer?.cornerRadius = Self.height / 2
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        panel.contentView = pill
    }

    /// Shows the hint just under the tab bar (`barFrame`, Cocoa coordinates), centred on the cursor, and
    /// under the cursor itself once it has left the bar.
    func show(_ newIntent: TabDragIntent, owner newOwner: ObjectIdentifier, barFrame: CGRect, mouse: CGPoint) {
        owner = newOwner
        if newIntent != intent {
            intent = newIntent
            label.stringValue = newIntent.message
            pill.layer?.backgroundColor = newIntent.isReady
                ? NSColor.controlAccentColor.cgColor
                : NSColor.black.withAlphaComponent(0.6).cgColor
        }
        let width = ceil(label.intrinsicContentSize.width) + 24
        let top = min(barFrame.minY - 6, mouse.y - 22)
        var frame = CGRect(x: mouse.x - width / 2, y: top - Self.height, width: width, height: Self.height)
        if let screen = Geometry.screen(containingCocoa: mouse) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - width - 4)
            frame.origin.y = max(frame.minY, visible.minY + 4)
        }
        if !panel.frame.isClose(to: frame, tolerance: 0.5) {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide(owner hidingOwner: ObjectIdentifier) {
        guard owner == hidingOwner else { return }
        owner = nil
        intent = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}
