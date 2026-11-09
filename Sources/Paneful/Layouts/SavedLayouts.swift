import AppKit

/// Saved layouts: ⌃⌥⇧1…9 stores where every window on screen is under that number, and ⌃⌥1…9 puts them back.
///
/// - Saved: every standard window on the current desktop (all displays), front to back, by app and title, with
///   its frame. A tab group is one item: its tabs in order, its frame and its visible tab.
/// - Restoring finds each saved window among the open ones (same app; the same or a similar title, otherwise
///   the window nearest to where it was), brings back minimized windows and hidden apps, forms the tab groups
///   again (and splits off windows that were grouped since), moves everything into place and restores the
///   stacking order. Windows that aren't open are skipped (apps aren't launched); windows that aren't part of
///   the layout stay where they are.
/// - A display that's gone or changed size: its windows keep their relative place and size on the display
///   closest to it (LayoutGeometry).
/// - With auto-tiling on, restoring floats the current windows (the layout replaces the tiling); new windows
///   are still tiled.
@MainActor
final class SavedLayouts {
    static let shared = SavedLayouts()
    static let numbers = 1...9

    private let store = LayoutStore()
    private lazy var layouts: [Int: SavedLayout] =
        Dictionary(store.load().map { ($0.number, $0) }, uniquingKeysWith: { _, last in last })

    private init() {}

    var all: [SavedLayout] { layouts.values.sorted { $0.number < $1.number } }

    func layout(_ number: Int) -> SavedLayout? { layouts[number] }

    // MARK: - Commands

    /// ⌃⌥⇧<number> / menu: saves the current arrangement under `number`, replacing what was there.
    func save(_ number: Int) {
        guard Permissions.isTrusted, !SystemState.shared.isPaused else { NSSound.beep(); return }
        let items = capture()
        guard !items.isEmpty else {
            NSSound.beep()
            Toast.shared.show("No windows to save", detail: "Open and arrange some windows first")
            return
        }
        let replaced = layouts[number] != nil
        let layout = SavedLayout(number: number, savedAt: Date(), items: items)
        layouts[number] = layout
        store.save(all)
        Log.layouts.notice("Saved layout \(number, privacy: .public): \(layout.windowCount, privacy: .public) windows (\(layout.summary, privacy: .public))")
        Toast.shared.show("Layout \(number) \(replaced ? "replaced" : "saved")",
                          detail: "\(Self.count(layout.windowCount)) · ⌃⌥\(number) brings \(layout.windowCount == 1 ? "it" : "them") back")
    }

    /// ⌃⌥<number> / menu: puts the windows saved under `number` back.
    func restore(_ number: Int) {
        guard Permissions.isTrusted, !SystemState.shared.isPaused else { NSSound.beep(); return }
        guard let layout = layouts[number] else {
            NSSound.beep()
            Toast.shared.show("No layout saved as \(number)",
                              detail: "Arrange your windows, then press ⌃⌥⇧\(number) to save them")
            return
        }

        // The open windows of the layout's apps, paired with the saved ones.
        let bundles = Set(layout.items.flatMap { $0.windows.map(\.bundleID) })
        var open: [AXWindow] = []
        var openInfo: [LayoutMatcher.Window] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, bundles.contains(bundle),
                  app.processIdentifier != WindowQuery.ownPID else { continue }
            for window in AXWindow.windows(ofApp: app.processIdentifier) where window.isStandardWindow && !window.isFullScreen {
                open.append(window)
                openInfo.append(LayoutMatcher.Window(bundleID: bundle, title: window.title, frame: window.frame))
            }
        }
        let saved = layout.items.flatMap { item in
            item.windows.map { LayoutMatcher.Window(bundleID: $0.bundleID, title: $0.title, frame: item.frame) }
        }
        let matches = LayoutMatcher.match(saved: saved, open: openInfo)

        var plan: [Step] = []
        var missing: [String] = []
        var next = 0
        for item in layout.items {
            var windows: [AXWindow] = []
            var visible: AXWindow?
            for (tab, savedWindow) in item.windows.enumerated() {
                let match = matches[next]
                next += 1
                guard let index = match else {
                    if !missing.contains(savedWindow.appName) { missing.append(savedWindow.appName) }
                    continue
                }
                windows.append(open[index])
                if tab == item.activeTab { visible = open[index] }
            }
            guard let first = windows.first else { continue }
            plan.append(Step(item: item, windows: windows, visible: visible ?? first))
        }
        guard !plan.isEmpty else {
            NSSound.beep()
            Toast.shared.show("Layout \(number): none of its windows are open", detail: layout.summary)
            return
        }

