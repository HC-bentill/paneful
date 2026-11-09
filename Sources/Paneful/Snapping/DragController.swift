import AppKit

/// Watches global mouse drags. When the user drags a window:
///  - to a screen edge/corner → shows a snap preview and snaps on release;
///  - onto the top part of another window (or a tab bar) and holds briefly → shows a "tab" preview and
///    groups them on release.
///
/// Drag tracking uses the window server (CGWindowList), not Accessibility, so it stays quick and reliable
/// with apps that answer Accessibility requests slowly (Chromium, Electron). Accessibility is only used
/// once a real window move has started.
@MainActor
final class DragController {
    private enum DropTarget {
        case snap(CGRect)                                // Cocoa rect
        case tab(TabCandidate, ready: Bool)
    }

    private struct TabCandidate {
        enum Key: Equatable { case window(CGWindowID), group(UUID) }
        let key: Key
        let window: ScreenWindow?    // the window under the cursor (nil when dropping on a tab bar)
        let group: TabGroup?         // its formed group, if any
        let rect: CGRect             // preview, Cocoa coordinates
    }

    /// How close (pt) the cursor must get to a screen edge to trigger a snap. When the Dock sits on that
    /// side, anywhere over the Dock counts too.
    private let edgeThreshold: CGFloat = 6
    /// Corner hot-zone size (pt) along the left/right edges → quarter snaps.
    private let cornerSize: CGFloat = 140
    /// Height (pt) of the drop zone at the top of a window (title bar + toolbar) that creates a tab.
    private let tabZoneHeight: CGFloat = 80
    /// How long (s) the cursor must stay over a tab drop zone before releasing groups the windows.
    private let tabDwell: TimeInterval = 0.3
    /// A single missed probe (window list caught mid-update) shouldn't restart the hold.
    private let probeGrace: TimeInterval = 0.15

    private var monitors: [Any] = []
    private let preview = PreviewWindow()

