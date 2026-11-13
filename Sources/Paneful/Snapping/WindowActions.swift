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
        // macOS doesn't let anyone move a window that's in its own full screen: say so instead of doing nothing.
        guard !window.isFullScreen else { NSSound.beep(); return }
        AutoTiler.shared.release(window)   // snapped somewhere on purpose: it floats now
        WindowMover.move(window, toCocoa: zone.rect(in: screen.visibleFrame))
    }

    /// Places the current window on the left half and the previously focused window on the right half.
    static func sideBySide() {
        guard let window = currentWindow,
              let other = FocusTracker.shared.previous(excluding: window),
              let frame = window.frame,
              let screen = Geometry.screen(forAX: frame),
              !window.isFullScreen, !other.isFullScreen else { NSSound.beep(); return }
        let visible = screen.visibleFrame
        AutoTiler.shared.release(window)
        AutoTiler.shared.release(other)
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

    /// Minimizes the focused window's whole tab group (or just the window when it isn't grouped).
    static func minimizeGroup() {
        guard let window = currentWindow else { NSSound.beep(); return }
        if let group = TabGroupManager.shared.group(containing: window) {
            TabGroupManager.shared.minimize(group)
        } else {
            window.setMinimized(true)
        }
    }

    static func removeFromGroup() {
        guard let window = currentWindow else { return }
        TabGroupManager.shared.remove(window)
    }

    static func ungroupAll() { TabGroupManager.shared.ungroupAll() }

    /// ⌃⌥F: takes the focused window out of the auto-tiling layout, or puts it in.
    static func toggleTiling() {
        guard let window = currentWindow else { NSSound.beep(); return }
        AutoTiler.shared.toggle(window)
    }
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

    /// The current window, then earlier ones, most recent first, leaving out `window`.
    func recent(excluding window: AXWindow?) -> [AXWindow] {
        ([current].compactMap { $0 } + history).filter { $0 != window }
    }

    /// Most recent other window that still exists and isn't minimized.
    func previous(excluding window: AXWindow) -> AXWindow? {
        history.removeAll { $0.frame == nil }
        return history.first { $0 != window && !$0.isMinimized }
    }
}