        apply(plan)
        let placed = plan.reduce(0) { $0 + $1.windows.count }
        Log.layouts.notice("Restored layout \(number, privacy: .public): \(placed, privacy: .public) of \(layout.windowCount, privacy: .public) windows")
        Toast.shared.show("Layout \(number) restored",
                          detail: placed == layout.windowCount ? Self.count(placed)
                              : "\(placed) of \(layout.windowCount) windows · not open: \(missing.joined(separator: ", "))")
    }

    /// Menu: "Forget Layout".
    func forget(_ number: Int) {
        guard layouts.removeValue(forKey: number) != nil else { return }
        store.save(all)
        Log.layouts.notice("Forgot layout \(number, privacy: .public)")
    }

    // MARK: - Saving

    /// Every standard window on screen (current desktop, all displays), front to back. A tab group is one item.
    private func capture() -> [SavedLayout.Item] {
        let manager = TabGroupManager.shared
        var windowsByID: [pid_t: [CGWindowID: AXWindow]] = [:]
        var groupsSaved = Set<UUID>()
        var items: [SavedLayout.Item] = []

        for screenWindow in WindowQuery.onScreenWindows()
        where screenWindow.layer == 0 && screenWindow.pid != WindowQuery.ownPID {
            let pid = screenWindow.pid
            if windowsByID[pid] == nil {
                var byID: [CGWindowID: AXWindow] = [:]
                for window in AXWindow.windows(ofApp: pid) {
                    if let id = window.windowID { byID[id] = window }
                }
                windowsByID[pid] = byID
            }
            guard let window = windowsByID[pid]?[screenWindow.id], window.isStandardWindow, !window.isFullScreen
            else { continue }

            if let group = manager.group(containing: window) {
                // Its first window in the list is the visible tab; the tabs behind it are saved with it.
                guard groupsSaved.insert(group.id).inserted else { continue }
                let tabs = group.windows.compactMap { tab in describe(tab).map { (tab, $0) } }
                guard !tabs.isEmpty else { continue }
                let active = group.active.flatMap { active in tabs.firstIndex { $0.0 == active } } ?? 0
                items.append(SavedLayout.Item(windows: tabs.map(\.1), frame: group.contentFrame,
                                              screen: visibleFrame(around: group.outerFrame), activeTab: active))
            } else if let description = describe(window) {
                let frame = window.frame ?? screenWindow.bounds
                items.append(SavedLayout.Item(windows: [description], frame: frame, screen: visibleFrame(around: frame)))
            }
        }
        return items
    }

    private func describe(_ window: AXWindow) -> SavedLayout.Window? {
        guard let app = NSRunningApplication(processIdentifier: window.pid), let bundle = app.bundleIdentifier else {
            return nil
        }
        let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
        return SavedLayout.Window(bundleID: bundle, appName: app.localizedName ?? bundle, title: title)
    }

    /// Visible frame (AX coordinates) of the display showing most of `rect`.
    private func visibleFrame(around rect: CGRect) -> CGRect {
        Geometry.screen(forAX: rect).map { Geometry.toAX($0.visibleFrame) } ?? rect
    }

    // MARK: - Restoring

    /// One saved item and the open windows that take its place.
    private struct Step {
        let item: SavedLayout.Item
        let windows: [AXWindow]
        /// The window in front: the window itself, or the group's visible tab.
        let visible: AXWindow
    }

    private func apply(_ plan: [Step]) {
        let manager = TabGroupManager.shared
        let screens = NSScreen.screens.map { Geometry.toAX($0.visibleFrame) }
        let everyone = Set(plan.flatMap(\.windows))
        /// Windows coming back from the Dock or from a hidden app animate in; the stacking order waits for them.
        var appearing = false

        // The layout replaces the auto-tiling arrangement. New windows are still tiled.
        if AutoTiler.shared.isEnabled { AutoTiler.shared.floatAll() }

        for pid in Set(everyone.map(\.pid)) {
            guard let app = NSRunningApplication(processIdentifier: pid), app.isHidden else { continue }
            app.unhide()
            appearing = true
        }

        // A window saved on its own leaves the tab group it's in now. (A minimized one too: coming back from
        // the Dock would put it back in its group.)
        for step in plan where step.windows.count == 1 {
            let window = step.windows[0]
            if let group = manager.boundGroup(of: window), group.isFormed || window.isMinimized {
                manager.detach(window)
            }
        }
        // Tab groups are formed again (or changed to match) at their saved frame.
        for step in plan where step.windows.count > 1 {
            let outer = LayoutGeometry.place(outerFrame(of: step.item), savedScreen: step.item.screen, screens: screens)
            manager.arrange(step.windows, contentFrame: contentFrame(inside: outer), active: step.visible,
                            claimedElsewhere: everyone.subtracting(step.windows))
        }
        for window in everyone where window.isMinimized {
            window.setMinimized(false)
            appearing = true
        }
        for step in plan where step.windows.count == 1 {
            // A saved group with only one of its windows open: that window takes the group's whole frame.
            let frame = outerFrame(of: step.item)
            FrameKeeper.shared.place(step.windows[0],
                                     LayoutGeometry.place(frame, savedScreen: step.item.screen, screens: screens))
        }

        // Stacking order: raise back to front, then focus the front-most window.
        let order = plan.map(\.visible)
        Task { @MainActor in
            if appearing { try? await Task.sleep(for: .milliseconds(600)) }
            for window in order.reversed() { window.raise() }
            if let front = order.first {
                if let group = manager.group(containing: front) {
                    manager.activate(group, window: front)
                } else {
                    front.focus()
                }
            }
            manager.placeBars()
        }
    }

    /// A group's frame including its tab bar (a single window's frame as it is).
    private func outerFrame(of item: SavedLayout.Item) -> CGRect {
        guard item.isGroup else { return item.frame }
        return CGRect(x: item.frame.minX, y: item.frame.minY - TabBarPanel.height,
                      width: item.frame.width, height: item.frame.height + TabBarPanel.height)
    }

    private func contentFrame(inside outer: CGRect) -> CGRect {
        CGRect(x: outer.minX, y: outer.minY + TabBarPanel.height,
               width: outer.width, height: outer.height - TabBarPanel.height)
    }

    private static func count(_ windows: Int) -> String { windows == 1 ? "1 window" : "\(windows) windows" }
}
