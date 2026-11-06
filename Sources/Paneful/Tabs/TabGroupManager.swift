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

        var isLive: Bool { window != nil && !minimized }
    }

    let id: UUID
    var members: [Member]
    var activeWindow: AXWindow?
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

    // Auto-tabbing of remembered windows.
    /// Per app: windows already judged. They are never auto-tabbed (again).
    private var knownWindows: [pid_t: Set<AXWindow>] = [:]
    /// New windows still allowed to auto-tab, with the time they first appeared.
    private var firstSeen: [AXWindow: TimeInterval] = [:]
    private var unresponsiveUntil: [pid_t: TimeInterval] = [:]
    /// True during the first scan after launch, which claims windows that are already open.
    private var restoring = false

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

        // Re-form remembered groups from windows that are already open.
        restoring = true
        scanForRememberedWindows()
        restoring = false
        if !groups.isEmpty { NSLog("Paneful: loaded %d remembered group(s)", groups.count) }
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

    /// The remembered group a window belongs to, formed or not (includes minimized members).
    private func boundGroup(of window: AXWindow) -> TabGroup? {
        groups.first { $0.memberIndex(of: window) != nil }
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
        window.setFrame(group.contentFrame)
        window.focus()
        updateBar(group)
        group.bar?.show()
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

    /// Moves/resizes a whole group so that bar + windows fill `outer` (AX coords).
    func setOuterFrame(of group: TabGroup, to outer: CGRect) {
        var content = outer
        content.origin.y += TabBarPanel.height
        content.size.height -= TabBarPanel.height
        group.contentFrame = content
        group.windows.forEach { $0.setFrame(content) }
        group.active?.focus()
        updateBar(group)
        save()
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
            newcomer.setFrame(group.contentFrame)
            updateBar(group)
        }
    }

    private func form(_ group: TabGroup, around frame: CGRect, active: AXWindow) {
        var content = frame
        content.origin.y += TabBarPanel.height
        content.size.height -= TabBarPanel.height
        group.contentFrame = content
        group.activeWindow = active
        group.bar = makeBar(for: group)
        group.windows.forEach { $0.setFrame(content) }
        updateBar(group)
    }

    /// Hides the tab bar and gives its space back to the windows. The group stays remembered.
    private func unform(_ group: TabGroup) {
        guard let bar = group.bar else { return }
        let outer = group.outerFrame
        group.windows.forEach { $0.setFrame(outer) }
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
        if let placeAt {
            window.setFrame(placeAt)
            window.focus()
        }
        reconcile(group, focusNext: false)
        save()
    }

    /// A member's window closed, or its app quit. The member stays remembered.
    private func windowGone(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window) else { return }
        unobserve(window)
        group.members[index].window = nil
        group.members[index].minimized = false
        reconcile(group, focusNext: true)
    }

    private func windowMinimized(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window), !group.members[index].minimized else { return }
        group.members[index].minimized = true
        reconcile(group, focusNext: true)
    }

    private func windowRestored(_ window: AXWindow, in group: TabGroup) {
        guard let index = group.memberIndex(of: window), group.members[index].minimized else { return }
        group.members[index].minimized = false
        layoutAfterJoin(group, newcomer: window, focus: true)
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
            if focusNext { activate(group, window: next) } else { next.setFrame(group.contentFrame); updateBar(group) }
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
        NSLog("Paneful: \"%@\" rejoined remembered group %@", title, best.group.displayName)
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
            remove: { index in
                guard let (g, w) = lookup(index) else { return }
                TabGroupManager.shared.forget(w, in: g, placeAt: g.outerFrame.offsetBy(dx: 40, dy: 40))
            },
            closeWindow: { index in
                lookup(index)?.1.close()
            },
            tearOff: { index, cocoaPoint in
                guard let (g, w) = lookup(index) else { return }
                TabGroupManager.shared.forget(w, in: g, placeAt: Self.tearOffFrame(for: w, in: g, at: cocoaPoint))
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
        // Catch closed and un-minimized windows even if an AX notification was missed.
        for group in groups {
            for window in group.members.compactMap(\.window) {
                guard let index = group.memberIndex(of: window) else { continue }
                if window.frame == nil {
                    windowGone(window, in: group)
                } else if group.members[index].minimized, !window.isMinimized {
                    windowRestored(window, in: group)
                }
            }
        }

        scanForRememberedWindows()

        let formed = groups.filter(\.isFormed)
        guard !formed.isEmpty else { return }
        let focused = WindowQuery.focusedWindow()
        let followFocus = now >= focusFollowPausedUntil
        for group in formed {
            if let focused, group.windows.contains(focused) {
                if focused != group.activeWindow, followFocus {
                    group.activeWindow = focused
                    focused.setFrame(group.contentFrame)
                }
                updateBar(group)
                group.bar?.show()
            } else {
                group.bar?.hide()
            }
        }
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
            // Only the visible (active) window drives the group; the others are moved by us.
            guard group.isFormed, window == group.active, let frame = window.frame,
                  !frame.isClose(to: group.contentFrame, tolerance: 0.5) else { return }
            group.contentFrame = frame
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
                let active = group.active
                for window in group.windows where window != active {
                    window.setFrame(group.contentFrame)
                }
                self.save()
            }
        }
        pendingSync[group.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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
