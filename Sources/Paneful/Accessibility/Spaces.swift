import AppKit
import CoreGraphics

// macOS has no public way to ask which desktop (Space) a window is on. These private SkyLight calls answer it.
// They need no permission and have been stable for over a decade: AltTab, Hammerspoon, yabai and Amethyst use
// the same ones.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ connection: Int32, _ windowIDs: CFArray, _ space: UInt64)

/// Which desktop (Space) windows are on.
///
/// What macOS reports (checked on macOS 27.2): a window on a desktop gives that desktop's ID. A minimized or
/// hidden window gives either nothing or the desktop it was last shown on, never some other desktop. So
/// "this window's desktop differs from its groupmates'" reliably means it was moved to another desktop.
enum Spaces {
    private static let connection = CGSMainConnectionID()
    /// Current, other and user Spaces.
    private static let allSpaces: Int32 = 7

    /// The desktop a window is on. `nil` when macOS doesn't say (minimized, hidden, closed), and for a window
    /// on several desktops (its app is assigned to All Desktops): it's with its group wherever that is.
    static func space(of windowID: CGWindowID) -> UInt64? {
        guard let list = CGSCopySpacesForWindows(connection, allSpaces, [windowID] as CFArray)?
            .takeRetainedValue() as? [NSNumber], list.count == 1 else { return nil }
        return list[0].uint64Value
    }

    /// The desktop a tab group lives on, given the desktops of its open windows: the one holding the most of
    /// them. On a tie, the visible tab's desktop wins (so the group stays put while its windows are moved over
    /// one by one), else the lowest ID (so the answer doesn't flip between ticks).
    static func home(of desktops: [UInt64], visibleTab: UInt64?) -> UInt64? {
        var counts: [UInt64: Int] = [:]
        for desktop in desktops { counts[desktop, default: 0] += 1 }
        guard let most = counts.values.max() else { return nil }
        let tied = counts.filter { $0.value == most }.map(\.key)
        if let visibleTab, tied.contains(visibleTab) { return visibleTab }
        return tied.min()
    }

    /// Every display's desktops, in Mission Control's order.
    static func layout() -> DesktopLayout {
        let raw = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        return DesktopLayout(raw: raw)
    }

    /// The desktops on screen right now: one per display (or one for all, when displays share Spaces).
    static func visible() -> Set<UInt64> {
        Set(layout().displays.compactMap(\.current))
    }

    /// Moves one of Paneful's OWN windows (a tab bar) to another desktop.
    ///
    /// Checked on macOS 27.2: this works for Paneful's own windows only. For another app's window macOS
    /// silently does nothing (and so do CGSAddWindowsToSpaces/CGSRemoveWindowsFromSpaces; the "compat ID"
    /// workaround fails with kCGErrorNotImplemented). Other apps' windows are moved by `DesktopMover`.
    static func moveOwnWindow(_ windowNumber: Int, to space: UInt64) {
        guard windowNumber > 0 else { return }
        CGSMoveWindowsToManagedSpace(connection, [windowNumber] as CFArray, space)
    }

    /// True while Mission Control (or App Exposé, Show Desktop) is on screen. The Dock then covers a whole
    /// display with a window of its own at the Dock's level; normally it has none that size. Paneful never
    /// sends clicks or keys while it's up.
    @MainActor
    static func missionControlIsShowing() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?
            .processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let displays = NSScreen.screens.map { Geometry.toAX($0.frame) }
        return info.contains { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dock,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 >= Int(CGWindowLevelForKey(.dockWindow)),
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return displays.contains { $0.isClose(to: bounds, tolerance: 2) }
        }
    }
}

/// The desktops (Spaces) of every display, as Mission Control shows them. Pure data, so it can be tested.
struct DesktopLayout: Equatable {
    struct Space: Equatable {
        let id: UInt64
        /// Stable across restarts (the numeric ID isn't: it changes when displays come and go).
        let uuid: String
        /// A normal desktop. False for a full-screen app's own Space.
        let isDesktop: Bool
    }

    struct Display: Equatable {
        let id: String
        let current: UInt64?
        let spaces: [Space]
    }

    let displays: [Display]

    init(displays: [Display]) {
        self.displays = displays
    }

    /// From CGSCopyManagedDisplaySpaces: one entry per display with "Display Identifier", "Current Space" and
    /// "Spaces" (each with "ManagedSpaceID", "uuid" and "type": 0 = desktop, 4 = full-screen app).
    init(raw: [[String: Any]]) {
        displays = raw.map { display in
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                return Space(id: id, uuid: space["uuid"] as? String ?? "",
                             isDesktop: (space["type"] as? NSNumber)?.intValue ?? 0 == 0)
            }
            return Display(id: display["Display Identifier"] as? String ?? "", current: current, spaces: spaces)
        }
    }

    func displayIndex(of space: UInt64) -> Int? {
        displays.firstIndex { $0.spaces.contains { $0.id == space } }
    }

    func space(_ id: UInt64) -> Space? {
        displays.lazy.flatMap(\.spaces).first { $0.id == id }
    }

    /// The desktop's number as in "Switch to Desktop N": desktops (not full-screen apps) counted 1, 2, 3…
    /// across displays in order.
    func desktopNumber(of space: UInt64) -> Int? {
        let desktops = displays.flatMap(\.spaces).filter(\.isDesktop)
        return desktops.firstIndex { $0.id == space }.map { $0 + 1 }
    }

    /// How many "Move right a space" presses (negative: "Move left") go from one Space to another. Those
    /// shortcuts step through every Space of a display, full-screen apps included. `nil` when the two aren't
    /// on the same display.
    func steps(from: UInt64, to: UInt64) -> Int? {
        for display in displays {
            guard let a = display.spaces.firstIndex(where: { $0.id == from }) else { continue }
            guard let b = display.spaces.firstIndex(where: { $0.id == to }) else { return nil }
            return b - a
        }
        return nil
    }

    /// The Space showing on the display that holds `space`.
    func current(onDisplayOf space: UInt64) -> UInt64? {
        displayIndex(of: space).flatMap { displays[$0].current }
    }

    /// Finds a saved desktop again: by its UUID, else (no UUID saved) by its number.
    func space(matching stored: StoredDesktop) -> UInt64? {
        let desktops = displays.flatMap(\.spaces).filter(\.isDesktop)
        if !stored.uuid.isEmpty { return desktops.first { $0.uuid == stored.uuid }?.id }
        return desktops.indices.contains(stored.number - 1) ? desktops[stored.number - 1].id : nil
    }

    /// What to save for a desktop. `nil` for a full-screen app's Space or an unknown one.
    func stored(_ space: UInt64) -> StoredDesktop? {
        guard let found = self.space(space), found.isDesktop, let number = desktopNumber(of: space) else { return nil }
        return StoredDesktop(uuid: found.uuid, number: number)
    }
}
