import AppKit

/// Watches global mouse drags. When the user drags a window:
///  - to a screen edge/corner → shows a snap preview and snaps on release;
///  - onto another window's title-bar strip → shows a "tab" preview and groups them on release.
@MainActor
final class DragController {
    private enum DropTarget {
        case snap(CGRect)                 // Cocoa rect
        case tab(AXWindow, CGRect)        // target window, Cocoa preview rect
    }

    /// How close (pt) the cursor must get to a screen edge to trigger a snap.
    private let edgeThreshold: CGFloat = 6
    /// Corner hot-zone size (pt) along the left/right edges → quarter snaps.
    private let cornerSize: CGFloat = 140
    /// Height (pt) of the strip at the top of a window where dropping creates a tab group.
    private let tabStripHeight: CGFloat = 44
    /// How long (s) the cursor must stay over a tab drop zone before it becomes the target. Stops windows
    /// from being grouped by accident when they're dragged across other windows.
    private let tabDwell: TimeInterval = 0.3

    private var monitors: [Any] = []
    private let preview = PreviewWindow()

    private var dragged: AXWindow?
    private var startFrame: CGRect?
    private var startMouse: CGPoint = .zero
    private var isMoving = false
    private var gaveUp = false
    private var target: DropTarget?
    private var lastTabProbe: TimeInterval = 0
    /// The tab drop zone under the cursor (not yet confirmed by the dwell) and when it was entered.
    private var tabCandidate: (window: AXWindow, rect: CGRect)?
    private var tabCandidateSince: TimeInterval = 0
    private var dwellCheck: DispatchWorkItem?

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
        let point = Geometry.axPoint(fromCocoa: NSEvent.mouseLocation)
        guard let window = WindowQuery.window(atAX: point), !window.isFullScreen,
              let frame = window.frame else { return }
        dragged = window
        startFrame = frame
        startMouse = NSEvent.mouseLocation
    }

    private func mouseDragged() {
        guard let window = dragged, let startFrame, !gaveUp else { return }
        let mouse = NSEvent.mouseLocation

        if !isMoving {
            // Only treat this as a window move once the window's origin changes but its size doesn't
            // (i.e. a title-bar drag, not a resize or a text selection).
            guard let frame = window.frame else { gaveUp = true; return }
            let sameSize = abs(frame.width - startFrame.width) < 1 && abs(frame.height - startFrame.height) < 1
            if sameSize && frame.origin != startFrame.origin {
                isMoving = true
            } else if hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) > 80 || !sameSize {
                gaveUp = true
            }
            return
        }

        updateTarget(cursor: mouse, dragged: window)
    }

    private func updateTarget(cursor: CGPoint, dragged: AXWindow) {
        target = computeTarget(cursor: cursor, dragged: dragged)
        switch target {
        case .snap(let rect)?: preview.show(rect)
        case .tab(_, let rect)?: preview.show(rect)
        case nil: preview.hide()
        }
    }

    private func mouseUp() {
        defer { reset() }
        preview.hide()
        guard isMoving, let window = dragged, let target else { return }

        // Let the app finish its own drag handling before we move the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                switch target {
                case .snap(let rect):
                    WindowMover.move(window, toCocoa: rect)
                case .tab(let other, _):
                    TabGroupManager.shared.addToGroup(target: other, window: window)
                }
            }
        }
    }

    private func reset() {
        dragged = nil
        startFrame = nil
        isMoving = false
        gaveUp = false
        target = nil
        lastTabProbe = 0
        tabCandidate = nil
        dwellCheck?.cancel()
        dwellCheck = nil
    }

    // MARK: - Target detection

    private func computeTarget(cursor: CGPoint, dragged: AXWindow) -> DropTarget? {
        if Settings.dragToSnap, let zone = edgeZone(for: cursor),
           let screen = Geometry.screen(containingCocoa: cursor) {
            tabCandidate = nil   // coming back to a window restarts its dwell
            return .snap(zone.rect(in: screen.visibleFrame))
        }
        guard Settings.dragToTab else { return nil }

        // CGWindowList is relatively expensive; probe at most ~16 times a second.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTabProbe >= 0.06 {
            lastTabProbe = now
            let probe = tabTarget(cursor: cursor, dragged: dragged)
            if probe?.window != tabCandidate?.window {
                tabCandidateSince = now
                scheduleDwellCheck(dragged: dragged)
            }
            tabCandidate = probe
        }
        guard let tabCandidate, now - tabCandidateSince >= tabDwell else { return nil }
        return .tab(tabCandidate.window, tabCandidate.rect)
    }

    /// Mouse-dragged events stop while the cursor is held still, so re-check once the dwell has passed.
    private func scheduleDwellCheck(dragged: AXWindow) {
        dwellCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isMoving, self.dragged == dragged, self.tabCandidate != nil else { return }
                self.updateTarget(cursor: NSEvent.mouseLocation, dragged: dragged)
            }
        }
        dwellCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tabDwell + 0.02, execute: work)
    }

    private func edgeZone(for cursor: CGPoint) -> SnapZone? {
        guard let screen = Geometry.screen(containingCocoa: cursor) else { return nil }
        let f = screen.frame
        if cursor.x <= f.minX + edgeThreshold {
            if cursor.y >= f.maxY - cornerSize { return .topLeft }
            if cursor.y <= f.minY + cornerSize { return .bottomLeft }
            return .leftHalf
        }
        if cursor.x >= f.maxX - edgeThreshold {
            if cursor.y >= f.maxY - cornerSize { return .topRight }
            if cursor.y <= f.minY + cornerSize { return .bottomRight }
            return .rightHalf
        }
        if cursor.y >= f.maxY - edgeThreshold {
            return .maximize
        }
        return nil
    }

    private func tabTarget(cursor: CGPoint, dragged: AXWindow) -> (window: AXWindow, rect: CGRect)? {
        let axPoint = Geometry.axPoint(fromCocoa: cursor)

        // The tab bar is Paneful's own panel, so CGWindowList (which skips our windows) can't find
        // a group when the cursor is over its bar. Check visible bars first.
        let ownGroup = TabGroupManager.shared.group(containing: dragged)
        if let group = TabGroupManager.shared.group(withVisibleBarAtAX: axPoint),
           group !== ownGroup, let active = group.active {
            return (active, Geometry.toCocoa(group.outerFrame))
        }

        guard let other = WindowQuery.window(belowAX: axPoint, excluding: dragged),
              other != dragged,
              let otherFrame = other.frame else { return nil }

        // Hidden tabs of the dragged window's own group sit underneath it; ignore them.
        if let ownGroup, ownGroup.windows.contains(other) {
            return nil
        }

        // If the window under the cursor is already in a group, the drop zone is the group's tab bar.
        let groupFrame = TabGroupManager.shared.group(containing: other)?.outerFrame
        let outer = groupFrame ?? otherFrame
        let stripTop = outer.minY
        guard axPoint.y >= stripTop, axPoint.y <= stripTop + tabStripHeight + (groupFrame == nil ? 0 : TabBarPanel.height) else {
            return nil
        }
        return (other, Geometry.toCocoa(outer))
    }
}
