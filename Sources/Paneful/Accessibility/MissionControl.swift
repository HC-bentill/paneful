import AppKit
import ApplicationServices

/// Mission Control, as Accessibility describes it.
///
/// Checked on macOS 27.2: Mission Control belongs to WindowManager (on older macOS it belonged to the Dock).
/// Per display there's an `mc.display` group holding a button per window picture, and a top row
/// (`mc.spaces.list`) holding a button per desktop and full-screen app, in Mission Control's order ("Desktop 1",
/// "Desktop 2"…, action "Exit to Desktop N"). While Mission Control is open, CGWindowList reports each window at
/// the place and size of its picture, so a window's picture is found from its window number.
///
/// There's no "move to desktop" action: a window is moved by dragging its picture onto a desktop in the top row,
/// as a person does (see `DesktopMover`).
@MainActor
enum MissionControl {
    struct Button {
        let element: AXUIElement
        let title: String
        let frame: CGRect
    }

    struct Display {
        let frame: CGRect
        /// The top row: desktops and full-screen apps, left to right.
        let spaces: [Button]
    }

    private static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    static var isShowing: Bool { Spaces.missionControlIsShowing() }

    /// Opens Mission Control (as F3 does). Returns once it's up and its top row can be read.
    static func open() async -> Bool {
        if isShowing, !displays().isEmpty { return true }
        NSWorkspace.shared.open(appURL)
        for _ in 0..<50 {   // 2.5 s
            try? await Task.sleep(for: .milliseconds(50))
            if isShowing, !displays().isEmpty {
                try? await Task.sleep(for: .milliseconds(300))   // the pictures glide into place
                return true
            }
        }
        Log.tabs.error("Mission Control didn't open (or its top row can't be read)")
        return false
    }

    /// Leaves Mission Control onto desktop `space`, as clicking it in the top row does (when it's the desktop
    /// already on screen, that just closes Mission Control). True once it's closed and `space` shows.
    static func leave(to space: UInt64) async -> Bool {
        if let button = button(for: space, in: Spaces.layout()) {
            AXUIElementPerformAction(button.element, kAXPressAction as CFString)
        } else {
            Log.tabs.error("Mission Control: no button for desktop \(space, privacy: .public), pressing Esc")
            pressEscape()
        }
        for _ in 0..<50 {   // 2.5 s
            try? await Task.sleep(for: .milliseconds(50))
            if !isShowing, Spaces.layout().current(onDisplayOf: space) == space {
                try? await Task.sleep(for: .milliseconds(250))   // the closing slide ends
                return true
            }
        }
        return !isShowing && Spaces.layout().current(onDisplayOf: space) == space
    }

    /// The top-row button of a desktop (or full-screen app), found by its place in Mission Control's order,
    /// else by its name.
    static func button(for space: UInt64, in layout: DesktopLayout) -> Button? {
        guard let d = layout.displayIndex(of: space),
              let index = layout.displays[d].spaces.firstIndex(where: { $0.id == space }) else { return nil }
        let shown = displays()
        let count = layout.displays[d].spaces.count
        if let row = MissionControlGeometry.displayRow(frames: shown.map(\.frame), counts: shown.map(\.spaces.count),
                                                       bounds: displayBounds(layout.displays[d].id),
                                                       spaceCount: count) {
            return shown[row].spaces[index]
        }
        let title = layout.desktopNumber(of: space).map { "Desktop \($0)" }
        return shown.flatMap(\.spaces).first { $0.title == title }
    }

    /// Every display Mission Control shows, with its top row.
    static func displays() -> [Display] {
        for root in roots() {
            let groups = descendants(of: root, withID: "mc.display", depth: 3)
            guard !groups.isEmpty else { continue }
            return groups.compactMap { group in
                guard let frame = frame(of: group) else { return nil }
                let list = descendants(of: group, withID: "mc.spaces.list", depth: 3).first
                let buttons = (list.flatMap { value($0, kAXChildrenAttribute) as? [AXUIElement] } ?? [])
                    .compactMap { button -> Button? in
                        guard let frame = self.frame(of: button) else { return nil }
                        return Button(element: button, title: value(button, kAXTitleAttribute) as? String ?? "",
                                      frame: frame)
                    }
                return Display(frame: frame, spaces: buttons)
            }
        }
        return []
    }

    /// True when the topmost thing Accessibility finds at `point` is a picture the size of `picture`.
    static func picture(_ picture: CGRect, isAt point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit, let frame = frame(of: hit) else { return false }
        return frame.isClose(to: picture, tolerance: 6)
    }

