import AppKit

/// Moves a window, keeping tab groups intact (a grouped window moves its whole group).
@MainActor
enum WindowMover {
    static func move(_ window: AXWindow, toCocoa rect: CGRect) {
        let axRect = Geometry.toAX(rect)
        if let group = TabGroupManager.shared.group(containing: window) {
            TabGroupManager.shared.setOuterFrame(of: group, to: axRect)
        } else {
            FrameKeeper.shared.place(window, axRect)
        }
    }
}

/// User-facing commands, triggered by hotkeys or the menu-bar menu.
@MainActor
enum WindowActions {
    /// The window the user is working in. Falls back to the last tracked one when Paneful's
    /// own menu is open (which can briefly make Paneful frontmost).
    static var currentWindow: AXWindow? {
        WindowQuery.focusedWindow() ?? FocusTracker.shared.current
    }

    static func snap(_ zone: SnapZone) {
        guard let window = currentWindow, let frame = window.frame,
              let screen = Geometry.screen(forAX: frame) else { return }
        WindowMover.move(window, toCocoa: zone.rect(in: screen.visibleFrame))
    }

    /// Places the current window on the left half and the previously focused window on the right half.
    static func sideBySide() {
        guard let window = currentWindow,
              let other = FocusTracker.shared.previous(excluding: window),
              let frame = window.frame,
              let screen = Geometry.screen(forAX: frame) else { NSSound.beep(); return }
        let visible = screen.visibleFrame
        WindowMover.move(window, toCocoa: SnapZone.leftHalf.rect(in: visible))
        WindowMover.move(other, toCocoa: SnapZone.rightHalf.rect(in: visible))
        other.focus()
        window.focus()
    }

    /// Groups the current window with the previously focused window as tabs.
    static func tabWithPrevious() {
        guard let window = currentWindow,
              let other = FocusTracker.shared.previous(excluding: window) else { NSSound.beep(); return }
        TabGroupManager.shared.addToGroup(target: other, window: window)
    }

    static func nextTab() { TabGroupManager.shared.cycle(from: currentWindow, by: 1) }
    static func previousTab() { TabGroupManager.shared.cycle(from: currentWindow, by: -1) }

    static func removeFromGroup() {
        guard let window = currentWindow else { return }
        TabGroupManager.shared.remove(window)
    }

    static func ungroupAll() { TabGroupManager.shared.ungroupAll() }
}

/// Remembers the current and previously focused windows (used by "side by side" and "tab with previous").
@MainActor
final class FocusTracker {
    static let shared = FocusTracker()
    private(set) var current: AXWindow?
    private var history: [AXWindow] = []

    func update() {
        guard let focused = WindowQuery.focusedWindow(), focused.isStandardWindow else { return }
        guard focused != current else { return }
        if let current { history.removeAll { $0 == current }; history.insert(current, at: 0) }
        history.removeAll { $0 == focused }
        history = Array(history.prefix(10))
        current = focused
    }

    /// Most recent other window that still exists and isn't minimized.
    func previous(excluding window: AXWindow) -> AXWindow? {
        history.removeAll { $0.frame == nil }
        return history.first { $0 != window && !$0.isMinimized }
    }
}
