import AppKit
import ApplicationServices

/// Windows from any apps stacked at the same frame, with one floating tab bar above them.
///
/// A group is *remembered*: each member is stored by app (plus title when needed), so a window that closes
/// and reopens later rejoins it. A group is *formed* (tab bar shown, frames kept in sync) only while at
/// least two members have a live, un-minimized window. With fewer, the remaining window floats normally.
@MainActor
final class TabGroup {
    struct Member {
        var signature: WindowSignature
        /// The member's window while it exists. `nil` while it's closed or its app isn't running.
        var window: AXWindow?
        var minimized = false
        /// Its app hid the window instead of closing it (Postman, Teams, Slack… "close" to the background).
        /// Like a minimized tab, it steps out of the bar until the app shows the window again.
        var hidden = false
        /// The window went into macOS's own full screen (its own Space). Like a minimized tab, it steps out of
        /// the bar, and it comes back as the active tab when it leaves full screen.
        var fullScreen = false
        /// The window is on another desktop (Space) than the rest of the group, e.g. it was dragged there in
        /// Mission Control, or it couldn't be carried along when the group moved. Its tab stays in the bar,
        /// dimmed as "away"; clicking it brings the window over (`checkDesktops`, `bringBack`).
        var elsewhere = false

        var isLive: Bool { window != nil && !minimized && !hidden && !fullScreen && !elsewhere }

        /// Why an open window's tab is drawn as away (not on this desktop), if it is.
        var away: TabAway? {
            guard window != nil, !minimized, !hidden else { return nil }
            return fullScreen ? .fullScreen : elsewhere ? .otherDesktop : nil
        }

        /// Has a tab in the bar: live, or away (on another desktop or in full screen).
        var isShownInBar: Bool { isLive || away != nil }
    }

    let id: UUID
    var members: [Member]
    var activeWindow: AXWindow?
    /// The whole group was minimized with "Minimize Group": restoring any of its windows restores all.
    var collapsed = false
    /// Frame (AX coords) shared by every window in the group. The tab bar sits directly above it.
    var contentFrame: CGRect
    var bar: TabBarPanel?
    /// Set while the group fills its screen (the green button): the frame it goes back to. Remembered.
    var restoreFrame: CGRect?
    /// The desktop the group was last on. Remembered, so a re-formed group goes back there.
    var desktop: StoredDesktop?

    init(id: UUID = UUID(), members: [Member], contentFrame: CGRect, restoreFrame: CGRect? = nil,
         desktop: StoredDesktop? = nil) {
        self.id = id
        self.members = members
        self.contentFrame = contentFrame
        self.restoreFrame = restoreFrame
        self.desktop = desktop
    }

    var isFormed: Bool { bar != nil }
    var isFilled: Bool { restoreFrame != nil }

    /// Live, un-minimized windows in tab order.
    var windows: [AXWindow] { members.compactMap { $0.isLive ? $0.window : nil } }

    /// The members that have a tab in the bar, in tab order (live ones and away ones).
    var barMembers: [Int] { members.indices.filter { members[$0].isShownInBar } }

    /// A formed group keeps its bar while one of its windows is here and it has at least two tabs, away ones
    /// included: a window that went to another desktop (or full screen) stays visible as an away tab.
    var keepsBar: Bool { !windows.isEmpty && barMembers.count >= 2 }

    /// After the group was carried to desktop `target`: windows on another desktop are away, the others are
    /// back. Returns the apps whose windows stayed behind (newly away).
    func settle(on target: UInt64, spaceOf: (AXWindow) -> UInt64?) -> [String] {
        var leftBehind: [String] = []
        for index in members.indices {
            guard let window = members[index].window, !members[index].minimized, !members[index].hidden,
                  !members[index].fullScreen, let space = spaceOf(window) else { continue }
            let away = space != target
            if away && !members[index].elsewhere { leftBehind.append(members[index].signature.appName) }
            members[index].elsewhere = away
        }
        return leftBehind
    }

    var active: AXWindow? {
        let live = windows
        if let activeWindow, live.contains(activeWindow) { return activeWindow }
        return live.first
    }

    func memberIndex(of window: AXWindow) -> Int? {
        members.firstIndex { $0.window == window }
    }

    var barFrame: CGRect {
        CGRect(x: contentFrame.minX, y: contentFrame.minY - TabBarPanel.height,
               width: contentFrame.width, height: TabBarPanel.height)
    }

    /// Tab bar + windows together (AX coords).
    var outerFrame: CGRect { barFrame.union(contentFrame) }

    var displayName: String { members.map(\.signature.appName).joined(separator: " + ") }

    var stored: StoredGroup {
        StoredGroup(id: id, members: members.map(\.signature), contentFrame: contentFrame, restoreFrame: restoreFrame,
                    desktop: desktop)
    }
}

/// Creates, syncs, remembers and dissolves tab groups.
///
/// How it works: macOS can't embed one app's window in another, so every window in a group is kept
/// at the same frame; the selected tab's window is raised in front of the others. AXObservers tell us
/// when the active window is moved/resized (so the others follow), closed or minimized.
@MainActor
final class TabGroupManager {
    static let shared = TabGroupManager()

    private(set) var groups: [TabGroup] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingSync: [UUID: DispatchWorkItem] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    private var focusFollowPausedUntil: TimeInterval = 0
    private var windowIDs: [AXWindow: CGWindowID] = [:]
    /// When a window was last put back in place by the self-check, to back off from apps that resist.
    private var healedAt: [AXWindow: TimeInterval] = [:]
    private var tickCount = 0
    /// Minimizing takes a moment; until then a window can still look un-minimized to the tick fallback.
    private var minimizeGraceUntil: TimeInterval = 0
    /// When a member's window was first seen missing from the screen while a groupmate was showing.
    private var offscreenSince: [AXWindow: TimeInterval] = [:]
    /// When a full-screen member's window was first seen out of full screen again.
    private var fullScreenLeftAt: [AXWindow: TimeInterval] = [:]
    private var startedAt: TimeInterval = 0
    private var lastDesktopToastAt: TimeInterval = 0
    /// No hidden-window checks until then (a Space switch is animating and the window list is in flux).
    private var spaceSwitchUntil: TimeInterval = 0

    // Auto-tabbing of remembered windows.
    /// Per app: windows already judged. They are never auto-tabbed (again).
    private var knownWindows: [pid_t: Set<AXWindow>] = [:]
    /// New windows still allowed to auto-tab, with the time they first appeared.
    private var firstSeen: [AXWindow: TimeInterval] = [:]
    private var unresponsiveUntil: [pid_t: TimeInterval] = [:]
    /// True during the first scan after launch, which claims windows that are already open.
    private var restoring = false
    /// Paneful started while the screen was locked: that first scan waits for the unlock.
    private var restorePendingUnlock = false

    /// A new window may auto-tab for this long after it first appears (its title can arrive late).
    private static let claimPeriod: TimeInterval = 5