    // MARK: Accessibility

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }()

    /// WindowManager on macOS 27, the Dock before.
    private static func roots() -> [AXUIElement] {
        ["com.apple.WindowManager", "com.apple.dock"].compactMap { bundle in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?
                .processIdentifier else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            return app
        }
    }

    private static func descendants(of element: AXUIElement, withID id: String, depth: Int) -> [AXUIElement] {
        guard depth > 0, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children.flatMap { child -> [AXUIElement] in
            value(child, "AXIdentifier") as? String == id ? [child] : descendants(of: child, withID: id, depth: depth - 1)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXWindow.value(of: element, attribute)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// The bounds (AX coordinates) of the display CGSCopyManagedDisplaySpaces names `identifier` (a UUID, or
    /// "Main" when all displays share one set of desktops).
    private static func displayBounds(_ identifier: String) -> CGRect? {
        if identifier == "Main" { return CGDisplayBounds(CGMainDisplayID()) }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { continue }
            if text.caseInsensitiveCompare(identifier) == .orderedSame { return CGDisplayBounds(id) }
        }
        return nil
    }

    private static func pressEscape() {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: DesktopMover.eventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// The geometry of dragging in Mission Control. Pure, so it can be tested.
enum MissionControlGeometry {
    /// Where to let go of a window over a desktop in the top row, given the frame Accessibility reports for
    /// that desktop's button.
    ///
    /// Checked on macOS 27.2: once the top row has opened, the reported frame starts about where the desktop's
    /// picture ends (it seems shifted down), so the middle of the frame is below the picture, and a window let
    /// go there lands in a new full-screen space of its own. Letting go just inside the frame's top edge, a
    /// fifth to a third of the way across, works (by hand and by Paneful). `attempt` 1 tries the middle, a
    /// little lower.
    static func dropPoint(on frame: CGRect, attempt: Int) -> CGPoint {
        attempt == 0 ? CGPoint(x: frame.minX + frame.width * 0.3, y: frame.minY + 2)
                     : CGPoint(x: frame.midX, y: frame.minY + 12)
    }

    /// Where the dragged picture goes first: under the desktop, below the top row (the row opens as the drag
    /// comes up into it). Coming up from below never passes over the gaps between desktops.
    static func approachPoint(under frame: CGRect, display: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: min(max(frame.maxY, 140) + 110, display.maxY - 40))
    }

    /// Whether the top row is open (showing desktop pictures, not just names), from a desktop button's frame:
    /// closed, the buttons sit at the very top of the display (y ≈ 5 on macOS 27.2); open, about 100 pt lower.
    static func rowIsOpen(_ button: CGRect, display: CGRect) -> Bool {
        button.minY - display.minY > 40
    }

    /// Two reads of a picture (or a button) agree: it has stopped gliding.
    static func isSettled(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return a.isClose(to: b, tolerance: 1)
    }

    /// Which of Mission Control's displays (`frames`, each with `counts` top-row buttons) shows the desktops of
    /// the display at `bounds` that has `spaceCount` desktops and full-screen apps.
    static func displayRow(frames: [CGRect], counts: [Int], bounds: CGRect?, spaceCount: Int) -> Int? {
        let candidates: [Int]
        if frames.count == 1 {
            candidates = [0]
        } else if let bounds, let match = frames.firstIndex(where: { $0.isClose(to: bounds, tolerance: 2) }) {
            candidates = [match]
        } else {
            let sameCount = counts.indices.filter { counts[$0] == spaceCount }
            candidates = sameCount.count == 1 ? sameCount : []
        }
        // The top row must list exactly the display's spaces, or the place in it means nothing.
        return candidates.first { counts[$0] == spaceCount }
    }

    enum Drop: Equatable {
        case moved
        /// Still on its desktop (Mission Control didn't take it, or not yet).
        case stayed
        /// Mission Control made it a full-screen app in a new space of its own (it was let go between desktops).
        case fullScreen(UInt64)
        /// It landed on a desktop next to the one aimed at.
        case otherDesktop(UInt64)
        /// macOS doesn't say where it is right now.
        case unknown
    }

    /// Where a dropped window ended up: `space` is its desktop now.
    static func drop(space: UInt64?, source: UInt64, target: UInt64, layout: DesktopLayout) -> Drop {
        guard let space else { return .unknown }
        if space == target { return .moved }
        if space == source { return .stayed }
        if layout.space(space)?.isDesktop == true { return .otherDesktop(space) }
        return .fullScreen(space)
    }
}