    // The current drag.
    private var pressed: ScreenWindow?       // window under the cursor at mouse-down
    private var startMouse: CGPoint = .zero  // Cocoa
    private var isMoving = false
    private var gaveUp = false
    private var dragged: AXWindow?
    private var draggedGroup: TabGroup?
    private var lookThrough: Set<CGWindowID> = []   // the dragged window and its group's hidden tabs
    private var target: DropTarget?
    private var lastProbe: TimeInterval = 0
    private var lastProbeHit: TimeInterval = 0
    private var candidate: TabCandidate?
    private var candidateSince: TimeInterval = 0
    private var dwellCheck: DispatchWorkItem?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, drag, up].compactMap { $0 }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        reset()
    }

    // MARK: - Events

    private func mouseDown() {
        reset()
        guard Settings.dragToSnap || Settings.dragToTab else { return }
        let mouse = NSEvent.mouseLocation
        guard let window = WindowQuery.topWindow(atAX: Geometry.axPoint(fromCocoa: mouse)) else { return }
        pressed = window
        startMouse = mouse
    }

    private func mouseDragged() {
        guard let pressed, !gaveUp else { return }
        let mouse = NSEvent.mouseLocation

        if !isMoving {
            // It's a window move once the window's origin changes but its size doesn't
            // (a title-bar drag, not a resize, a text selection or a drag inside the window).
            guard let bounds = WindowQuery.bounds(of: pressed.id) else { gaveUp = true; return }
            let sameSize = abs(bounds.width - pressed.bounds.width) < 1 && abs(bounds.height - pressed.bounds.height) < 1
            if sameSize && bounds.origin != pressed.bounds.origin {
                beginMove(pressed)
            } else if !sameSize || hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) > 80 {
                gaveUp = true
            }
            if !isMoving { return }
        }

        // Keep the group's tab bar glued to the window while it moves (AX move notifications are too
        // infrequent for a smooth follow).
        if let draggedGroup {
            let origin = CGPoint(x: pressed.bounds.minX + (mouse.x - startMouse.x),
                                 y: pressed.bounds.minY - (mouse.y - startMouse.y))
            TabGroupManager.shared.follow(draggedGroup, windowOrigin: origin)
        }
        updateTarget(cursor: mouse)
    }

    private func beginMove(_ pressed: ScreenWindow) {
        guard let window = WindowQuery.axWindow(for: pressed), !window.isFullScreen else {
            gaveUp = true
            Log.drag.notice("Drag ignored: no Accessibility window for CG window \(pressed.id, privacy: .public)")
            return
        }
        isMoving = true
        dragged = window
        draggedGroup = TabGroupManager.shared.group(containing: window)
        lookThrough = Set(draggedGroup?.windows.compactMap(\.windowID) ?? []).union([pressed.id])
        let app = NSRunningApplication(processIdentifier: pressed.pid)?.localizedName ?? "?"
        Log.drag.debug("Moving \(app, privacy: .public) window \(pressed.id, privacy: .public)")
    }

    private func updateTarget(cursor: CGPoint) {
        target = computeTarget(cursor: cursor)
        switch target {
        case .snap(let rect)?: preview.show(rect, style: .snap)
        case .tab(let c, let ready)?: preview.show(c.rect, style: ready ? .tabReady : .tabHold)
        case nil: preview.hide()
        }
    }

    private func mouseUp() {
        defer { reset() }
        AutoTiler.shared.noteMouseUp()   // a tile that changes size now was resized by the user
        preview.hide()
        guard isMoving, let window = dragged else { return }
        let group = draggedGroup

        // Auto-tiling: snapped somewhere on purpose → the window floats. Dropped with no target → it swaps
        // with the tile under the cursor, joins another display's layout, or slides back into its tile.
        switch target {
        case .snap?: AutoTiler.shared.release(window)
        case .tab(_, ready: true)?: break
        default: AutoTiler.shared.windowDropped(window, atCocoa: NSEvent.mouseLocation)
        }

        // Let the app finish its own drag handling before moving the window.
        let delay = DispatchTime.now() + 0.06
        switch target {
        case .snap(let rect)?:
            Log.drag.notice("Snap to \(rect.debugDescription, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: delay) {
                MainActor.assumeIsolated { WindowMover.move(window, toCocoa: rect) }
            }

        case .tab(let c, ready: true)?:
            guard let other = c.group?.active ?? c.window.flatMap(WindowQuery.axWindow(for:)) else {
                Log.drag.error("Tab drop: target window not found")
                return
            }
            Log.drag.notice("Tab drop onto window \(other.windowID ?? 0, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: delay) {
                MainActor.assumeIsolated { TabGroupManager.shared.addToGroup(target: other, window: window) }
            }

        default:
            if let group {
                DispatchQueue.main.asyncAfter(deadline: delay) {
                    MainActor.assumeIsolated { TabGroupManager.shared.dragEnded(group) }
                }
            }
        }
    }

    private func reset() {
        pressed = nil
        isMoving = false
        gaveUp = false
        dragged = nil
        draggedGroup = nil
        lookThrough = []
        target = nil
        lastProbe = 0
        lastProbeHit = 0
        candidate = nil
        dwellCheck?.cancel()
        dwellCheck = nil
    }

    // MARK: - Target detection

    private func computeTarget(cursor: CGPoint) -> DropTarget? {
        if Settings.dragToSnap, let screen = Geometry.screen(containingCocoa: cursor),
           let zone = edgeZone(for: cursor, on: screen) {
            candidate = nil   // coming back to a window restarts its hold
            return .snap(zone.rect(in: screen.visibleFrame))
        }
        guard Settings.dragToTab else { return nil }

        // CGWindowList is cheap but not free; probe ~20 times a second.
        let time = now
        if time - lastProbe >= 0.05 {
            lastProbe = time
            if let probe = tabProbe(cursor: cursor) {
                lastProbeHit = time
                if probe.key != candidate?.key {
                    candidateSince = time
                    scheduleDwellCheck()
                }
                candidate = probe
            } else if time - lastProbeHit > probeGrace {
                candidate = nil
            }
        }
        guard let candidate else { return nil }
        return .tab(candidate, ready: time - candidateSince >= tabDwell)
    }

    /// Mouse-dragged events stop while the cursor is held still, so re-check once the hold time has passed.
    private func scheduleDwellCheck() {
        dwellCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isMoving, self.candidate != nil else { return }
                self.updateTarget(cursor: NSEvent.mouseLocation)
            }
        }
        dwellCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tabDwell + 0.02, execute: work)
    }

    private func edgeZone(for cursor: CGPoint, on screen: NSScreen) -> SnapZone? {
        let f = screen.frame, v = screen.visibleFrame
        let dockLeft = v.minX > f.minX + 1, dockRight = v.maxX < f.maxX - 1
        let atLeft = cursor.x <= f.minX + edgeThreshold || (dockLeft && cursor.x <= v.minX)
        let atRight = cursor.x >= f.maxX - edgeThreshold || (dockRight && cursor.x >= v.maxX)
        if atLeft || atRight {
            if cursor.y >= f.maxY - cornerSize { return atLeft ? .topLeft : .topRight }
            if cursor.y <= f.minY + cornerSize { return atLeft ? .bottomLeft : .bottomRight }
            return atLeft ? .leftHalf : .rightHalf
        }
        // Top edge, including anywhere in the menu bar.
        if cursor.y >= min(f.maxY - edgeThreshold, v.maxY) {
            return .maximize
        }
        return nil
    }

    /// The tab drop zone under the cursor: a group's tab bar, or the top part of another window
    /// (plus the bar when that window is grouped).
    private func tabProbe(cursor: CGPoint) -> TabCandidate? {
        let point = Geometry.axPoint(fromCocoa: cursor)
        let manager = TabGroupManager.shared

        if let group = manager.group(withVisibleBarAtAX: point), group !== draggedGroup {
            return TabCandidate(key: .group(group.id), window: nil, group: group,
                                rect: Geometry.toCocoa(group.outerFrame))
        }

        guard let under = WindowQuery.topWindow(atAX: point, excluding: lookThrough, blockedByOwn: false) else {
            return nil
        }
        let group = manager.group(withWindowID: under.id)
        if let group, group === draggedGroup { return nil }

        let outer = group?.outerFrame ?? under.bounds
        let zoneBottom = outer.minY + (group == nil ? 0 : TabBarPanel.height) + tabZoneHeight
        guard point.y >= outer.minY, point.y <= zoneBottom else { return nil }
        return TabCandidate(key: group.map { .group($0.id) } ?? .window(under.id), window: under,
                            group: group, rect: Geometry.toCocoa(outer))
    }
}
