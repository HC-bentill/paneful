import AppKit
import ApplicationServices

/// A window as the window server sees it (CGWindowList). Bounds are in AX/CG coordinates
/// (origin top-left of the primary screen, y down). Cheap to query, and it doesn't depend on how
/// quickly the owning app answers Accessibility requests.
struct ScreenWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let layer: Int
}

/// Finds windows on screen: the focused one, the one under the cursor, the one beneath a dragged window.
@MainActor
enum WindowQuery {
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// The focused window of the frontmost app (ignoring Paneful itself).
    static func focusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID else { return nil }
        return AXWindow.focused(inApp: app.processIdentifier)
    }

    /// Every on-screen window on the current Space, front to back (Paneful's own windows included).
    static func onScreenWindows() -> [ScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap(screenWindow(from:))
    }

    /// IDs of every normal (layer 0) window, on any Space, minimized or not.
    static func allWindowIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids = Set<CGWindowID>()
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0 else { continue }
            ids.insert(number.uint32Value)
        }
        return ids
    }

    /// Current bounds of one window, or nil when it's gone or not on screen.
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = info.first else { return nil }
        return screenWindow(from: entry)?.bounds
    }

    /// The normal (layer 0) window at a point, front-most first.
    /// - `excluding`: windows to look through (e.g. the window being dragged).
    /// - `blockedByOwn`: if one of Paneful's own windows (a tab bar) is on top at that point, return nil.
    static func topWindow(atAX point: CGPoint, excluding: Set<CGWindowID> = [],
                          blockedByOwn: Bool = true) -> ScreenWindow? {
        for window in onScreenWindows() where window.layer == 0 && window.bounds.contains(point) {
            if excluding.contains(window.id) { continue }
            if window.pid == ownPID {
                if blockedByOwn { return nil }
                continue
            }
            return window
        }
        return nil
    }

    /// The Accessibility element for a window-server window.
    static func axWindow(for window: ScreenWindow) -> AXWindow? {
        let candidates = AXWindow.windows(ofApp: window.pid)
        return candidates.first { $0.windowID == window.id }
            ?? candidates.first { $0.frame?.isClose(to: window.bounds) == true }
    }

    private static func screenWindow(from entry: [String: Any]) -> ScreenWindow? {
        guard let number = entry[kCGWindowNumber as String] as? NSNumber,
              let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        if let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { return nil }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return ScreenWindow(id: number.uint32Value, pid: pid.int32Value, bounds: bounds, layer: layer)
    }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// Same place, roughly the same size. Apps with size increments (e.g. Terminal) or minimum sizes
    /// never match a requested size exactly, so the size gets more slack than the position.
    func isRoughly(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= 2 && abs(minY - other.minY) <= 2 &&
        abs(width - other.width) <= 24 && abs(height - other.height) <= 24
    }
}
