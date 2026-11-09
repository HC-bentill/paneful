import AppKit

/// What an auto-tiling tile holds.
enum TileItem: Hashable {
    case window(AXWindow)
    /// A tab group is one tile; its tab bar spans the tile's width.
    case group(UUID)
    /// An app that's still launching. Its placeholder holds the slot until its first window arrives.
    case pending(pid_t)
}

struct Tile {
    var item: TileItem
    /// Share of the stack column's height (relative; unused for the main tile).
    var weight: CGFloat = 1
    /// Taking no space right now (minimized, its app hidden, or on another Space). It keeps its place, so it
    /// comes back to the same slot.
    var parked = false
    /// When a pending tile was added.
    var since: TimeInterval = 0
}

/// One display's layout: tiles in order, the first is the main tile.
@MainActor
final class ScreenLayout {
    let displayID: CGDirectDisplayID
    var tiles: [Tile] = []
    var mainRatio: CGFloat = 0.5

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    var activeIndices: [Int] { tiles.indices.filter { !tiles[$0].parked } }
}

/// Auto-tiling (off by default): new windows take a tile instead of opening wherever their app puts them.
///
/// - The first new window splits the screen with the window you were using: that one goes left, the new one
///   right. More new windows stack top to bottom in the right column.
/// - While an app launches, a placeholder holds its slot. Closing or minimizing a window gives its space to
///   the others, and the last one left fills the screen. A minimized window returns to the same slot.
/// - A tab group is one tile. Each display has its own layout; each Space shows only its own windows.
/// - Drop a tiled window onto another tile to swap them, or onto another display to join its layout.
///   Resize a tile by dragging its edge and the layout follows.
/// - Windows that were open before auto-tiling was turned on stay where they are.
///
/// Auto-tabbing new windows (also off by default) uses the same detection: a new window joins the tab group of
/// the window you were using, or starts a group with it. With both on, a new window joins a tab first; a tab
/// group is one tile, so it lands in that group's tile.
///
/// New windows are found with the window server's list (cheap), compared each tick with every window seen
/// before. Accessibility is used only for windows that are actually new.
@MainActor
final class AutoTiler {
    static let shared = AutoTiler()

    /// Apps whose windows always float, on top of the user's own "Always Float" list.
    private static let builtInFloating: Set<String> = [
        "com.apple.systempreferences", "com.apple.archiveutility", "com.apple.installer",
        "io.github.hc-bentill.paneful",
    ]

