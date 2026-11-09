import CoreGraphics
import Foundation

/// A saved arrangement of windows (Saved layouts: ⌃⌥⇧1…9 saves, ⌃⌥1…9 restores).
struct SavedLayout: Codable, Equatable {
    struct Window: Codable, Equatable {
        var bundleID: String
        var appName: String
        /// The window's title when it was saved, to tell an app's windows apart.
        var title: String?
    }

    struct Item: Codable, Equatable {
        /// One window, or a tab group's tabs in tab order.
        var windows: [Window]
        /// The window's frame, or the tab group's content frame (below its tab bar). AX coordinates.
        var frame: CGRect
        /// Visible frame of the display it was on, to fit it onto another display later. AX coordinates.
        var screen: CGRect
        /// The tab group's visible tab.
        var activeTab: Int = 0

        var isGroup: Bool { windows.count > 1 }
    }

    var number: Int
    var savedAt: Date
    /// Front to back.
    var items: [Item]

    var windowCount: Int { items.reduce(0) { $0 + $1.windows.count } }

    /// "Safari, Xcode, Terminal +2": the apps in it, front-most first.
    var summary: String {
        var names: [String] = []
        for window in items.flatMap(\.windows) where !names.contains(window.appName) {
            names.append(window.appName)
        }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }
}

/// Pairs the windows of a saved layout with the windows that are open now.
enum LayoutMatcher {
    struct Window {
        var bundleID: String
        var title: String?
        var frame: CGRect?
    }

    /// For each saved window, the index of the open window that takes its place, or nil when there's none.
    /// Only windows of the same app pair up: first those with the same title, then a similar title (one
    /// contains the other), then the open window nearest to where the saved one was. Each open window is
    /// used once.
    static func match(saved: [Window], open: [Window]) -> [Int?] {
        var result = [Int?](repeating: nil, count: saved.count)
        var used = Set<Int>()

        func pair(where fits: (Window, Window) -> Bool) {
            for (i, want) in saved.enumerated() where result[i] == nil {
                guard let j = open.indices.first(where: { j in
                    !used.contains(j) && open[j].bundleID == want.bundleID && fits(want, open[j])
                }) else { continue }
                result[i] = j
                used.insert(j)
            }
        }

        pair { a, b in
            guard let x = normalized(a.title) else { return false }
            return x == normalized(b.title)
        }
        pair { a, b in
            guard let x = a.title, let y = b.title else { return false }
            return WindowSignature.titlesMatch(x, y)
        }
        // Titles that changed (browsers show the current page): the nearest window of the same app.
        for (i, want) in saved.enumerated() where result[i] == nil {
            let candidates = open.indices.filter { !used.contains($0) && open[$0].bundleID == want.bundleID }
            guard let j = candidates.min(by: { distance(want.frame, open[$0].frame) < distance(want.frame, open[$1].frame) })
            else { continue }
            result[i] = j
            used.insert(j)
        }
        return result
    }

    private static func normalized(_ title: String?) -> String? {
        guard let text = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func distance(_ a: CGRect?, _ b: CGRect?) -> CGFloat {
        guard let a, let b else { return .greatestFiniteMagnitude }
        return hypot(a.midX - b.midX, a.midY - b.midY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

/// Fits saved frames onto the displays connected now.
enum LayoutGeometry {
    /// Where a frame saved on a display whose visible frame was `savedScreen` goes now, given the visible frames
    /// of today's displays (all AX coordinates). On the same display it goes exactly where it was. If that
    /// display is gone or its size changed, the frame keeps its relative place and size on the display that
    /// overlaps the saved one most (or the first display), and is kept on screen.
    static func place(_ frame: CGRect, savedScreen: CGRect, screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        if screens.contains(where: { $0.isClose(to: savedScreen, tolerance: 2) }) { return frame }
        guard savedScreen.width > 0, savedScreen.height > 0 else { return clamp(frame, to: screens[0]) }

        let overlapping = screens.max { $0.intersection(savedScreen).area < $1.intersection(savedScreen).area }
        let target = overlapping.flatMap { $0.intersection(savedScreen).area > 0 ? $0 : nil } ?? screens[0]
        let sx = target.width / savedScreen.width
        let sy = target.height / savedScreen.height
        let mapped = CGRect(x: (target.minX + (frame.minX - savedScreen.minX) * sx).rounded(),
                            y: (target.minY + (frame.minY - savedScreen.minY) * sy).rounded(),
                            width: (frame.width * sx).rounded(),
                            height: (frame.height * sy).rounded())
        return clamp(mapped, to: target)
    }

    /// Moves (and if needed shrinks) a frame so it lies inside `screen`.
    static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}
