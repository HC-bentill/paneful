import AppKit
import ApplicationServices

/// Windows from any apps stacked at the same frame, with one floating tab bar above them.
@MainActor
final class TabGroup {
    let id = UUID()
    var windows: [AXWindow]
    var activeIndex: Int
    /// Frame (AX coords) shared by every window in the group. The tab bar sits directly above it.
    var contentFrame: CGRect
    var bar: TabBarPanel!

    init(windows: [AXWindow], activeIndex: Int, contentFrame: CGRect) {
        self.windows = windows
        self.activeIndex = activeIndex
        self.contentFrame = contentFrame
    }

    var active: AXWindow? { windows.indices.contains(activeIndex) ? windows[activeIndex] : nil }

    var barFrame: CGRect {
        CGRect(x: contentFrame.minX, y: contentFrame.minY - TabBarPanel.height,
               width: contentFrame.width, height: TabBarPanel.height)
    }

    /// Tab bar + windows together (AX coords).
    var outerFrame: CGRect { barFrame.union(contentFrame) }
}

/// Creates, syncs and dissolves tab groups.
///
/// How it works: macOS can't embed one app's window in another, so every window in a group is kept
/// at the same frame; the selected tab's window is raised in front of the others. AXObservers tell us
/// when the active window is moved/resized (so the others follow) or closed.
@MainActor
final class TabGroupManager {
    static let shared = TabGroupManager()

    private(set) var groups: [TabGroup] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingSync: [UUID: DispatchWorkItem] = [:]
    private var iconCache: [pid_t: NSImage] = [:]

    private static let watched = [
        kAXMovedNotification, kAXResizedNotification,
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
    ]

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TabGroupManager.shared.refresh() }
        }
    }

    // MARK: - Queries

    func group(containing window: AXWindow) -> TabGroup? {
        groups.first { $0.windows.contains(window) }
    }

    // MARK: - Grouping

    /// Adds `window` as a new tab to `target`'s group (creating the group if needed).
    func addToGroup(target: AXWindow, window: AXWindow) {
        guard target != window else { return }
        if let old = group(containing: window) {
            if old === group(containing: target) { return }
            detach(window, from: old, restore: false)
        }

        let group: TabGroup
        if let existing = self.group(containing: target) {
            group = existing
        } else {
            guard let frame = target.frame else { return }
            // Make room for the tab bar by pushing the content down.
            var content = frame
            content.origin.y += TabBarPanel.height
            content.size.height -= TabBarPanel.height
            group = makeGroup(with: target, content: content)
            target.setFrame(content)
        }

        group.windows.append(window)
        observe(window)
        activate(group, index: group.windows.count - 1)
    }

    private func makeGroup(with window: AXWindow, content: CGRect) -> TabGroup {
        let group = TabGroup(windows: [window], activeIndex: 0, contentFrame: content)
        let id = group.id
        group.bar = TabBarPanel(
            onSelect: { [weak self] index in
                guard let self, let g = self.groups.first(where: { $0.id == id }) else { return }
                self.activate(g, index: index)
            },
            onClose: { [weak self] index in
                guard let self, let g = self.groups.first(where: { $0.id == id }),
                      g.windows.indices.contains(index) else { return }
                self.detach(g.windows[index], from: g, restore: true)
            },
            onUngroup: { [weak self] in
                guard let self, let g = self.groups.first(where: { $0.id == id }) else { return }
                self.dissolve(g)
            })
        groups.append(group)
        observe(window)
        return group
    }

    /// Shows tab `index`: moves its window into place and brings it to the front.
    func activate(_ group: TabGroup, index: Int) {
        guard group.windows.indices.contains(index) else { return }
        group.activeIndex = index
        let window = group.windows[index]
        window.setFrame(group.contentFrame)
        window.focus()
        updateBar(group)
        group.bar.show()
    }

    func cycle(from window: AXWindow?, by delta: Int) {
        guard let window, let group = group(containing: window), group.windows.count > 1 else { return }
        let count = group.windows.count
        activate(group, index: ((group.activeIndex + delta) % count + count) % count)
    }

    /// Removes a window from whichever group holds it.
    func remove(_ window: AXWindow) {
        guard let group = group(containing: window) else { return }
        detach(window, from: group, restore: true)
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
    }

    func ungroupAll() {
        groups.forEach { dissolve($0) }
    }

    // MARK: - Removing

    private func detach(_ window: AXWindow, from group: TabGroup, restore: Bool) {
        unobserve(window)
        group.windows.removeAll { $0 == window }
        if restore {
            // Pop it out slightly offset so the user can see it left the group.
            window.setFrame(group.outerFrame.offsetBy(dx: 40, dy: 40))
            window.focus()
        }
        if group.windows.count <= 1 {
            dissolve(group)
        } else {
            group.activeIndex = min(group.activeIndex, group.windows.count - 1)
            if !restore { activate(group, index: group.activeIndex) } else { updateBar(group) }
        }
    }

    private func dissolve(_ group: TabGroup) {
        let outer = group.outerFrame
        for window in group.windows {
            unobserve(window)
            window.setFrame(outer)    // give the space taken by the tab bar back to the window
        }
        group.bar.close()
        pendingSync[group.id]?.cancel()
        pendingSync[group.id] = nil
        groups.removeAll { $0 === group }
    }

    // MARK: - Tab bar

    private func updateBar(_ group: TabGroup) {
        group.bar.setFrame(ax: group.barFrame)
        let tabs = group.windows.enumerated().map { index, window in
            let app = NSRunningApplication(processIdentifier: window.pid)
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app?.localizedName ?? "Window"
            return TabItem(id: index, title: title, icon: icon(for: window.pid, app: app),
                           isActive: index == group.activeIndex)
        }
        if group.bar.model.tabs != tabs { group.bar.model.tabs = tabs }
    }

    private func icon(for pid: pid_t, app: NSRunningApplication?) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let image = app?.icon
        iconCache[pid] = image
        return image
    }

    /// Called on a timer and on app switches: shows the bar only for the group the user is working in,
    /// keeps titles fresh, and follows Cmd-Tab / clicks that focus a background tab.
    func refresh() {
        guard !groups.isEmpty else { return }

        // Drop windows that no longer exist.
        for group in groups {
            let gone = group.windows.filter { $0.frame == nil }
            gone.forEach { detach($0, from: group, restore: false) }
        }

        let focused = WindowQuery.focusedWindow()
        for group in groups {
            if let focused, let index = group.windows.firstIndex(of: focused) {
                if index != group.activeIndex {
                    group.activeIndex = index
                    focused.setFrame(group.contentFrame)
                }
                updateBar(group)
                group.bar.show()
            } else {
                group.bar.hide()
            }
        }
    }

    // MARK: - AX observation

    fileprivate func handle(element: AXUIElement, notification: String) {
        guard let group = groups.first(where: { g in g.windows.contains { CFEqual($0.element, element) } }),
              let index = group.windows.firstIndex(where: { CFEqual($0.element, element) }) else { return }
        let window = group.windows[index]

        switch notification {
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            detach(window, from: group, restore: false)

        case kAXMovedNotification, kAXResizedNotification:
            // Only the visible (active) window drives the group; the others are moved by us.
            guard index == group.activeIndex, let frame = window.frame,
                  !frame.isClose(to: group.contentFrame, tolerance: 0.5) else { return }
            group.contentFrame = frame
            group.bar.setFrame(ax: group.barFrame)
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
                guard let self, let group, self.groups.contains(where: { $0 === group }) else { return }
                for (i, w) in group.windows.enumerated() where i != group.activeIndex {
                    w.setFrame(group.contentFrame)
                }
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
