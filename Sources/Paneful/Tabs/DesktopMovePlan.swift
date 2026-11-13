import Foundation

/// The decisions behind moving a tab group to another desktop. Pure, so they can be tested.
enum DesktopMovePlan {
    /// Where a group's tab bar is, compared with its windows.
    enum BarCheck: Equatable {
        /// Bar and windows are on the same desktop.
        case together
        /// The windows are on another desktop, and the bar hasn't moved: the visible tab was moved, and the
        /// bar follows it as usual.
        case windowsMoved
        /// The bar itself was moved to another desktop (dragged there in Mission Control): the group follows it.
        case barMoved(to: UInt64)
    }

    /// `lastBarSpace` is the desktop the bar was last seen on together with its windows.
    static func barCheck(barSpace: UInt64, lastBarSpace: UInt64?, home: UInt64) -> BarCheck {
        if barSpace == home { return .together }
        // A bar that was never seen with its windows (just made) can't have been dragged anywhere.
        guard let lastBarSpace, lastBarSpace != barSpace else { return .windowsMoved }
        return .barMoved(to: barSpace)
    }

    /// Why a group can't be moved to the desktop its bar was dragged to.
    enum Problem: Equatable {
        case desktopGone
        case fullScreenSpace
        case otherDisplay

        var message: String {
            switch self {
            case .desktopGone: "That desktop isn't there anymore."
            case .fullScreenSpace: "A full-screen app's space can't hold a tab group."
            case .otherDisplay: "Paneful can only move a group between desktops of the same display. Drag one of its windows to the other display instead."
            }
        }
    }

    enum Decision: Equatable {
        case carry
        case impossible(Problem)
    }

    /// Whether the windows on desktop `home` can be carried to desktop `target` (by dragging them there in
    /// Mission Control, which shows one display's desktops in its top row).
    static func decide(home: UInt64, target: UInt64, layout: DesktopLayout) -> Decision {
        guard let space = layout.space(target) else { return .impossible(.desktopGone) }
        guard space.isDesktop else { return .impossible(.fullScreenSpace) }
        guard layout.steps(from: home, to: target) != nil else { return .impossible(.otherDisplay) }
        return .carry
    }

    /// The window the user moved away from the group's desktop, if any: it was on `home` last time and is on
    /// another desktop now. (Windows Paneful left behind on another desktop were never on `home` since.)
    static func movedAway<W: Hashable>(_ windows: [W], before: [W: UInt64], now: [W: UInt64], home: UInt64?) -> W? {
        guard let home else { return nil }
        return windows.first { window in
            guard let space = now[window] else { return false }
            return before[window] == home && space != home
        }
    }

    /// The order windows are carried in: the visible tab last, so it ends up in front on the new desktop.
    static func carryOrder<T: Equatable>(_ items: [T], active: T?) -> [T] {
        items.filter { $0 != active } + items.filter { $0 == active }
    }
}