    private var layouts: [CGDirectDisplayID: ScreenLayout] = [:]
    /// Every window-server window seen so far. Anything not in here is a new window.
    private var seen: Set<CGWindowID> = []
    /// Windows that are new but whose Accessibility details aren't readable yet, with when they appeared.
    private var appearing: [CGWindowID: TimeInterval] = [:]
    /// Mark everything that exists as seen on the next pass, without tiling it (turned on, Space switch…).
    private var needsBaseline = true
    /// Apps launched recently, which may get a placeholder tile while their first window is on its way.
    private var launched: [pid_t: TimeInterval] = [:]
    /// Skip layout passes until then (a Space switch is animating).
    private var quietUntil: TimeInterval = 0
    private var lastMouseUp: TimeInterval = 0
    /// The last frame each tile was given, to tell the user's resizes from our own moves and to stop
    /// insisting on windows that won't fit (apps with a minimum size).
    private struct Placement {
        var frame: CGRect
        var time: TimeInterval
        /// The window has been seen at this frame, so a later size change came from someone else.
        var settled = false
    }
    private var placements: [TileItem: Placement] = [:]
    private let placeholders = TilePlaceholders()
    private var started = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var manager: TabGroupManager { .shared }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { AutoTiler.shared.appLaunched(pid) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { AutoTiler.shared.appTerminated(pid) }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Windows on the Space just switched to aren't new, and the switch is still animating.
                let tiler = AutoTiler.shared
                tiler.needsBaseline = true
                tiler.quietUntil = tiler.now + 0.8
            }
        }
        // After sleep or a display change, windows that reappear aren't new either.
        SystemState.shared.onResume { AutoTiler.shared.needsBaseline = true }
    }

    // MARK: - Commands

    var isEnabled: Bool { Settings.autoTiling }

    /// Menu: "Auto-tile New Windows". Turning it on leaves open windows where they are; turning it off
    /// stops arranging and leaves every window where it is.
    func setEnabled(_ on: Bool) {
        Settings.autoTiling = on
        layouts.removeAll()
        placements.removeAll()
        placeholders.hideAll()
        needsBaseline = true
        Log.tiling.notice("Auto-tiling \(on ? "on" : "off", privacy: .public)")
    }

    var autoTabsNewWindows: Bool { Settings.autoTabNewWindows }

    /// Menu: "Auto-tab New Windows". Windows that are already open aren't touched.
    func setAutoTab(_ on: Bool) {
        Settings.autoTabNewWindows = on
        needsBaseline = true
        Log.tiling.notice("Auto-tab new windows \(on ? "on" : "off", privacy: .public)")
    }

    /// Menu: "Float All Windows". Stops arranging the current windows, leaving them where they are. New
    /// windows are still tiled (into a fresh layout).
    func floatAll() {
        layouts.removeAll()
        placements.removeAll()
        placeholders.hideAll()
        Log.tiling.notice("Floated all windows")
    }

    /// Whether `window` (or its tab group) has a tile.
    func isTiled(_ window: AXWindow) -> Bool { locate(window) != nil }

    /// ⌃⌥F / menu: takes the focused window (or its group) out of the layout, or puts it in.
    func toggle(_ window: AXWindow) {
        guard isEnabled else { NSSound.beep(); return }
        if isTiled(window) {
            release(window)
        } else if let frame = window.frame, isTileable(window, bounds: frame, requireNew: false) {
            adopt(window, bounds: frame, seed: false, flash: false)
            update()
        } else {
            NSSound.beep()
        }
    }

    /// The window (or its group) leaves the layout and floats where it is; the others close the gap.
    /// Used when the user snaps a tiled window somewhere specific.
    func release(_ window: AXWindow) {
        guard let (layout, index) = locate(window) else { return }
        let tile = layout.tiles.remove(at: index)
        placements[tile.item] = nil
        Log.tiling.info("Window left the layout; it floats now")
    }

    /// Menu: "Always Float <app>". Toggles the rule for the app and takes its windows out of the layout.
    func toggleAlwaysFloat(bundleID: String) {
        var floating = Settings.alwaysFloatBundleIDs
        if floating.contains(bundleID) {
            floating.remove(bundleID)
        } else {
            floating.insert(bundleID)
            for layout in layouts.values {
                layout.tiles.removeAll { tile in
                    switch tile.item {
                    case .window(let window): window.bundleID == bundleID
                    case .pending(let pid): NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
                    case .group: false
                    }
                }
            }
        }
        Settings.alwaysFloatBundleIDs = floating
    }

    func floatsByDefault(bundleID: String) -> Bool { Self.builtInFloating.contains(bundleID) }

    func alwaysFloats(bundleID: String) -> Bool {
        Self.builtInFloating.contains(bundleID) || Settings.alwaysFloatBundleIDs.contains(bundleID)
    }

    // MARK: - Drags (from DragController)

    /// Any left mouse-up. A tile whose size changed shortly after one was resized by the user.
    func noteMouseUp() { lastMouseUp = now }

    /// The user let go of a dragged window (no snap or tab target). Dropped onto another tile: the two swap.
    /// Dropped onto another display: it joins that display's layout. Anywhere else, it slides back into its
    /// tile on the next pass.
    func windowDropped(_ window: AXWindow, atCocoa point: CGPoint) {
        guard isEnabled, let (layout, index) = locate(window),
              let screen = Geometry.screen(containingCocoa: point), let displayID = screen.displayID else { return }
        let cursor = Geometry.axPoint(fromCocoa: point)

        if displayID != layout.displayID {
            let tile = layout.tiles.remove(at: index)
            let target = self.layout(for: displayID)
            let frames = tileFrames(target, on: screen)
            if let hit = TileLayout.index(of: cursor, in: frames.map(\.frame)) {
                target.tiles.insert(tile, at: frames[hit].index)
            } else {
                target.tiles.append(tile)
            }
            Log.tiling.info("Tile moved to another display")
        } else {
            let frames = tileFrames(layout, on: screen)
            guard let hit = TileLayout.index(of: cursor, in: frames.map(\.frame)),
                  frames[hit].index != index else { return }
            layout.tiles.swapAt(index, frames[hit].index)
            Log.tiling.info("Swapped two tiles")
        }
        placements.removeAll()
    }

    // MARK: - The tick

    /// Called every tick (after the tab groups have been refreshed).
    func update() {
        let tiling = Settings.autoTiling, tabbing = Settings.autoTabNewWindows
        guard tiling || tabbing else { return }
        guard !SystemState.shared.isPaused, now >= quietUntil else { return }

        let onScreen = WindowQuery.onScreenWindows().filter { $0.layer == 0 && $0.pid != WindowQuery.ownPID }
        let visible = Set(onScreen.map(\.id))
        if tiling { resolveTiles(visible: visible) }

        if needsBaseline {
            seen.formUnion(WindowQuery.allWindowIDs())
            appearing.removeAll()
            needsBaseline = false
        } else {
            adoptNewWindows(onScreen, visible: visible)
        }

        guard tiling else { return }
        // With auto-tab on, a launching app's window will most likely become a tab, so no tile is held for it.
        if !tabbing { addLaunchPlaceholders(onScreen: onScreen) }
        // Not while the mouse is down: the user may be dragging or resizing a window right now.
        if NSEvent.pressedMouseButtons == 0 { applyLayouts() }
        updatePlaceholders()
    }

    // MARK: - New windows

    private func adoptNewWindows(_ onScreen: [ScreenWindow], visible: Set<CGWindowID>) {
        let time = now
        for screenWindow in onScreen where !seen.contains(screenWindow.id) {
            let since = appearing[screenWindow.id] ?? time
            appearing[screenWindow.id] = since
            // A brand-new window's Accessibility element can lag behind it; keep trying for a moment.
            guard let window = WindowQuery.axWindow(for: screenWindow) else {
                if time - since > 2 { seen.insert(screenWindow.id); appearing[screenWindow.id] = nil }
                continue
            }
            seen.insert(screenWindow.id)
            appearing[screenWindow.id] = nil
            guard isTileable(window, bounds: screenWindow.bounds, requireNew: true) else { continue }
            if Settings.autoTabNewWindows, tabIntoRecent(window, visible: visible) { continue }
            if Settings.autoTiling { adopt(window, bounds: screenWindow.bounds, seed: true, flash: true) }
        }
        appearing = appearing.filter { time - $0.value <= 2 }
    }

    /// Whether a window can be tiled. Dialogs, sheets, panels, full-screen and fixed-size windows can't.
    private func isTileable(_ window: AXWindow, bounds: CGRect, requireNew: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid), app.activationPolicy == .regular,
              !alwaysFloats(bundleID: app.bundleIdentifier ?? "") else { return false }
        guard bounds.width >= 200, bounds.height >= 150,
              window.isStandardWindow, !window.isFullScreen, !window.isMinimized, window.isResizable else { return false }
        guard locate(window) == nil else { return false }
        // A window that tabbed itself into a remembered group belongs to that group, which floats unless it
        // has a tile already.
        if requireNew, manager.group(containing: window) != nil { return false }
        return true
    }

    /// Gives a window a tile on the display it's on. With `seed`, an empty layout first takes in the window
    /// the user was working in, so the new window splits the screen with it.
    private func adopt(_ window: AXWindow, bounds: CGRect, seed: Bool, flash: Bool) {
        guard let screen = Geometry.screen(forAX: bounds), let displayID = screen.displayID else { return }
        let layout = layout(for: displayID)
        let item: TileItem = manager.group(containing: window).map { .group($0.id) } ?? .window(window)

        if let pending = layout.tiles.firstIndex(where: { $0.item == .pending(window.pid) }) {
            // The launching app's window arrived: it takes the placeholder's slot.
            placeholders.hide(.pending(window.pid))
            layout.tiles[pending] = Tile(item: item)
        } else {
            if seed, layout.activeIndices.isEmpty, let main = recentWindow(on: screen, excluding: window) {
                layout.tiles.append(Tile(item: main))
            }
            layout.tiles.append(Tile(item: item))
        }
        let app = NSRunningApplication(processIdentifier: window.pid)
        Log.tiling.notice("Tiled new \(app?.localizedName ?? "?", privacy: .public) window (\(layout.activeIndices.count, privacy: .public) tile(s) on this display)")

        if flash, let target = tileFrames(layout, on: screen).first(where: { layout.tiles[$0.index].item == item }) {
            placeholders.flash(item, frame: target.frame, app: app, title: window.title)
        }
    }

    /// The window the user was working in before `window` appeared (or before app `excludingApp` launched),
    /// if it's on `screen` and can be tiled.
    private func recentWindow(on screen: NSScreen, excluding window: AXWindow?, excludingApp pid: pid_t? = nil) -> TileItem? {
        let screenFrame = Geometry.toAX(screen.frame)
        for candidate in FocusTracker.shared.recent(excluding: window) where candidate.pid != pid {
            guard let frame = candidate.frame, screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            if let group = manager.group(containing: candidate) {
                return locate(candidate) == nil ? .group(group.id) : nil
            }
            guard !candidate.isMinimized, isTileable(candidate, bounds: frame, requireNew: false) else { continue }
            return .window(candidate)
        }
        return nil
    }

    // MARK: - Auto-tabbing new windows

    /// Adds a new window as a tab to the window the user was working in, joining that window's group or
    /// starting one with it. False when there's no suitable window (then the new one floats, or is tiled).
    private func tabIntoRecent(_ window: AXWindow, visible: Set<CGWindowID>) -> Bool {
        let target = FocusTracker.shared.recent(excluding: window).first { candidate in
            // On screen on this Space (not minimized, hidden or elsewhere), a normal window, not a floating app.
            guard let id = manager.windowID(of: candidate), visible.contains(id),
                  candidate.isStandardWindow, !candidate.isFullScreen,
                  !alwaysFloats(bundleID: candidate.bundleID ?? "") else { return false }
            return true
        }
        guard let target else { return false }
        let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
        Log.tiling.notice("Auto-tabbed new \(app, privacy: .public) window with the window in front of it")
        manager.addToGroup(target: target, window: window)
        return manager.boundGroup(of: window) != nil
    }

    // MARK: - Launching apps

    private func appLaunched(_ pid: pid_t) {
        guard isEnabled else { return }
        launched[pid] = now
    }

    private func appTerminated(_ pid: pid_t) {
        launched[pid] = nil
        for layout in layouts.values {
            layout.tiles.removeAll { tile in
                switch tile.item {
                case .window(let window): window.pid == pid
                case .pending(let other): other == pid
                case .group: false
                }
            }
        }
        placeholders.hide(.pending(pid))
    }

    /// An app the user just launched gets a placeholder tile right away, so the layout makes room before its
    /// window appears. Only once the app is frontmost (it was opened on purpose) and has no window yet.
    private func addLaunchPlaceholders(onScreen: [ScreenWindow]) {
        for (pid, time) in launched {
            guard now - time <= 4 else { launched[pid] = nil; continue }
            guard let app = NSRunningApplication(processIdentifier: pid), app.isActive else { continue }
            launched[pid] = nil
            guard app.activationPolicy == .regular, !alwaysFloats(bundleID: app.bundleIdentifier ?? ""),
                  !onScreen.contains(where: { $0.pid == pid }),
                  let screen = Geometry.screen(containingCocoa: NSEvent.mouseLocation),
                  let displayID = screen.displayID else { continue }
            let layout = layout(for: displayID)
            if layout.activeIndices.isEmpty, let main = recentWindow(on: screen, excluding: nil, excludingApp: pid) {
                layout.tiles.append(Tile(item: main))
            }
            layout.tiles.append(Tile(item: .pending(pid), since: now))
            Log.tiling.notice("Holding a tile for \(app.localizedName ?? "?", privacy: .public) while it launches")
        }
    }

    // MARK: - Keeping tiles in step with their windows

    /// Drops tiles whose window closed, parks the ones that are minimized, hidden or on another Space,
    /// and follows windows into and out of tab groups.
    private func resolveTiles(visible: Set<CGWindowID>) {
        var claimed = Set<TileItem>()
        for displayID in layouts.keys.sorted() {
            guard let layout = layouts[displayID] else { continue }
            layout.tiles = layout.tiles.compactMap { original in
                var tile = original
                switch tile.item {
                case .window(let window):
                    if window.isGone { return nil }
                    if let group = manager.group(containing: window) {
                        // Tabbed into a group: the group takes over the tile.
                        tile.item = .group(group.id)
                        tile.parked = isParked(group, visible: visible)
                    } else {
                        tile.parked = isParked(window, visible: visible)
                    }
                case .group(let id):
                    guard let group = manager.group(withID: id) else { return nil }
                    if group.isFormed {
                        tile.parked = isParked(group, visible: visible)
                    } else if let last = group.windows.first, group.windows.count == 1 {
                        // Down to one open window: it keeps the tile.
                        tile.item = .window(last)
                        tile.parked = isParked(last, visible: visible)
                    } else if group.members.contains(where: { $0.window != nil }) {
                        tile.parked = true   // its windows are minimized
                    } else {
                        return nil           // all of its windows closed
                    }
                case .pending(let pid):
                    if now - tile.since > 6 || NSRunningApplication(processIdentifier: pid) == nil {
                        placeholders.hide(tile.item)
                        return nil
                    }
                    tile.parked = false
                }
                guard claimed.insert(tile.item).inserted else { return nil }
                return tile
            }
        }
        layouts = layouts.filter { !$0.value.tiles.isEmpty }
    }

    private func isParked(_ window: AXWindow, visible: Set<CGWindowID>) -> Bool {
        guard let id = manager.windowID(of: window) else { return window.isMinimized }
        return !visible.contains(id)
    }

    private func isParked(_ group: TabGroup, visible: Set<CGWindowID>) -> Bool {
        guard let active = group.active else { return true }   // the whole group is minimized
        return isParked(active, visible: visible)
    }

    // MARK: - Layout

    private func layout(for displayID: CGDirectDisplayID) -> ScreenLayout {
        if let existing = layouts[displayID] { return existing }
        let layout = ScreenLayout(displayID: displayID)
        layouts[displayID] = layout
        return layout
    }

    /// Where `window`'s tile is: its own, or its tab group's.
    private func locate(_ window: AXWindow) -> (ScreenLayout, Int)? {
        let group = manager.group(containing: window) ?? manager.boundGroup(of: window)
        for layout in layouts.values {
            if let index = layout.tiles.firstIndex(where: { tile in
                switch tile.item {
                case .window(let other): other == window
                case .group(let id): id == group?.id
                case .pending: false
                }
            }) {
                return (layout, index)
            }
        }
        return nil
    }

    /// Each active tile's frame (AX), with its index in `layout.tiles`.
    private func tileFrames(_ layout: ScreenLayout, on screen: NSScreen) -> [(index: Int, frame: CGRect)] {
        let active = layout.activeIndices
        let frames = TileLayout.frames(in: Geometry.toAX(screen.visibleFrame), mainRatio: layout.mainRatio,
                                       weights: active.map { layout.tiles[$0].weight })
        return Array(zip(active, frames)).map { (index: $0.0, frame: $0.1) }
    }

    private func applyLayouts() {
        for layout in Array(layouts.values) {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == layout.displayID }) else {
                rehome(layout)
                continue
            }
            var frames = tileFrames(layout, on: screen)
            if adoptUserResize(layout, frames: frames, on: screen) {
                frames = tileFrames(layout, on: screen)
            }
            for (index, frame) in frames {
                place(layout.tiles[index].item, frame)
            }
        }
    }

    /// The display a layout was on is gone: its tiles join the layout of the display each window is on now.
    private func rehome(_ layout: ScreenLayout) {
        layouts[layout.displayID] = nil
        for tile in layout.tiles {
            guard let frame = currentFrame(of: tile.item), let screen = Geometry.screen(forAX: frame),
                  let displayID = screen.displayID else { continue }
            self.layout(for: displayID).tiles.append(tile)
        }
    }

    /// The user dragged a tile's edge: right after a mouse-up, a window that had settled into its tile has a
    /// different size, and not because Paneful moved it. Resize the layout around it instead of undoing it.
    /// Returns true if the layout changed.
    private func adoptUserResize(_ layout: ScreenLayout, frames: [(index: Int, frame: CGRect)], on screen: NSScreen) -> Bool {
        guard frames.count > 1, now - lastMouseUp < 1.5 else { return false }
        for (position, entry) in frames.enumerated() {
            let item = layout.tiles[entry.index].item
            guard let placed = placements[item], placed.settled, placed.frame == entry.frame,
                  !isBeingPlaced(item), let actual = currentFrame(of: item),
                  abs(actual.width - placed.frame.width) > 24 || abs(actual.height - placed.frame.height) > 24
            else { continue }
            let weights = layout.activeIndices.map { layout.tiles[$0].weight }
            let result = TileLayout.resized(index: position, to: actual, in: Geometry.toAX(screen.visibleFrame),
                                            mainRatio: layout.mainRatio, weights: weights)
            layout.mainRatio = result.mainRatio
            for (activeIndex, weight) in zip(layout.activeIndices, result.weights) {
                layout.tiles[activeIndex].weight = weight
            }
            Log.tiling.info("Tile resized by the user: main ratio \(result.mainRatio, privacy: .public)")
            lastMouseUp = 0   // one resize per mouse-up
            return true
        }
        return false
    }

    private func currentFrame(of item: TileItem) -> CGRect? {
        switch item {
        case .window(let window): window.frame
        case .group(let id): manager.group(withID: id).flatMap { $0.isFormed ? $0.outerFrame : nil }
        case .pending: nil
        }
    }

    private func isBeingPlaced(_ item: TileItem) -> Bool {
        switch item {
        case .window(let window): FrameKeeper.shared.isPlacing(window)
        case .group(let id): manager.group(withID: id)?.active.map(FrameKeeper.shared.isPlacing) ?? false
        case .pending: false
        }
    }

    private func place(_ item: TileItem, _ frame: CGRect) {
        guard !isBeingPlaced(item), let actual = currentFrame(of: item) else { return }
        if actual.isRoughly(frame) {
            if placements[item]?.frame == frame {
                placements[item]?.settled = true
            } else {
                placements[item] = Placement(frame: frame, time: now, settled: true)
            }
            return
        }
        // Asked for this exact frame a moment ago and it didn't stick: the app won't fit (minimum size).
        if let placed = placements[item], placed.frame == frame, now - placed.time < 8 { return }
        placements[item] = Placement(frame: frame, time: now)
        switch item {
        case .window(let window):
            FrameKeeper.shared.place(window, frame)
        case .group(let id):
            if let group = manager.group(withID: id) { manager.setOuterFrame(of: group, to: frame, focus: false) }
        case .pending:
            break
        }
    }

    /// Placeholders follow their pending tiles; ones whose tile is gone fade out.
    private func updatePlaceholders() {
        var pendingFrames: [TileItem: CGRect] = [:]
        for layout in layouts.values {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == layout.displayID }) else { continue }
            for (index, frame) in tileFrames(layout, on: screen) {
                if case .pending = layout.tiles[index].item { pendingFrames[layout.tiles[index].item] = frame }
            }
        }
        for (item, frame) in pendingFrames {
            guard case .pending(let pid) = item else { continue }
            placeholders.show(item, frame: frame, app: NSRunningApplication(processIdentifier: pid),
                              title: nil, status: "Opening…")
        }
        for key in placeholders.keys {
            if case .pending = key, pendingFrames[key] == nil { placeholders.hide(key) }
        }
    }
}

extension NSScreen {
    /// The display's ID, stable while it stays connected.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
