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

        var isLive: Bool { window != nil && !minimized && !hidden }
    }

    let id: UUID
    var members: [Member]
    var activeWindow: AXWindow?
    /// The whole group was minimized with "Minimize Group": restoring any of its windows restores all.
    var collapsed = false
    /// Frame (AX coords) shared by every window in the group. The tab bar sits directly above it.
    var contentFrame: CGRect
    var bar: TabBarPanel?

    init(id: UUID = UUID(), members: [Member], contentFrame: CGRect) {
        self.id = id
        self.members = members
        self.contentFrame = contentFrame
    }

    var isFormed: Bool { bar != nil }

    /// Live, un-minimized windows in tab order.
    var windows: [AXWindow] { members.compactMap { $0.isLive ? $0.window : nil } }

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
        StoredGroup(id: id, members: members.map(\.signature), contentFrame: contentFrame)
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
        groups = GroupStore.shared.load().map { stored in
            TabGroup(id: stored.id,
                     members: stored.members.map { TabGroup.Member(signature: $0) },
                     contentFrame: stored.contentFrame)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TabGroupManager.shared.refresh() }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let manager = TabGroupManager.shared
                manager.spaceSwitchUntil = manager.now + 1
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
            // Only if that spot is still on a connected display; otherwise follow the window as usual.
            guard let screen = Geometry.screen(forAX: group.contentFrame),
                  Geometry.toAX(screen.frame).intersection(group.contentFrame).area >= group.contentFrame.area / 2
            else { continue }
            group.contentFrame = fitted(group.contentFrame)
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

    /// The group whose (visible) tab bar is under an AX-space point.
    func group(withVisibleBarAtAX point: CGPoint) -> TabGroup? {
        groups.first { ($0.bar?.isVisible ?? false) && $0.barFrame.contains(point) }
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

    /// Moves a tab to another position in the bar (`from`/`to` count live tabs, left to right). Closed and
    /// minimized members keep their place in between. The new order is remembered.
    func moveTab(in group: TabGroup, from: Int, to: Int) {
        guard let reordered = group.members.movingLive(from: from, to: to, isLive: \.isLive) else { return }
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
        var content = outer
        content.origin.y += TabBarPanel.height
        content.size.height -= TabBarPanel.height
        group.contentFrame = fitted(content)
        group.windows.forEach { FrameKeeper.shared.place($0, group.contentFrame) }
        if focus { group.active?.focus() }
        updateBar(group)
        placeBars()
        save()
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
        let live = group.windows
        guard live.count >= 2 else { return }   // alone: it floats until another member opens

        if !group.isFormed {
            // Form around a window that was already on screen, not the newcomer.
            guard let anchor = live.first(where: { $0 != newcomer }), let frame = anchor.frame else { return }
            form(group, around: frame, active: anchor)
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
    }

    /// Removes a window from a group for good. `placeAt` (AX) moves and focuses it, e.g. when popped out.
    private func forget(_ window: AXWindow, in group: TabGroup, placeAt: CGRect?) {
        guard let index = group.memberIndex(of: window) else { return }
        unobserve(window)
        group.members.remove(at: index)
        windowIDs[window] = nil
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
        offscreenSince[window] = nil
        reconcile(group, focusNext: true)
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
        if group.windows.count < 2 {
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
                // Not ready yet (e.g. still appearing): try again next tick.
                guard window.isStandardWindow, !window.isMinimized, !window.isFullScreen else { continue }
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
        layoutAfterJoin(best.group, newcomer: window, focus: focus)
        save()
        return true
    }

    // MARK: - Tab bar

    private func makeBar(for group: TabGroup) -> TabBarPanel {
        let id = group.id
        func lookup(_ index: Int) -> (TabGroup, AXWindow)? {
            guard let g = TabGroupManager.shared.groups.first(where: { $0.id == id }) else { return nil }
            let live = g.windows
            return live.indices.contains(index) ? (g, live[index]) : nil
        }
        return TabBarPanel(actions: TabBarActions(
            select: { index in
                guard let (g, w) = lookup(index) else { return }
                TabGroupManager.shared.activate(g, window: w)
            },
            move: { from, to in
                guard let g = TabGroupManager.shared.groups.first(where: { $0.id == id }) else { return }
                TabGroupManager.shared.moveTab(in: g, from: from, to: to)
            },
            remove: { index in
                guard let (g, w) = lookup(index) else { return }
                TabGroupManager.shared.forget(w, in: g, placeAt: g.outerFrame.offsetBy(dx: 40, dy: 40))
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
                TabGroupManager.shared.forget(w, in: g, placeAt: Self.tearOffFrame(for: w, in: g, at: cocoaPoint))
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
            guard member.isLive, let window = member.window else { continue }
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
                                isActive: window == active))
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
                }
            }
        }

        if !restorePendingUnlock { scanForRememberedWindows() }
        if now >= spaceSwitchUntil { checkHiddenWindows() }
        CloseButtonInterceptor.shared.updateTargets(groups)

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
        let time = now
        for group in groups {
            for index in group.members.indices {
                guard index < group.members.count, let window = group.members[index].window,
                      !group.members[index].minimized else { continue }
                if group.members[index].hidden {
                    guard showing(window) else { continue }
                    group.members[index].hidden = false
                    Log.tabs.notice("\(group.members[index].signature.appName, privacy: .public) showed its window again: back in \(group.displayName, privacy: .public)")
                    layoutAfterJoin(group, newcomer: window, focus: true)
                    continue
                }
                let groupmateShowing = group.windows.contains { $0 != window && showing($0) }
                let appHidden = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false
                guard group.isFormed, groupmateShowing, !showing(window), !appHidden, !window.isMinimized else {
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
    func placeBars(focused: AXWindow? = nil, hideMissing: Bool = true) {
        let formed = groups.filter(\.isFormed)
        guard !formed.isEmpty else { return }
        let onScreen = WindowQuery.onScreenWindows()
        var index: [CGWindowID: Int] = [:]
        for (i, w) in onScreen.enumerated() { index[w.id] = i }
        let focusedWindow = focused ?? WindowQuery.focusedWindow()

        for group in formed {
            guard let bar = group.bar else { continue }
            guard let active = group.active, let wid = windowID(of: active), let windowIndex = index[wid] else {
                if hideMissing { bar.hide() }
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