    private static let watched = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        startedAt = now
        groups = GroupStore.shared.load().map { stored in
            TabGroup(id: stored.id,
                     members: stored.members.map { TabGroup.Member(signature: $0) },
                     contentFrame: stored.contentFrame,
                     restoreFrame: stored.restoreFrame,
                     desktop: stored.desktop)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TabGroupManager.shared.refresh() }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let manager = TabGroupManager.shared
                manager.spaceSwitchUntil = manager.now + 1
                manager.lastSpaceChangeAt = manager.now
                manager.offscreenSince.removeAll()
                manager.refresh()
            }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { TabGroupManager.shared.appLaunched(pid) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { TabGroupManager.shared.appTerminated(pid) }
        }

        SystemState.shared.onWake { TabGroupManager.shared.restoreGroupFrames() }
        SystemState.shared.onResume { TabGroupManager.shared.resumeAfterPause() }

        // Re-form remembered groups from windows that are already open. Other apps' windows can't be read
        // or moved while the screen is locked, so if Paneful starts then (say, relaunched while the user is
        // away), wait for the unlock. Until then the tick doesn't scan either, or it would mark the open
        // windows as already seen and they'd never be restored.
        if SystemState.shared.isPaused {
            restorePendingUnlock = true
            Log.tabs.notice("Screen is locked or asleep: restoring \(self.groups.count, privacy: .public) remembered group(s) once it's back")
        } else {
            restoreOpenWindows()
        }
    }

    private func restoreOpenWindows() {
        restoring = true
        scanForRememberedWindows()
        restoring = false
        Log.tabs.notice("Loaded \(self.groups.count, privacy: .public) remembered group(s), \(self.groups.filter(\.isFormed).count, privacy: .public) re-formed")
    }

    /// The Mac woke up, the screen was unlocked, or the displays changed, and things have settled.
    /// Windows were left alone meanwhile; put every group back where it was once more, in case macOS moved
    /// something late.
    private func resumeAfterPause() {
        if restorePendingUnlock {
            restorePendingUnlock = false
            restoreOpenWindows()
            return
        }
        restoreGroupFrames()
    }

    /// Puts every group's windows and bar back at the group's frame. Runs right after waking or unlocking
    /// (so the screen looks the way it did before the Mac slept) and again once things have settled. Windows
    /// already in place aren't touched.
    private func restoreGroupFrames() {
        guard !restorePendingUnlock else { return }   // not restored since launch yet: the resume does that
        for group in groups where group.isFormed {
            if group.isFilled, let target = fillFrame(near: group.active?.frame ?? group.contentFrame) {
                // A group that fills its screen fills it again: the display, its resolution, or the room the
                // menu bar and Dock leave may have changed.
                group.contentFrame = target
            } else {
                // Only if that spot is still on a connected display; otherwise follow the window as usual.
                guard let screen = Geometry.screen(forAX: group.contentFrame),
                      Geometry.toAX(screen.frame).intersection(group.contentFrame).area >= group.contentFrame.area / 2
                else { continue }
                group.contentFrame = fitted(group.contentFrame)
            }
            for window in group.windows {
                if let frame = window.frame, !frame.isRoughly(group.contentFrame) {
                    FrameKeeper.shared.place(window, group.contentFrame)
                }
            }
            updateBar(group)
        }
        placeBars(hideMissing: !SystemState.shared.isSettling)
    }

    // MARK: - Queries

    /// The formed group showing `window` as one of its tabs.
    func group(containing window: AXWindow) -> TabGroup? {
        groups.first { $0.isFormed && $0.windows.contains(window) }
    }

    /// The group whose tab bar is showing on this desktop under an AX-space point.
    func group(withVisibleBarAtAX point: CGPoint) -> TabGroup? {
        groups.first { ($0.bar?.isShowingHere ?? false) && $0.barFrame.contains(point) }
    }

    /// The formed group showing the window-server window `id` as one of its tabs.
    func group(withWindowID id: CGWindowID) -> TabGroup? {
        groups.first { $0.isFormed && $0.windows.contains { windowID(of: $0) == id } }
    }

    func windowID(of window: AXWindow) -> CGWindowID? {
        if let cached = windowIDs[window] { return cached }
        let id = window.windowID
        windowIDs[window] = id
        return id
    }

    /// The remembered group a window belongs to, formed or not (includes minimized members).
    func boundGroup(of window: AXWindow) -> TabGroup? {
        groups.first { $0.memberIndex(of: window) != nil }
    }

    func group(withID id: UUID) -> TabGroup? {
        groups.first { $0.id == id }
    }

    // MARK: - Grouping (user actions)

    /// Adds `window` as a new tab to `target`'s group (creating the group if needed).
    func addToGroup(target: AXWindow, window: AXWindow) {
        guard target != window else { return }
        let targetGroup = boundGroup(of: target)
        if let old = boundGroup(of: window) {
            if old === targetGroup {
                if old.isFormed { activate(old, window: window) }
                return
            }
            forget(window, in: old, placeAt: nil)
        }

        let group: TabGroup
        if let targetGroup {
            group = targetGroup
        } else {
            guard let frame = target.frame else { return }
            group = TabGroup(members: [member(for: target)], contentFrame: frame)
            groups.append(group)
            observe(target)
        }
        group.members.append(member(for: window))
        observe(window)
        layoutAfterJoin(group, newcomer: window, focus: true)
        save()
    }

    /// Shows `window`'s tab: moves it into place and brings it to the front.
    func activate(_ group: TabGroup, window: AXWindow) {
        guard group.isFormed, group.windows.contains(window) else { return }
        group.activeWindow = window
        // App activation is asynchronous; don't let the next tick see the old app still frontmost
        // and switch the active tab back.
        focusFollowPausedUntil = now + 0.6
        FrameKeeper.shared.place(window, group.contentFrame)
        window.focus()
        updateBar(group)
        placeBars()
        // The app raises its window a moment later; put the bar back on top of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { TabGroupManager.shared.placeBars() }
        }
    }

    /// Moves a tab to another position in the bar (`from`/`to` count the bar's tabs, away ones included, left
    /// to right). Closed and minimized members keep their place in between. The new order is remembered.
    func moveTab(in group: TabGroup, from: Int, to: Int) {
        guard let reordered = group.members.movingLive(from: from, to: to, isLive: \.isShownInBar) else { return }
        group.members = reordered
        updateBar(group)
        save()
        Log.tabs.info("Moved tab \(from, privacy: .public) → \(to, privacy: .public) in \(group.displayName, privacy: .public)")
    }

    func cycle(from window: AXWindow?, by delta: Int) {
        guard let window, let group = group(containing: window), let active = group.active else { return }
        let live = group.windows
        guard live.count > 1, let index = live.firstIndex(of: active) else { return }
        activate(group, window: live[((index + delta) % live.count + live.count) % live.count])
    }

    /// Takes a window out of its group for good (⌃⌥W, ✕, menu).
    func remove(_ window: AXWindow) {
        guard let group = boundGroup(of: window) else { return }
        forget(window, in: group, placeAt: group.isFormed ? group.outerFrame.offsetBy(dx: 40, dy: 40) : nil)
    }

    /// Moves/resizes a whole group so that bar + windows fill `outer` (AX coords). `focus` brings its visible
    /// tab to the front (snapping does; auto-tiling rearranging the screen doesn't).
    func setOuterFrame(of group: TabGroup, to outer: CGRect, focus: Bool = true) {
        group.restoreFrame = nil   // put somewhere else on purpose: it no longer fills the screen
        setContentFrame(of: group, to: Self.content(ofOuter: outer), focus: focus)
        save()
    }

    private func setContentFrame(of group: TabGroup, to content: CGRect, focus: Bool) {
        group.contentFrame = fitted(content)
        group.windows.forEach { FrameKeeper.shared.place($0, group.contentFrame) }
        if focus { group.active?.focus() }
        updateBar(group)
        placeBars()
    }

    /// The windows' part of a bar + windows rect (AX coords).
    private static func content(ofOuter outer: CGRect) -> CGRect {
        var content = outer
        content.origin.y += TabBarPanel.height
        content.size.height -= TabBarPanel.height
        return content
    }

    // MARK: - Filling the screen (green button)

    /// The green button on a grouped window. The whole group fills its screen, with the tab bar along the top
    /// and the windows below it, like a full-screen window would. When it already does, it goes back to the
    /// size and place it had before. (macOS's own full screen holds a single window in its own Space, so a
    /// group of several apps' windows can't go there.)
    func toggleFill(_ group: TabGroup) {
        guard group.isFormed, let active = group.active, let target = fillFrame(near: group.contentFrame) else { return }
        if let previous = group.restoreFrame ?? (group.contentFrame.isRoughly(target) ? centeredContent(near: target) : nil) {
            // Back to where it was, if that spot is still on a connected display.
            let back = Self.isMostlyOnScreen(previous) ? previous : (centeredContent(near: target) ?? previous)
            group.restoreFrame = nil
            setContentFrame(of: group, to: back, focus: true)
            Log.tabs.notice("\(group.displayName, privacy: .public) went back to its size")
        } else {
            AutoTiler.shared.release(active)   // filling the screen on purpose: it floats now
            let previous = group.contentFrame
            setContentFrame(of: group, to: target, focus: true)
            group.restoreFrame = previous
            Log.tabs.notice("\(group.displayName, privacy: .public) fills the screen")
        }
        save()
    }

    /// The group's frame (AX) when it fills the screen that shows most of `rect`: the screen's usable area
    /// (below the menu bar, beside the Dock), less the tab bar's height at the top.
    private func fillFrame(near rect: CGRect) -> CGRect? {
        guard let screen = Geometry.screen(forAX: rect) else { return nil }
        return fitted(Self.content(ofOuter: Geometry.toAX(screen.visibleFrame)))
    }

    /// Where a group goes when it leaves "fill" with nothing to go back to (it was maximized another way).
    private func centeredContent(near rect: CGRect) -> CGRect? {
        guard let screen = Geometry.screen(forAX: rect) else { return nil }
        return Self.content(ofOuter: Geometry.toAX(SnapZone.center.rect(in: screen.visibleFrame)))
    }

    private static func isMostlyOnScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { Geometry.toAX($0.frame).intersection(rect).area >= rect.area / 2 }
    }

    /// A group that filled its screen and was then moved or resized (dragged, snapped, or an app that
    /// wouldn't take the size) doesn't fill it anymore: the green button fills it again instead of restoring.
    private func checkStillFilled(_ group: TabGroup) {
        guard group.isFilled, let target = fillFrame(near: group.contentFrame),
              !group.contentFrame.isRoughly(target) else { return }
        group.restoreFrame = nil
        Log.tabs.info("\(group.displayName, privacy: .public) was moved: it no longer fills the screen")
        save()
    }

    /// ⌥-click on a grouped window's green button: macOS's own full screen for that window alone. The window
    /// steps out of the group until it leaves full screen (see `windowEnteredFullScreen`).
    func enterNativeFullScreen(_ window: AXWindow) {
        window.setFullScreen(true)
    }

    /// Sends one tab's window to the Dock (the tab's ✕, or its red close button). It keeps its place in the
    /// group: the next tab takes over now, and restoring it from the Dock brings it back as the active tab.
    func minimizeTab(_ window: AXWindow) {
        let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
        Log.tabs.notice("Minimizing grouped \(app, privacy: .public) window")
        window.setMinimized(true)
    }

    /// Minimizes every window of the group into the Dock. Restoring any one of them brings the whole group back.
    func minimize(_ group: TabGroup) {
        let live = group.windows
        guard !live.isEmpty else { return }
        group.collapsed = true
        minimizeGraceUntil = now + 1.5
        for index in group.members.indices where group.members[index].isLive {
            group.members[index].minimized = true    // before the AX notifications arrive, so they're ignored
        }
        group.bar?.hide()
        for window in live {
            FrameKeeper.shared.cancel(window)
            window.setMinimized(true)
        }
        Log.tabs.notice("Minimized group \(group.displayName, privacy: .public)")
    }

    /// Dissolves every formed group and forgets it.
    func ungroupAll() {
        groups.filter(\.isFormed).forEach { ungroup($0) }
    }

    /// Dissolves a group and forgets it.
    func ungroup(_ group: TabGroup) {
        unform(group)
        group.members.compactMap(\.window).forEach { unobserve($0) }
        groups.removeAll { $0 === group }
        save()
    }

    func forgetGroup(id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        ungroup(group)
    }

    func forgetAll() {
        groups.forEach { ungroup($0) }
    }

    /// Paneful is quitting: give every window its full frame back but keep the groups remembered.
    func suspendAll() {
        groups.forEach { unform($0) }
        GroupStore.shared.saveNow(groups.map(\.stored))
    }

    // MARK: - Saved layouts

    /// Takes a window out of its tab group for good, leaving it where it is (a saved layout places it next).
    func detach(_ window: AXWindow) {
        guard let group = boundGroup(of: window) else { return }
        forget(window, in: group, placeAt: nil)
    }

    /// Makes `windows` (in tab order) one tab group whose windows fill `contentFrame`, showing `active`.
    /// The group most of them already belong to is reused, so it keeps its other remembered members; windows
    /// from other groups move over. Members that the layout puts somewhere else (`claimedElsewhere`) leave it.
    /// The caller brings back windows that are minimized: they count as tabs here already.
    func arrange(_ windows: [AXWindow], contentFrame: CGRect, active: AXWindow, claimedElsewhere: Set<AXWindow>) {
        guard windows.count >= 2 else { return }
        var tally: [ObjectIdentifier: (group: TabGroup, count: Int)] = [:]
        for window in windows {
            guard let group = boundGroup(of: window) else { continue }
            tally[ObjectIdentifier(group), default: (group, 0)].count += 1
        }
        let group: TabGroup
        if let reused = tally.values.max(by: { $0.count < $1.count })?.group {
            group = reused
        } else {
            group = TabGroup(members: [], contentFrame: contentFrame)
            groups.append(group)
        }

        // Join first, then let the others go, so the group never drops below two members on the way.
        for window in windows where group.memberIndex(of: window) == nil {
            if let old = boundGroup(of: window) { forget(window, in: old, placeAt: nil) }
            group.members.append(member(for: window))
            observe(window)
        }
        let wanted = Set(windows)
        for index in group.members.indices where group.members[index].window.map(wanted.contains) == true {
            group.members[index].minimized = false
            group.members[index].hidden = false
            group.members[index].elsewhere = false   // checked again on the next tick
        }
        for window in group.members.compactMap(\.window) where claimedElsewhere.contains(window) && !wanted.contains(window) {
            forget(window, in: group, placeAt: nil)
        }

        // Their tabs come first, in the saved order; the group's other members keep their order after them.
        let tabs = windows.compactMap { window in group.memberIndex(of: window).map { group.members[$0] } }
        group.members = tabs + group.members.filter { member in member.window.map { !wanted.contains($0) } ?? true }
        group.collapsed = false
        group.activeWindow = active
        group.restoreFrame = nil
        if group.isFormed {
            group.contentFrame = fitted(contentFrame)
            group.windows.forEach { FrameKeeper.shared.place($0, group.contentFrame) }
            updateBar(group)
            placeBars()
        } else {
            // Already at the group's frame, so forming doesn't take the bar's height off the windows again.
            group.contentFrame = contentFrame
            form(group, around: contentFrame, active: active)
        }
        save()
        Log.tabs.notice("Arranged \(group.displayName, privacy: .public) from a saved layout")
    }

    // MARK: - Membership changes

    private func member(for window: AXWindow) -> TabGroup.Member {
        let app = NSRunningApplication(processIdentifier: window.pid)
        let bundle = app?.bundleIdentifier ?? ""
        // The title only helps tell windows apart when the app has more than one.
        let several = AXWindow.windows(ofApp: window.pid).filter(\.isStandardWindow).count > 1
        let signature = WindowSignature(bundleID: bundle,
                                        appName: app?.localizedName ?? (bundle.isEmpty ? "Window" : bundle),
                                        titleHint: several ? window.title : nil)
        return TabGroup.Member(signature: signature, window: window)
    }

    /// Lays a group out after `newcomer` became live in it (joined, reopened or un-minimized).
    private func layoutAfterJoin(_ group: TabGroup, newcomer: AXWindow, focus: Bool) {
        // A window in macOS's own full screen sits in a Space of its own: it waits outside the bar until it
        // leaves full screen (then `checkFullScreenEnded` brings it in).
        var steppedAside = false
        for index in group.members.indices where group.members[index].isLive {
            if group.members[index].window?.isFullScreen == true {
                group.members[index].fullScreen = true
                steppedAside = true
            }
        }
        if steppedAside && group.isFormed && !group.keepsBar {
            reconcile(group, focusNext: false)   // not enough tabs left on the desktop for a bar
            return
        }
        let live = group.windows
        guard live.count >= 2 else {
            // Alone: it floats until another member opens. (A formed group keeps its bar, with away tabs.)
            if group.isFormed { updateBar(group) }
            return
        }

        if !group.isFormed {
            // Form around a window that was already on screen, not the newcomer.
            guard let anchor = live.first(where: { $0 != newcomer }), let frame = anchor.frame else { return }
            form(group, around: frame, active: anchor)
        }
        guard live.contains(newcomer) else {
            updateBar(group)
            return
        }
        if focus {
            activate(group, window: newcomer)
        } else {
            FrameKeeper.shared.place(newcomer, group.contentFrame)
            updateBar(group)
        }
    }

    private func form(_ group: TabGroup, around frame: CGRect, active: AXWindow) {
        if frame.isRoughly(group.contentFrame) {
            // The window is still where the group left it, already below the bar's spot (the group only
            // lost its bar for a moment). Making room for the bar again would push the window down and
            // shorten it by a bar's height every time.
            group.contentFrame = fitted(group.contentFrame)
        } else {
            var content = frame
            content.origin.y += TabBarPanel.height
            content.size.height -= TabBarPanel.height
            group.contentFrame = fitted(content)
        }
        group.activeWindow = active
        group.bar = makeBar(for: group)
        group.windows.forEach { FrameKeeper.shared.place($0, group.contentFrame) }
        updateBar(group)
        // Re-formed from remembered windows (at launch, or as they reopen): back to the group's own desktop.
        if restoring || claiming { scheduleDesktopRestore(group) }
        placeBars()
        Log.tabs.notice("Formed group \(group.displayName, privacy: .public)")
    }

    /// Hides the tab bar and gives its space back to the windows. The group stays remembered.
    private func unform(_ group: TabGroup) {
        guard let bar = group.bar else { return }
        let outer = group.outerFrame
        group.windows.forEach { FrameKeeper.shared.place($0, outer) }
        bar.close()
        group.bar = nil
        pendingSync[group.id]?.cancel()
        pendingSync[group.id] = nil
        lastBarSpace[group.id] = nil
        pendingDesktopMoves[group.id] = nil
    }

    /// Removes a window from a group for good. `placeAt` (AX) moves and focuses it, e.g. when popped out.
    private func forget(_ window: AXWindow, in group: TabGroup, placeAt: CGRect?) {
        guard let index = group.memberIndex(of: window) else { return }
        unobserve(window)
        group.members.remove(at: index)
        windowIDs[window] = nil
        lastSpaceOf[window] = nil
        if let placeAt {
            FrameKeeper.shared.place(window, placeAt)
            window.focus()
        }
        reconcile(group, focusNext: false)
        save()
    }

    /// A member's window closed, or its app quit. The member stays remembered.
    private func windowGone(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window) else { return }
        Log.tabs.info("\(group.members[index].signature.appName, privacy: .public) window closed; \(group.displayName, privacy: .public) keeps remembering it")
        unobserve(window)
        windowIDs[window] = nil
        healedAt[window] = nil
        group.members[index].window = nil
        group.members[index].minimized = false
        group.members[index].hidden = false
        group.members[index].fullScreen = false
        group.members[index].elsewhere = false
        offscreenSince[window] = nil
        fullScreenLeftAt[window] = nil
        lastSpaceOf[window] = nil
        reconcile(group, focusNext: true)
    }

    /// A member's window went into macOS's own full screen, which moves it to a Space of its own. Its tab steps
    /// aside like a minimized one: the next tab takes over, and the other windows keep their size instead of
    /// following the window to full-screen size.
    private func windowEnteredFullScreen(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window), !group.members[index].fullScreen else { return }
        group.members[index].fullScreen = true
        fullScreenLeftAt[window] = nil
        FrameKeeper.shared.cancel(window)
        pendingSync[group.id]?.cancel()
        Log.tabs.notice("\(group.members[index].signature.appName, privacy: .public) went full screen: its tab steps aside until it leaves full screen")
        // Without focusing the next tab: that would pull the user back out of the full-screen Space.
        reconcile(group, focusNext: false)
    }

    /// Called on the tick for a member that is in full screen. Once its window has been out of full screen for
    /// a moment (macOS animates it back first), it rejoins as the active tab.
    private func checkFullScreenEnded(_ window: AXWindow, in group: TabGroup, at index: Int) {
        guard !window.isFullScreen else {
            fullScreenLeftAt[window] = nil
            return
        }
        let left = fullScreenLeftAt[window] ?? now
        fullScreenLeftAt[window] = left
        guard now - left >= 0.8 else { return }
        fullScreenLeftAt[window] = nil
        group.members[index].fullScreen = false
        Log.tabs.notice("\(group.members[index].signature.appName, privacy: .public) left full screen: back in \(group.displayName, privacy: .public)")
        layoutAfterJoin(group, newcomer: window, focus: true)
    }

    private func windowMinimized(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window), !group.members[index].minimized else { return }
        group.members[index].minimized = true
        reconcile(group, focusNext: true)
    }

    private func windowRestored(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window), group.members[index].minimized else { return }
        if group.collapsed {
            restoreGroup(group, from: window)
            return
        }
        group.members[index].minimized = false
        layoutAfterJoin(group, newcomer: window, focus: true)
    }

    /// One window of a minimized group came back from the Dock: bring the rest back too, stacked behind it.
    private func restoreGroup(_ group: TabGroup, from window: AXWindow) {
        group.collapsed = false
        var others: [AXWindow] = []
        for index in group.members.indices where group.members[index].minimized {
            group.members[index].minimized = false
            if let other = group.members[index].window, other != window { others.append(other) }
        }
        others.forEach { $0.setMinimized(false) }
        if group.isFormed {
            group.windows.forEach { FrameKeeper.shared.place($0, group.contentFrame) }
            activate(group, window: window)
        } else {
            layoutAfterJoin(group, newcomer: window, focus: true)
        }
        // The other windows finish their un-minimize animation after this one; keep the chosen tab in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                guard group.isFormed, group.active == window else { return }
                window.focus()
                TabGroupManager.shared.placeBars()
            }
        }
        Log.tabs.notice("Restored group \(group.displayName, privacy: .public)")
    }

    /// Re-checks a group after a window left it.
    private func reconcile(_ group: TabGroup, focusNext: Bool) {
        if group.members.count < 2 {
            // Nothing left to group with: forget the group.
            unform(group)
            group.members.compactMap(\.window).forEach { unobserve($0) }
            groups.removeAll { $0 === group }
            return
        }
        guard group.isFormed else { return }
        if !group.keepsBar {
            unform(group)
        } else if let next = group.active, next != group.activeWindow {
            // The visible tab left: show the next one.
            group.activeWindow = next
            if focusNext {
                activate(group, window: next)
            } else {
                FrameKeeper.shared.place(next, group.contentFrame)
                updateBar(group)
                placeBars()
            }
        } else {
            updateBar(group)
        }
    }

    private func save() {
        GroupStore.shared.save(groups.map(\.stored))
    }

    // MARK: - Auto-tabbing remembered windows

    private func appLaunched(_ pid: pid_t) {
        // Everything a freshly launched app opens counts as new.
        knownWindows[pid] = []
        unresponsiveUntil[pid] = nil
    }

    private func appTerminated(_ pid: pid_t) {
        for group in groups {
            for window in group.members.compactMap(\.window) where window.pid == pid {
                windowGone(window, in: group)
            }
        }
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        iconCache[pid] = nil
        knownWindows[pid] = nil
        unresponsiveUntil[pid] = nil
        firstSeen = firstSeen.filter { $0.key.pid != pid }
    }

    /// Finds newly opened windows that belong to a remembered group and tabs them in.
    private func scanForRememberedWindows() {
        guard Settings.autoTabRemembered else { return }
        let wanted = Set(groups.flatMap { $0.members.filter { $0.window == nil }.map(\.signature.bundleID) })
        guard !wanted.isEmpty else {
            knownWindows.removeAll()
            firstSeen.removeAll()
            return
        }

        let time = now
        var wantedPIDs = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier, wanted.contains(bundle) else { continue }
            let pid = app.processIdentifier
            guard pid != WindowQuery.ownPID else { continue }
            wantedPIDs.insert(pid)
            guard (unresponsiveUntil[pid] ?? 0) <= time else { continue }
            guard let windows = AXWindow.windowsIfResponsive(ofApp: pid) else {
                unresponsiveUntil[pid] = time + 5   // hung app: don't block on it every tick
                continue
            }

            // First look at an app that was already running: its open windows are not new.
            let baseline = knownWindows[pid] == nil && !restoring
            var known = (knownWindows[pid] ?? []).intersection(windows)
            for window in windows where !known.contains(window) {
                if baseline || boundGroup(of: window) != nil {
                    known.insert(window)
                    continue
                }
                let seen = firstSeen[window] ?? time
                firstSeen[window] = seen
                if time - seen > Self.claimPeriod {
                    known.insert(window)   // too late: it stays a floating window
                    firstSeen[window] = nil
                    continue
                }
                // Not ready yet (e.g. still appearing): try again next tick. A window in macOS's own full
                // screen may rejoin: it waits outside the bar until it leaves full screen.
                guard window.isStandardWindow, !window.isMinimized else { continue }
                if claim(window, focus: !restoring) {
                    known.insert(window)
                    firstSeen[window] = nil
                }
            }
            knownWindows[pid] = known
        }
        knownWindows = knownWindows.filter { wantedPIDs.contains($0.key) }
        firstSeen = firstSeen.filter { wantedPIDs.contains($0.key.pid) }
    }

    /// Binds `window` to the best-matching offline member of a remembered group.
    @discardableResult
    private func claim(_ window: AXWindow, focus: Bool) -> Bool {
        guard let bundle = window.bundleID else { return false }
        let title = window.title ?? ""
        let frame = window.frame

        var best: (group: TabGroup, index: Int, score: Int)?
        for group in groups {
            for (index, member) in group.members.enumerated()
            where member.window == nil && member.signature.bundleID == bundle {
                var score: Int
                if let hint = member.signature.titleHint {
                    guard WindowSignature.titlesMatch(title, hint) else { continue }
                    score = 4
                } else {
                    score = 1
                }
                // Prefer the group whose saved frame this window is sitting at.
                if let frame, frame.isClose(to: group.contentFrame, tolerance: 8)
                    || frame.isClose(to: group.outerFrame, tolerance: 8) {
                    score += 2
                }
                // Prefer groups with an open window to tab onto.
                if !group.windows.isEmpty { score += 1 }
                if score > (best?.score ?? 0) { best = (group, index, score) }
            }
        }
        guard let best else { return false }

        best.group.members[best.index].window = window
        observe(window)
        Log.tabs.notice("\"\(title, privacy: .public)\" rejoined remembered group \(best.group.displayName, privacy: .public)")
        claiming = true
        layoutAfterJoin(best.group, newcomer: window, focus: focus)
        claiming = false
        save()
        return true
    }

    // MARK: - Tab bar

    private func makeBar(for group: TabGroup) -> TabBarPanel {
        let id = group.id
        /// The group and window behind the bar's `index`-th tab (away tabs count).
        func lookup(_ index: Int) -> (TabGroup, AXWindow)? {
            guard let g = TabGroupManager.shared.groups.first(where: { $0.id == id }) else { return nil }
            let shown = g.barMembers
            guard shown.indices.contains(index), let window = g.members[shown[index]].window else { return nil }
            return (g, window)
        }
        return TabBarPanel(actions: TabBarActions(
            select: { index in
                guard let (g, w) = lookup(index), let m = g.memberIndex(of: w) else { return }
                switch g.members[m].away {
                case .otherDesktop?: TabGroupManager.shared.bringBack(w, to: g)
                case .fullScreen?: w.focus()   // takes the user to its full-screen space
                case nil: TabGroupManager.shared.activate(g, window: w)
                }
            },
            move: { from, to in
                guard let g = TabGroupManager.shared.groups.first(where: { $0.id == id }) else { return }
                TabGroupManager.shared.moveTab(in: g, from: from, to: to)
            },
            remove: { index in
                guard let (g, w) = lookup(index) else { return }
                // An away tab's window is on another desktop: leave it there.
                let live = g.windows.contains(w)
                TabGroupManager.shared.forget(w, in: g, placeAt: live ? g.outerFrame.offsetBy(dx: 40, dy: 40) : nil)
            },
            minimize: { index in
                guard let (_, w) = lookup(index) else { return }
                TabGroupManager.shared.minimizeTab(w)
            },
            closeWindow: { index in
                lookup(index)?.1.close()
            },
            tearOff: { index, cocoaPoint in
                guard let (g, w) = lookup(index) else { return }
                let live = g.windows.contains(w)
                TabGroupManager.shared.forget(w, in: g,
                                              placeAt: live ? Self.tearOffFrame(for: w, in: g, at: cocoaPoint) : nil)
            },
            minimizeGroup: {
                guard let g = TabGroupManager.shared.groups.first(where: { $0.id == id }) else { return }
                TabGroupManager.shared.minimize(g)
            },
            ungroup: {
                guard let g = TabGroupManager.shared.groups.first(where: { $0.id == id }) else { return }
                TabGroupManager.shared.ungroup(g)
            }))
    }

    /// Where a torn-off tab lands: same size, title bar under the cursor, kept on screen (AX coords).
    private static func tearOffFrame(for window: AXWindow, in group: TabGroup, at cocoaPoint: CGPoint) -> CGRect {
        let size = window.frame?.size ?? group.contentFrame.size
        let cursor = Geometry.axPoint(fromCocoa: cocoaPoint)
        var origin = CGPoint(x: cursor.x - min(120, size.width / 2), y: cursor.y - 12)
        if let screen = Geometry.screen(containingCocoa: cocoaPoint) {
            let visible = Geometry.toAX(screen.visibleFrame)
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - 40))
        }
        return CGRect(origin: origin, size: size)
    }

    private func updateBar(_ group: TabGroup) {
        guard let bar = group.bar else { return }
        bar.setFrame(ax: group.barFrame)
        let active = group.active
        var tabs: [TabItem] = []
        var hintsChanged = false
        for (index, member) in group.members.enumerated() {
            guard member.isShownInBar, let window = member.window else { continue }
            let app = NSRunningApplication(processIdentifier: window.pid)
            let liveTitle = window.title.flatMap { $0.isEmpty ? nil : $0 }
            if let liveTitle, let hint = member.signature.titleHint, liveTitle != hint {
                // Keep the latest title; titles that keep changing stop being used for matching.
                group.members[index].signature.titleChanges += 1
                group.members[index].signature.titleHint =
                    group.members[index].signature.titleChanges >= WindowSignature.volatileTitleThreshold ? nil : liveTitle
                hintsChanged = true
            }
            tabs.append(TabItem(id: tabs.count,
                                title: liveTitle ?? app?.localizedName ?? "Window",
                                icon: icon(for: window.pid, app: app),
                                isActive: window == active,
                                away: member.away))
        }
        if bar.model.tabs != tabs { bar.model.tabs = tabs }
        if hintsChanged { save() }
    }

    private func icon(for pid: pid_t, app: NSRunningApplication?) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let image = app?.icon
        iconCache[pid] = image
        return image
    }

    /// Called on a timer and on app switches: shows the bar only for the group the user is working in,
    /// keeps titles fresh, follows Cmd-Tab / clicks that focus a background tab, and auto-tabs
    /// remembered windows that just opened.
    func refresh() {
        // Asleep, displays off or locked: windows can't be read, so touch nothing (see SystemState).
        let state = SystemState.shared
        if state.isFrozen { return }
        // Carrying a group to another desktop: windows and desktops change on purpose for a few seconds.
        if DesktopMover.shared.isBusy { return }
        if state.isSettling {
            // Just woke or unlocked: keep every tab bar on its window, in case macOS reordered windows, but
            // decide nothing else until the screens have settled.
            placeBars(hideMissing: false)
            return
        }

        // Catch closed and un-minimized windows even if an AX notification was missed.
        for group in groups {
            for window in group.members.compactMap(\.window) {
                guard let index = group.memberIndex(of: window) else { continue }
                if window.isGone {
                    windowGone(window, in: group)
                } else if group.members[index].minimized, now >= minimizeGraceUntil, !window.isMinimized {
                    windowRestored(window, in: group)
                } else if group.members[index].fullScreen {
                    checkFullScreenEnded(window, in: group, at: index)
                } else if group.isFormed, window == group.active, window.isFullScreen {
                    // Only the visible tab is checked each tick: a hidden tab can't go full screen without
                    // being brought to the front (which makes it the visible tab) first.
                    windowEnteredFullScreen(window, in: group)
                }
            }
        }

        if !restorePendingUnlock { scanForRememberedWindows() }
        // Not while the mouse is down, nor right after it comes up: a window dragged to another display changes
        // desktop as it's dropped, and its tabs only follow once the drop has been handled.
        if NSEvent.pressedMouseButtons == 0,
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) > 0.3 {
            checkDesktops()
        }
        if now >= spaceSwitchUntil { checkHiddenWindows() }
        CloseButtonInterceptor.shared.updateTargets(groups)
        // A tab bar dragged to another desktop takes its group there (before placeBars, which would otherwise
        // bring the bar back to its windows).
        checkBarDesktops()
        servePendingDesktopMove()

        let formed = groups.filter(\.isFormed)
        guard !formed.isEmpty else { return }
        tickCount += 1
        let focused = WindowQuery.focusedWindow()
        let followFocus = now >= focusFollowPausedUntil
        for group in formed {
            if let focused, group.windows.contains(focused) {
                if focused != group.activeWindow, followFocus {
                    group.activeWindow = focused
                    FrameKeeper.shared.place(focused, group.contentFrame)
                }
                updateBar(group)
            }
        }
        // Not while the mouse is down: the user may be dragging or resizing a window right now.
        if NSEvent.pressedMouseButtons == 0 {
            formed.forEach { keepInPlace($0, checkHiddenTabs: tickCount % 3 == 0) }
        }
        placeBars(focused: focused)
    }

    /// Apps such as Postman, Teams or Slack hide a window when you close it, instead of closing it. Its tab
    /// stayed in the bar with nothing behind it, so the bar vanished and the group looked like loose windows.
    /// Now a member whose window has left the screen while a groupmate is still showing is treated like a
    /// minimized tab: the next tab takes over. When the app shows the window again, it comes back as the
    /// active tab. (A window on another Space, or of an app hidden with ⌘H, doesn't count.)
    private func checkHiddenWindows() {
        let onScreen = Set(WindowQuery.onScreenWindows().map(\.id))
        func showing(_ window: AXWindow) -> Bool { windowID(of: window).map(onScreen.contains) ?? true }
        let visibleDesktops = Spaces.visible()
        /// Off screen because it's on a desktop that isn't showing, not because its app hid it.
        func onOtherDesktop(_ window: AXWindow) -> Bool {
            guard !visibleDesktops.isEmpty, let id = windowID(of: window), let space = Spaces.space(of: id) else {
                return false
            }
            return !visibleDesktops.contains(space)
        }
        let time = now
        for group in groups {
            for index in group.members.indices {
                guard index < group.members.count, let window = group.members[index].window,
                      !group.members[index].minimized, !group.members[index].fullScreen,
                      !group.members[index].elsewhere else { continue }
                if group.members[index].hidden {
                    guard showing(window) else { continue }
                    group.members[index].hidden = false
                    Log.tabs.notice("\(group.members[index].signature.appName, privacy: .public) showed its window again: back in \(group.displayName, privacy: .public)")
                    layoutAfterJoin(group, newcomer: window, focus: true)
                    continue
                }
                let groupmateShowing = group.windows.contains { $0 != window && showing($0) }
                let appHidden = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false
                guard group.isFormed, groupmateShowing, !showing(window), !appHidden, !window.isMinimized,
                      !onOtherDesktop(window) else {
                    offscreenSince[window] = nil
                    continue
                }
                // Make sure it's not a window list caught mid-update.
                let since = offscreenSince[window] ?? time
                offscreenSince[window] = since
                guard time - since >= 0.6 else { continue }
                offscreenSince[window] = nil
                group.members[index].hidden = true
                Log.tabs.notice("\(group.members[index].signature.appName, privacy: .public) hid its window instead of closing it: its tab steps aside until it's shown again")
                reconcile(group, focusNext: true)
            }
        }
    }

    /// A group lives on one desktop (Space): the one it was carried to on purpose, else the one holding most of
    /// its open windows (on a tie, the visible tab's). A member whose window is on another desktop (say, the
    /// user dragged it there in Mission Control) becomes an away tab: dimmed in the bar, and clicking it carries
    /// the window over (`bringBack`). It's a normal tab again once its window is on the group's desktop. So
    /// dragging a group's windows to another desktop one by one also moves the group there.
    ///
    /// It never focuses a window on another desktop here: before this check, a moved window was taken for one
    /// its app had hidden, and bringing it back focused it, which made macOS jump between desktops.
    private func checkDesktops() {
        for group in groups {
            var spaceOf: [AXWindow: UInt64] = [:]
            var moving = false
            for member in group.members {
                guard let window = member.window, !member.minimized, !member.hidden, !member.fullScreen else { continue }
                // Being placed right now (moving to another display can change its desktop): look again later.
                if FrameKeeper.shared.isPlacing(window) { moving = true; break }
                if let id = windowID(of: window), let space = Spaces.space(of: id) { spaceOf[window] = space }
            }
            guard !moving, !isWaitingToMove(group) else { continue }
            // Where each window was last time, to tell a window the user just moved from one left behind.
            let previousSpaces = lastSpaceOf
            let previousHome = lastHome[group.id]
            for (window, space) in spaceOf { lastSpaceOf[window] = space }
            guard Set(spaceOf.values).count > 1 || group.members.contains(where: \.elsewhere) else {
                if let only = spaceOf.values.first { lastHome[group.id] = only }
                continue
            }

            // A window the user moved from the group's desktop to another desktop (in Mission Control, or by
            // switching desktops while holding it) takes the whole group along.
            if group.isFormed, Settings.dragBarMovesGroup,
               let moved = DesktopMovePlan.movedAway(group.windows, before: previousSpaces, now: spaceOf,
                                                     home: previousHome),
               let target = spaceOf[moved], Spaces.layout().space(target)?.isDesktop == true {
                pendingDesktopMoves[group.id] = PendingDesktopMove(target: target, reason: .windowMoved, since: now,
                                                                   show: moved)
                Log.tabs.notice("A window of \(group.displayName, privacy: .public) was moved to desktop \(target, privacy: .public): the group follows it")
                continue
            }

            // A group carried to another desktop on purpose lives there while any of its windows is there,
            // even when more of them stayed behind.
            if let pinned = pinnedHome[group.id], !spaceOf.values.contains(pinned) { pinnedHome[group.id] = nil }
            guard let home = pinnedHome[group.id]
                    ?? Spaces.home(of: Array(spaceOf.values), visibleTab: group.active.flatMap { spaceOf[$0] })
            else { continue }
            lastHome[group.id] = home

            var left: [String] = []
            var cameBack: [AXWindow] = []
            for index in group.members.indices {
                guard let window = group.members[index].window, let space = spaceOf[window] else { continue }
                if group.members[index].elsewhere, space == home {
                    group.members[index].elsewhere = false
                    cameBack.append(window)
                } else if !group.members[index].elsewhere, space != home {
                    group.members[index].elsewhere = true
                    FrameKeeper.shared.cancel(window)
                    left.append(group.members[index].signature.appName)
                }
            }
            if !left.isEmpty {
                Log.tabs.notice("\(left.joined(separator: ", "), privacy: .public) on another desktop than the rest of \(group.displayName, privacy: .public): out of the bar until they're on the same desktop again")
                pendingSync[group.id]?.cancel()
                reconcile(group, focusNext: false)
            }
            for window in cameBack where group.windows.contains(window) {
                Log.tabs.notice("A window of \(group.displayName, privacy: .public) is on the group's desktop again: back in the bar")
                layoutAfterJoin(group, newcomer: window, focus: false)
            }
            if !left.isEmpty || !cameBack.isEmpty { desktopToast(for: group, split: !left.isEmpty) }
        }
    }

    /// Says what happened when the user moved a group's window to another desktop (not at launch).
    private func desktopToast(for group: TabGroup, split: Bool) {
        guard now - startedAt > 5, now - lastDesktopToastAt > 3 else { return }
        if split {
            lastDesktopToastAt = now
            Toast.shared.show("Tab group split across desktops",
                              detail: "Tabs on another desktop are dimmed. Click one to bring its window here.")
        } else if !group.members.contains(where: \.elsewhere) {
            lastDesktopToastAt = now
            Toast.shared.show("Tabs back together", detail: group.displayName)
        }
    }

    /// Self-check: keeps a group's windows stacked and its bar clear of the windows, even when an app moved
    /// a window on its own, ignored a frame change, or an Accessibility notification was missed.
    private func keepInPlace(_ group: TabGroup, checkHiddenTabs: Bool) {
        guard let active = group.active, !FrameKeeper.shared.isPlacing(active),
              let frame = active.frame else { return }
        var changed = false
        if !frame.isRoughly(group.contentFrame) {
            // The visible tab moved or resized: the group follows it, keeping room for the bar.
            group.contentFrame = fitted(frame)
            if !group.contentFrame.isRoughly(frame) { heal(active, to: group.contentFrame) }
            changed = true
        } else if !fitted(group.contentFrame).isRoughly(group.contentFrame) {
            // No room for the bar above the windows (e.g. the window was zoomed to full height).
            group.contentFrame = fitted(group.contentFrame)
            heal(active, to: group.contentFrame)
            changed = true
        }
        if changed || checkHiddenTabs {
            for window in group.windows where window != active && !FrameKeeper.shared.isPlacing(window) {
                if let f = window.frame, !f.isRoughly(group.contentFrame) {
                    heal(window, to: group.contentFrame)
                }
            }
        }
        if changed {
            group.bar?.setFrame(ax: group.barFrame)
            save()
        }
        checkStillFilled(group)
    }

    private func heal(_ window: AXWindow, to rect: CGRect) {
        // Back off from a window that keeps refusing (e.g. its app enforces a minimum size).
        if let last = healedAt[window], now - last < 5 { return }
        healedAt[window] = now
        let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
        Log.tabs.notice("Re-stacking \(app, privacy: .public) window into its group")
        FrameKeeper.shared.place(window, rect)
    }

    /// Moves `content` down if needed so the tab bar fits between it and the menu bar (AX coords).
    private func fitted(_ content: CGRect) -> CGRect {
        guard let screen = Geometry.screen(forAX: content) else { return content }
        let visible = Geometry.toAX(screen.visibleFrame)
        let top = visible.minY + TabBarPanel.height
        guard content.minY < top - 0.5 else { return content }
        var fitted = content
        fitted.origin.y = top
        fitted.size.height = max(200, content.maxY - top)
        return fitted
    }

    /// Shows every formed group's bar whose visible window is on screen (on this Space), ordered directly
    /// above that window, and hides the others (unless `hideMissing` is false: right after waking, a window
    /// can be missing from the window list for a moment).
    ///
    /// A bar that is up on another desktop (Space) stays there: its group lives on that desktop, so when the
    /// user swipes back, the bar slides in with it instead of popping up after the swipe.
    func placeBars(focused: AXWindow? = nil, hideMissing: Bool = true) {
        guard !DesktopMover.shared.isBusy else { return }
        let formed = groups.filter(\.isFormed)
        guard !formed.isEmpty else { return }
        let onScreen = WindowQuery.onScreenWindows()
        var index: [CGWindowID: Int] = [:]
        for (i, w) in onScreen.enumerated() { index[w.id] = i }
        let focusedWindow = focused ?? WindowQuery.focusedWindow()

        for group in formed {
            guard let bar = group.bar else { continue }
            // Waiting to follow its bar to another desktop (or being carried there): leave the bar where the
            // user put it. When the bar and its visible tab aren't both on screen here, check first whether the
            // bar was just dragged to another desktop in Mission Control.
            if isWaitingToMove(group) { continue }
            let activeOnScreen = group.active.flatMap { windowID(of: $0) }.flatMap { index[$0] } != nil
            if bar.isVisible && (!bar.isShowingHere || !activeOnScreen) && checkBarDesktop(group) { continue }
            guard let active = group.active, let wid = windowID(of: active), let windowIndex = index[wid] else {
                // Not on screen here. On this desktop that means minimized, hidden or closed: hide the bar.
                // Also hide a bar that ended up on another desktop than its window (dragged there in Mission
                // Control): it's shown again next to its window when that desktop is on screen.
                let strayed = bar.isVisible && group.active.flatMap { windowID(of: $0) }
                    .map { Self.onDifferentDesktops(bar.windowNumber, $0) } == true
                if hideMissing && (bar.isShowingHere || strayed) { bar.hide() }
                continue
            }
            bar.setFrame(ax: group.barFrame)
            bar.setFocused(focusedWindow.map { group.windows.contains($0) } ?? false)
            // Already directly above its window? (CGWindowList is ordered front to back.)
            let barIndex = index[CGWindowID(bar.windowNumber)]
            if !bar.isVisible || barIndex != windowIndex - 1 {
                bar.show(above: wid)
            }
        }
    }

    /// Whether macOS puts two windows on different desktops (false when it doesn't say for either).
    private static func onDifferentDesktops(_ barNumber: Int, _ window: CGWindowID) -> Bool {
        guard barNumber > 0, let barSpace = Spaces.space(of: CGWindowID(barNumber)),
              let windowSpace = Spaces.space(of: window) else { return false }
        return barSpace != windowSpace
    }

    // MARK: - Moving a group to another desktop

    private enum DesktopMoveReason {
        /// The user dragged the tab bar to another desktop in Mission Control.
        case barDragged
        /// The group re-formed from remembered windows on another desktop than the one it was saved on.
        case restore
        /// The user clicked an away tab.
        case bringBack
        /// The user moved one of the group's windows to another desktop.
        case windowMoved
    }

    private struct PendingDesktopMove {
        let target: UInt64
        let reason: DesktopMoveReason
        let since: TimeInterval
        /// The tab to show once there (default: the visible one).
        var show: AXWindow? = nil
    }

    /// A move that still hasn't started after this long (the mouse held or clicking all along) is dropped, and the bar goes back to its windows, so it's never stranded alone on a desktop.
    private static let pendingMoveTimeout: TimeInterval = 20

    /// Groups waiting to be carried to another desktop (until nothing is held or clicked).
    private var pendingDesktopMoves: [UUID: PendingDesktopMove] = [:]
    /// Groups being carried right now.
    private var movingGroups: Set<UUID> = []
    /// The desktop each bar was last seen on together with its windows.
    private var lastBarSpace: [UUID: UInt64] = [:]
    /// The desktop each group was last remembered on (saves looking up its UUID every tick).
    private var rememberedSpace: [UUID: UInt64] = [:]
    /// The desktop a group was carried to on purpose: it stays the group's desktop while any of its windows is
    /// there, even when more of them stayed behind.
    private var pinnedHome: [UUID: UInt64] = [:]
    /// True while a remembered window is being claimed: a group that re-forms then goes back to its desktop.
    private var claiming = false
    /// When the desktop on screen last changed.
    private var lastSpaceChangeAt: TimeInterval = 0
    /// Each group's desktop, and each grouped window's desktop, as last seen by `checkDesktops`.
    private var lastHome: [UUID: UInt64] = [:]
    private var lastSpaceOf: [AXWindow: UInt64] = [:]

    private func isWaitingToMove(_ group: TabGroup) -> Bool {
        movingGroups.contains(group.id) || pendingDesktopMoves[group.id] != nil
    }

    /// The desktop of a group's open windows (see `Spaces.home`), preferring the one it was carried to.
    private func homeDesktop(of group: TabGroup) -> UInt64? {
        var spaces: [UInt64] = []
        var visible: UInt64?
        for window in group.windows {
            guard let id = windowID(of: window), let space = Spaces.space(of: id) else { continue }
            spaces.append(space)
            if window == group.active { visible = space }
        }
        if let pinned = pinnedHome[group.id], spaces.contains(pinned) { return pinned }
        return Spaces.home(of: spaces, visibleTab: visible)
    }

    /// "Desktop 2", for the menu.
    func desktopName(of group: TabGroup) -> String? {
        group.desktop.map { "Desktop \($0.number)" }
    }

    /// On every tick and whenever the desktop on screen changes: was a tab bar dragged to another desktop in
    /// Mission Control? Then its group follows it there. Also remembers each group's desktop.
    private func checkBarDesktops() {
        for group in groups where group.isFormed && !movingGroups.contains(group.id) {
            checkBarDesktop(group)
        }
    }

    /// Returns true while the group waits to be carried to another desktop.
    @discardableResult
    private func checkBarDesktop(_ group: TabGroup) -> Bool {
        guard let bar = group.bar, bar.isVisible, let barSpace = Spaces.space(of: CGWindowID(bar.windowNumber)),
              let home = homeDesktop(of: group) else { return pendingDesktopMoves[group.id] != nil }
        switch DesktopMovePlan.barCheck(barSpace: barSpace, lastBarSpace: lastBarSpace[group.id], home: home) {
        case .together:
            lastBarSpace[group.id] = barSpace
            if pendingDesktopMoves[group.id]?.reason == .barDragged {
                pendingDesktopMoves[group.id] = nil
                Log.tabs.notice("The tab bar of \(group.displayName, privacy: .public) is back with its windows: the group stays")
            }
            rememberDesktop(home, of: group)
        case .windowsMoved:
            break   // the visible tab went to another desktop: placeBars brings the bar along
        case .barMoved(let target):
            if pendingDesktopMoves[group.id]?.target != target {
                pendingDesktopMoves[group.id] = PendingDesktopMove(target: target, reason: .barDragged, since: now)
                Log.tabs.notice("The tab bar of \(group.displayName, privacy: .public) was moved to desktop \(target, privacy: .public) (its windows are on \(home, privacy: .public)): the group follows it")
            }
        }
        return pendingDesktopMoves[group.id] != nil
    }

    /// Saves the group's desktop when it changes.
    private func rememberDesktop(_ space: UInt64, of group: TabGroup) {
        guard rememberedSpace[group.id] != space else { return }
        rememberedSpace[group.id] = space
        guard let stored = Spaces.layout().stored(space), stored != group.desktop else { return }
        group.desktop = stored
        save()
    }

    /// A group re-formed from remembered windows: if they opened on another desktop than the group's own, carry
    /// them back there.
    private func scheduleDesktopRestore(_ group: TabGroup) {
        guard Settings.dragBarMovesGroup, let stored = group.desktop,
              let target = Spaces.layout().space(matching: stored),
              let home = homeDesktop(of: group), home != target else { return }
        pendingDesktopMoves[group.id] = PendingDesktopMove(target: target, reason: .restore, since: now)
        Log.tabs.notice("\(group.displayName, privacy: .public) re-formed on desktop \(home, privacy: .public), but it was on Desktop \(stored.number, privacy: .public): taking it back there")
    }

    /// Starts a waiting move once it's safe to drag with the mouse for the user: they aren't holding or clicking
    /// the mouse, or typing.
    private func servePendingDesktopMove() {
        guard !DesktopMover.shared.isBusy, let next = pendingDesktopMoves.first else { return }
        let pending = next.value
        guard let group = group(withID: next.key), group.isFormed else {
            pendingDesktopMoves[next.key] = nil
            return
        }
        func idle(_ type: CGEventType) -> Bool {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) > 0.3
        }
        // Nothing held, no click or key press just now, and no desktop sliding in. (Moving the mouse is fine:
        // DesktopMover drags with it, in Mission Control when that's open.)
        guard NSEvent.pressedMouseButtons == 0, idle(.leftMouseDown), idle(.leftMouseUp),
              idle(.keyDown), now - lastSpaceChangeAt > 0.4 else {
            if now - pending.since > Self.pendingMoveTimeout {
                Log.tabs.error("Gave up moving \(group.displayName, privacy: .public) to desktop \(pending.target, privacy: .public): no quiet moment to do it in \(Int(Self.pendingMoveTimeout), privacy: .public)s")
                if pending.reason == .barDragged { returnBar(group, problem: nil) } else {
                    pendingDesktopMoves[group.id] = nil
                    placeBars()
                }
            }
            return
        }
        pendingDesktopMoves[group.id] = nil

        guard Settings.dragBarMovesGroup else {
            Log.tabs.notice("Moving groups with their tab bar is off: \(group.displayName, privacy: .public)'s bar goes back")
            returnBar(group, problem: nil)
            return
        }
        // For a window that was moved away, the others are still on the group's old desktop.
        let home = pending.reason == .windowMoved ? (lastHome[group.id] ?? homeDesktop(of: group))
                                                  : homeDesktop(of: group)
        guard let home else {
            returnBar(group, problem: nil)
            return
        }
        let layout = Spaces.layout()
        switch DesktopMovePlan.decide(home: home, target: pending.target, layout: layout) {
        case .impossible(let problem):
            Log.tabs.error("Can't move \(group.displayName, privacy: .public) to desktop \(pending.target, privacy: .public): \(problem.message, privacy: .public)")
            switch pending.reason {
            case .barDragged:
                returnBar(group, problem: problem)
            case .windowMoved:
                // The moved window stays where the user put it, as an away tab; the rest stays here.
                Toast.shared.show("Couldn't bring the rest of the tab group along", detail: problem.message)
                placeBars()
            case .restore, .bringBack:
                placeBars()   // restore: it just stays where it opened
            }
        case .carry:
            carry(group, to: pending.target, reason: pending.reason, layout: layout, show: pending.show)
        }
    }

    /// Carries every open window of the group (away ones too) to desktop `target`, the visible tab last.
    /// Windows in full screen can't be carried: they stay away tabs.
    private func carry(_ group: TabGroup, to target: UInt64, reason: DesktopMoveReason, layout: DesktopLayout,
                       show: AXWindow? = nil) {
        var items: [DesktopMover.Item] = []
        for member in group.members {
            guard let window = member.window, member.isLive || member.elsewhere, let id = windowID(of: window) else {
                if member.fullScreen {
                    Log.tabs.notice("\(member.signature.appName, privacy: .public) is in full screen: it can't be carried, its tab stays away")
                }
                continue
            }
            items.append(DesktopMover.Item(window: window, id: id, name: member.signature.appName))
        }
        let active = show ?? group.active
        let ordered = DesktopMovePlan.carryOrder(items, active: items.first { $0.window == active })
        let number = layout.desktopNumber(of: target)
        let destination = number.map { "Desktop \($0)" } ?? "the other desktop"
        // Where the user is now: they're brought back here afterwards.
        let returnTo = layout.current(onDisplayOf: target)

        movingGroups.insert(group.id)
        Log.tabs.notice("Carrying \(ordered.count, privacy: .public) window(s) of \(group.displayName, privacy: .public) to \(destination, privacy: .public) (desktop \(target, privacy: .public))")
        Toast.shared.show(reason == .restore ? "Putting the tab group back on \(destination)…"
                                             : "Moving the tab group to \(destination)…",
                          detail: "Paneful drags each window there in Mission Control. A click or key press stops it.")
        Task { @MainActor in
            let report = await DesktopMover.shared.carry(ordered, to: target, returnTo: returnTo)
            TabGroupManager.shared.finishCarry(group, to: target, report: report, show: active,
                                               reason: reason, destination: destination)
        }
    }

    /// Clicking an away tab: its window is on another desktop. Carries it to the group's desktop, and shows it.
    func bringBack(_ window: AXWindow, to group: TabGroup) {
        guard !DesktopMover.shared.isBusy, !isWaitingToMove(group), let index = group.memberIndex(of: window),
              let id = windowID(of: window), let source = Spaces.space(of: id),
              let home = homeDesktop(of: group) else { return }
        guard source != home else { return }   // already here: the next desktop check brings it in
        let layout = Spaces.layout()
        if case .impossible(let problem) = DesktopMovePlan.decide(home: source, target: home, layout: layout) {
            Log.tabs.error("Can't bring \(group.members[index].signature.appName, privacy: .public) back: \(problem.message, privacy: .public)")
            Toast.shared.show("Couldn't bring that tab here", detail: problem.message)
            return
        }
        let item = DesktopMover.Item(window: window, id: id, name: group.members[index].signature.appName)
        let returnTo = layout.current(onDisplayOf: home)
        movingGroups.insert(group.id)
        Log.tabs.notice("Bringing \(item.name, privacy: .public) back from desktop \(source, privacy: .public) to \(group.displayName, privacy: .public) on \(home, privacy: .public)")
        Task { @MainActor in
            let report = await DesktopMover.shared.carry([item], to: home, returnTo: returnTo)
            TabGroupManager.shared.finishCarry(group, to: home, report: report, show: window,
                                               reason: .bringBack, destination: "this desktop")
        }
    }

    /// After carrying: windows that arrived are tabs again, the others are away tabs (logged and named in a
    /// toast). If nothing arrived, the bar goes back to the windows.
    private func finishCarry(_ group: TabGroup, to target: UInt64, report: DesktopMover.Report, show: AXWindow?,
                             reason: DesktopMoveReason, destination: String) {
        movingGroups.remove(group.id)
        spaceSwitchUntil = now + 1
        offscreenSince.removeAll()
        for failure in report.failed {
            Log.tabs.error("Desktop move: \(failure.name, privacy: .public) wasn't moved: \(failure.reason, privacy: .public)")
        }
        guard groups.contains(where: { $0 === group }), group.isFormed else {
            placeBars()
            return
        }
        // Judge by where the windows are now, not by the report: an app can start a drag late, so a window
        // Paneful gave up on may still have been carried.
        let spaceOf: (AXWindow) -> UInt64? = { [self] window in windowID(of: window).flatMap(Spaces.space(of:)) }
        let arrived = group.members.filter { member in
            guard let window = member.window, !member.minimized, !member.hidden, !member.fullScreen else { return false }
            return spaceOf(window) == target && (reason != .bringBack || window == show)
        }
        if arrived.count != report.moved.count {
            Log.tabs.notice("Desktop move: \(arrived.count, privacy: .public) window(s) are on the new desktop, \(report.moved.count, privacy: .public) were counted as carried")
        }
        guard !arrived.isEmpty else {
            if reason == .bringBack {
                Toast.shared.show("Couldn't bring that tab here", detail: report.failed.first.map { "\($0.name): \($0.reason)." })
                placeBars()
            } else {
                // Nothing arrived: the group stays where it was, and so does its bar.
                returnBar(group, problem: nil)
                Toast.shared.show("Couldn't move the tab group", detail: report.failed.first.map { "\($0.name): \($0.reason)." })
            }
            return
        }

        pinnedHome[group.id] = target
        lastBarSpace[group.id] = target
        let leftBehind = group.settle(on: target, spaceOf: spaceOf)
        if let show, group.windows.contains(show) { group.activeWindow = show }
        if let bar = group.bar { Spaces.moveOwnWindow(bar.windowNumber, to: target) }
        for window in group.windows {
            if let frame = window.frame, !frame.isRoughly(group.contentFrame) {
                FrameKeeper.shared.place(window, group.contentFrame)
            }
        }
        reconcile(group, focusNext: false)
        if group.isFormed {
            updateBar(group)
            // Only when the user is looking at that desktop: focusing a window elsewhere jumps desktops.
            if Spaces.visible().contains(target), let active = group.active {
                focusFollowPausedUntil = now + 0.6
                active.focus()
            }
        }
        placeBars()
        rememberDesktop(target, of: group)
        rememberSpaces(of: group)
        save()

        // Still on another desktop after the move (the report can be wrong both ways, see above).
        let missed = group.members.filter { $0.elsewhere && $0.window != nil }.map(\.signature.appName)
        if !leftBehind.isEmpty {
            Log.tabs.notice("Away on another desktop after the move: \(leftBehind.joined(separator: ", "), privacy: .public)")
        }
        switch reason {
        case .bringBack:
            break
        case .barDragged, .restore, .windowMoved:
            if missed.isEmpty {
                Toast.shared.show("Tab group moved to \(destination)", detail: group.displayName)
            } else {
                let reasonText = report.failed.first { missed.contains($0.name) }.map { " (\($0.reason))" } ?? ""
                Toast.shared.show("Moved to \(destination), except \(missed.joined(separator: ", "))\(reasonText)",
                                  detail: "Their tabs are dimmed. Click one to try again.")
            }
        }
    }

    /// Notes where a group's windows are now, after Paneful moved some: `checkDesktops` must not take them for
    /// windows the user moved (and send the group after them).
    private func rememberSpaces(of group: TabGroup) {
        for window in group.members.compactMap(\.window) {
            if let space = windowID(of: window).flatMap(Spaces.space(of:)) { lastSpaceOf[window] = space }
        }
        lastHome[group.id] = pinnedHome[group.id] ?? homeDesktop(of: group)
    }

    /// Puts a group's bar back on its windows' desktop (Paneful can move its own windows between desktops), so
    /// a bar is never left alone on a desktop.
    private func returnBar(_ group: TabGroup, problem: DesktopMovePlan.Problem?) {
        pendingDesktopMoves[group.id] = nil
        if let bar = group.bar, let home = homeDesktop(of: group) {
            Spaces.moveOwnWindow(bar.windowNumber, to: home)
            lastBarSpace[group.id] = home
            Log.tabs.notice("The tab bar of \(group.displayName, privacy: .public) went back to its windows on desktop \(home, privacy: .public)")
        }
        if let problem { Toast.shared.show("Couldn't move the tab group", detail: problem.message) }
        rememberSpaces(of: group)
        placeBars()
    }

    /// While the user drags a group's visible window: keep the bar glued to it (AX coords origin).
    func follow(_ group: TabGroup, windowOrigin: CGPoint) {
        guard group.isFormed else { return }
        group.contentFrame.origin = windowOrigin
        group.bar?.setFrame(ax: group.barFrame)
    }

    /// The user let go of a group's window: settle the group where it landed and bring the hidden tabs.
    func dragEnded(_ group: TabGroup) {
        guard group.isFormed, let active = group.active, let frame = active.frame else { return }
        group.contentFrame = fitted(frame)
        if !group.contentFrame.isRoughly(frame) { FrameKeeper.shared.place(active, group.contentFrame) }
        for window in group.windows where window != active {
            FrameKeeper.shared.place(window, group.contentFrame)
        }
        pendingSync[group.id]?.cancel()
        updateBar(group)
        placeBars()
        save()
    }

    // MARK: - AX observation

    fileprivate func handle(element: AXUIElement, notification: String) {
        // Carrying windows to another desktop: their moves are Paneful's own (the tick catches anything else).
        guard !DesktopMover.shared.isBusy else { return }
        guard let group = groups.first(where: { g in
                  g.members.contains { $0.window.map { CFEqual($0.element, element) } ?? false }
              }),
              let window = group.members.lazy.compactMap(\.window).first(where: { CFEqual($0.element, element) })
        else { return }

        switch notification {
        case kAXUIElementDestroyedNotification:
            windowGone(window, in: group)

        case kAXWindowMiniaturizedNotification:
            windowMinimized(window, in: group)

        case kAXWindowDeminiaturizedNotification:
            windowRestored(window, in: group)

        case kAXMovedNotification, kAXResizedNotification:
            // Only the visible (active) window drives the group; the others are moved by us. Frames seen
            // while Paneful itself is placing the window are in-between states: ignore them. So are moves
            // while the screens wake up or change (macOS shuffles windows then; the group is put back after),
            // unless the mouse is down: that's the user dragging or resizing.
            guard group.isFormed, window == group.active, !FrameKeeper.shared.isPlacing(window),
                  !SystemState.shared.isFrozen,
                  !SystemState.shared.isSettling || NSEvent.pressedMouseButtons != 0,
                  let frame = window.frame, !frame.isClose(to: group.contentFrame, tolerance: 0.5) else { return }
            if window.isFullScreen {
                // Not a move: it went into macOS's own full screen. The other tabs must not follow it there.
                windowEnteredFullScreen(window, in: group)
                return
            }
            if NSEvent.pressedMouseButtons != 0 {
                // Mid-drag or mid-resize: follow as-is; dragEnded/keepInPlace settle it afterwards.
                group.contentFrame = frame
            } else {
                group.contentFrame = fitted(frame)
                if !group.contentFrame.isRoughly(frame) { FrameKeeper.shared.place(window, group.contentFrame) }
            }
            group.bar?.setFrame(ax: group.barFrame)
            scheduleSync(group)

        default:
            break
        }
    }

    /// After the user stops moving the active window, bring the hidden tabs along.
    private func scheduleSync(_ group: TabGroup) {
        pendingSync[group.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak group] in
            MainActor.assumeIsolated {
                guard let self, let group, group.isFormed, self.groups.contains(where: { $0 === group }) else { return }
                // Still dragging: the drag end (or the next notification) syncs instead.
                guard NSEvent.pressedMouseButtons == 0 else { return }
                let active = group.active
                for window in group.windows where window != active {
                    FrameKeeper.shared.place(window, group.contentFrame)
                }
                self.save()
            }
        }
        pendingSync[group.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func observer(for pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let observer = created else {
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        return observer
    }

    private func observe(_ window: AXWindow) {
        guard let observer = observer(for: window.pid) else { return }
        for name in Self.watched {
            AXObserverAddNotification(observer, window.element, name as CFString, nil)
        }
    }

    private func unobserve(_ window: AXWindow) {
        guard let observer = observers[window.pid] else { return }
        for name in Self.watched {
            AXObserverRemoveNotification(observer, window.element, name as CFString)
        }
    }
}

/// AXObserver C callback (must be a plain global function). Delivered on the main run loop.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    let name = notification as String
    MainActor.assumeIsolated {
        TabGroupManager.shared.handle(element: element, notification: name)
    }
}
