import AppKit

/// Carries other apps' windows to another desktop (Space) by dragging them there in Mission Control.
///
/// macOS 27 has no API that moves another app's window between desktops. Checked on macOS 27.2: the private
/// CGSMoveWindowsToManagedSpace and its relatives only move Paneful's own windows, and a window un-minimized on
/// another desktop goes back to its own. Holding a window by its title bar while switching desktops works for
/// most apps, but not for apps that draw their own title bar (the Claude app), and it switches desktops twice
/// per window.
///
/// Mission Control moves any window: it shows every window of the desktop on screen, and a window dropped on a
/// desktop in its top row goes there. So Paneful drags each window's picture onto the desktop, like a person
/// (`MissionControl` says where everything is). That needs no title bar and no desktop switching. When the
/// user dragged the tab bar in Mission Control, it's still open and Paneful works in it; otherwise Paneful
/// opens it and closes it again afterwards.
///
/// Paneful's own events carry `eventTag`. A click or key press from the user while it works stops the move: the
/// window in hand is put back, and the others stay where they are. Moving the mouse doesn't.
@MainActor
final class DesktopMover {
    static let shared = DesktopMover()

    /// Marks Paneful's own synthetic events ("PANE").
    static let eventTag: Int64 = 0x5041_4E45

    struct Item: Equatable {
        let window: AXWindow
        let id: CGWindowID
        let name: String
    }

    struct Report {
        var moved: [CGWindowID] = []
        var failed: [(name: String, reason: String)] = []
    }

    private(set) var isBusy = false
    private var interrupted = false
    private var watcher: CFMachPort?
    private var watcherSource: CFRunLoopSource?

    private static let stoppedByUser = "stopped because you clicked or typed"

    /// The user clicked while a move was running (seen by `CloseButtonInterceptor`).
    func userClicked(at point: CGPoint, sourcePID: Int64) {
        userInterrupted("a click", at: point, sourcePID: sourcePID)
    }

    fileprivate func userInterrupted(_ what: String, at point: CGPoint, sourcePID: Int64) {
        guard isBusy, !interrupted else { return }
        interrupted = true
        Log.tabs.notice("Desktop move: \(what, privacy: .public) at \(point.debugDescription, privacy: .public) (from pid \(sourcePID, privacy: .public)), stopping")
    }

    /// Carries `items` (in this order) to desktop `target`. Afterwards Mission Control is left as the user had
    /// it: open if they opened it (and Paneful stayed on their desktop), else closed onto desktop `returnTo`.
    func carry(_ items: [Item], to target: UInt64, returnTo: UInt64?) async -> Report {
        isBusy = true
        interrupted = false
        startWatching()
        defer {
            stopWatching()
            isBusy = false
        }
        let pointer = CGEvent(source: nil)?.location
        let began = ProcessInfo.processInfo.systemUptime
        let userOpenedIt = MissionControl.isShowing
        let layout = Spaces.layout()
        let startedOn = layout.current(onDisplayOf: target)
        var report = Report()

        // Leave out what can't be carried, and note each window's desktop.
        var todo: [(item: Item, source: UInt64)] = []
        for item in items {
            guard let source = Spaces.space(of: item.id) else {
                Log.tabs.error("Desktop move: macOS doesn't say which desktop \(item.name, privacy: .public) is on")
                report.failed.append((item.name, "macOS doesn't say which desktop it's on"))
                continue
            }
            if source == target {
                report.moved.append(item.id)
            } else if item.window.isFullScreen {
                report.failed.append((item.name, "it's in full screen"))
            } else if layout.steps(from: source, to: target) == nil {
                report.failed.append((item.name, "it's on another display"))
            } else {
                todo.append((item, source))
            }
        }

        // Desktop by desktop: the one on screen first (Mission Control shows only its windows).
        var sources: [UInt64] = []
        for entry in todo where !sources.contains(entry.source) { sources.append(entry.source) }
        if let startedOn, let i = sources.firstIndex(of: startedOn) { sources.insert(sources.remove(at: i), at: 0) }
        var stop: String?
        for source in sources {
            if stop == nil, !interrupted, !(await showInMissionControl(source)) {
                stop = "Mission Control didn't open on its desktop"
            }
            for (item, from) in todo where from == source {
                if stop == nil, interrupted { stop = Self.stoppedByUser }
                if let stop {
                    report.failed.append((item.name, stop))
                    continue
                }
                switch await drag(item, from: source, to: target) {
                case .moved:
                    report.moved.append(item.id)
                case .failed(let reason):
                    report.failed.append((item.name, reason))
                case .stop(let reason):
                    report.failed.append((item.name, reason))
                    stop = reason
                }
            }
        }

        if !interrupted, MissionControl.isShowing {
            let stillTheirs = userOpenedIt && Spaces.layout().current(onDisplayOf: target) == startedOn
            if !stillTheirs, let back = returnTo ?? startedOn {
                _ = await MissionControl.leave(to: back)
            }
        }
        if let pointer, !interrupted { post(mouse: .mouseMoved, at: pointer) }
        Log.tabs.notice("Desktop move: \(report.moved.count, privacy: .public) of \(items.count, privacy: .public) window(s) on desktop \(target, privacy: .public) after \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - began), privacy: .public)s")
        return report
    }

    // MARK: Mission Control

    /// Mission Control is open on desktop `space` (it shows that desktop's windows). Goes there through
    /// Mission Control's top row when another desktop is on screen.
    private func showInMissionControl(_ space: UInt64) async -> Bool {
        if Spaces.layout().current(onDisplayOf: space) != space {
            Log.tabs.info("Desktop move: going to desktop \(space, privacy: .public) through Mission Control")
            if !MissionControl.isShowing { guard await MissionControl.open() else { return false } }
            guard await MissionControl.leave(to: space) else { return false }
        }
        return MissionControl.isShowing ? true : await MissionControl.open()
    }

    private enum Outcome {
        case moved
        /// This window didn't move; the next one may.
        case failed(String)
        /// Don't try the others.
        case stop(String)
    }

    private func drag(_ item: Item, from source: UInt64, to target: UInt64) async -> Outcome {
        var reason = "Mission Control didn't take it"
        for attempt in 0..<2 {
            if interrupted { return .stop(Self.stoppedByUser) }
            guard let picture = await settledPicture(of: item.id) else {
                Log.tabs.error("Desktop move: Mission Control doesn't show \(item.name, privacy: .public)")
                return .failed("Mission Control doesn't show it")
            }
            let started = ProcessInfo.processInfo.systemUptime
            let drop = await dragOnce(item, picture: picture, from: source, to: target, attempt: attempt)
            let took = ProcessInfo.processInfo.systemUptime - started
            switch drop {
            case .moved:
                Log.tabs.notice("Desktop move: \(item.name, privacy: .public) is on desktop \(target, privacy: .public) now (\(String(format: "%.2f", took), privacy: .public)s, try \(attempt + 1, privacy: .public))")
                return .moved
            case .interrupted:
                return .stop(Self.stoppedByUser)
            case .noDesktop:
                Log.tabs.error("Desktop move: Mission Control's top row has no desktop \(target, privacy: .public)")
                return .stop("Mission Control doesn't show that desktop")
            case .stayed:
                Log.tabs.error("Desktop move: \(item.name, privacy: .public) was let go over desktop \(target, privacy: .public) but stayed on \(source, privacy: .public) (try \(attempt + 1, privacy: .public))")
            case .otherDesktop(let space):
                Log.tabs.error("Desktop move: \(item.name, privacy: .public) landed on desktop \(space, privacy: .public) instead of \(target, privacy: .public)")
                return .failed("it landed on another desktop")
            case .fullScreen(let space):
                Log.tabs.error("Desktop move: Mission Control made \(item.name, privacy: .public) full screen (space \(space, privacy: .public)); taking it out again (try \(attempt + 1, privacy: .public))")
                reason = "macOS put it in full screen"
                guard await undoFullScreen(item, back: source) else { return .failed(reason) }
            }
        }
        return .failed(reason)
    }

    private enum DragResult {
        case moved, stayed, interrupted, noDesktop
        case fullScreen(UInt64)
        case otherDesktop(UInt64)
    }

    /// One drag of a window's picture onto the desktop's button in the top row. The first try is brisk once the
    /// top row is open (it stays open after the first drop); a second try takes the slower pace first checked
    /// by hand (2026-11-13: 8 of 8 windows moved at it).
    private func dragOnce(_ item: Item, picture: CGRect, from source: UInt64, to target: UInt64,
                          attempt: Int) async -> DragResult {
        func targetFrame() -> CGRect? { MissionControl.button(for: target, in: Spaces.layout())?.frame }
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        let start = grabPoint(on: picture)
        let display = NSScreen.screens.map { Geometry.toAX($0.frame) }.first { $0.contains(start) }
            ?? CGDisplayBounds(CGMainDisplayID())
        let rowOpen = targetFrame().map { MissionControlGeometry.rowIsOpen($0, display: display) } ?? false
        let brisk = attempt == 0 && rowOpen
        post(mouse: .mouseMoved, at: start)
        await pause(brisk ? 25 : 40)
        post(mouse: .leftMouseDown, at: start)
        await pause(brisk ? 50 : 70)
        let lifted = CGPoint(x: start.x, y: start.y - 8)
        await glide(from: start, to: lifted, steps: brisk ? 2 : 3, every: 12)
        guard let first = targetFrame() else { return await putBack(from: lifted, to: start, .noDesktop) }

        // Up from below into the top row (which opens as the picture comes near, if it isn't open yet).
        let below = MissionControlGeometry.approachPoint(under: first, display: display)
        await glide(from: lifted, to: below, steps: brisk ? 6 : 10, every: brisk ? 10 : 12)
        let entry = CGPoint(x: first.midX, y: first.midY)
        await glide(from: below, to: entry, steps: brisk ? 4 : 6, every: brisk ? 12 : 15)
        await pause(brisk ? 120 : 250)

        // Aim at the desktop, again until the row stops moving.
        var position = entry
        var aim = entry
        for _ in 0..<3 {
            if interrupted { return await putBack(from: position, to: start, .interrupted) }
            guard let frame = targetFrame() else { return await putBack(from: position, to: start, .noDesktop) }
            aim = MissionControlGeometry.dropPoint(on: frame, attempt: attempt)
            await glide(from: position, to: aim, steps: brisk ? 4 : 5, every: 12)
            position = aim
            await pause(brisk ? 80 : 120)
            if MissionControlGeometry.isSettled(frame, targetFrame()) { break }
        }
        // Hover a moment, as a hand would.
        for dx: CGFloat in brisk ? [2, 0] : [2, -2, 0] {
            post(mouse: .leftMouseDragged, at: CGPoint(x: aim.x + dx, y: aim.y))
            await pause(45)
        }
        if interrupted { return await putBack(from: aim, to: start, .interrupted) }
        post(mouse: .leftMouseUp, at: aim)

        for _ in 0..<60 {   // 1.2 s
            await pause(20)
            switch MissionControlGeometry.drop(space: Spaces.space(of: item.id), source: source, target: target,
                                               layout: Spaces.layout()) {
            case .moved:
                await pause(60)   // the drop animation
                return .moved
            case .fullScreen(let space):
                return .fullScreen(space)
            case .otherDesktop(let space):
                return .otherDesktop(space)
            case .stayed, .unknown:
                continue
            }
        }
        return .stayed
    }

    /// Takes the picture back to where it was picked up and lets go there: nothing moves.
    private func putBack(from: CGPoint, to start: CGPoint, _ result: DragResult) async -> DragResult {
        await glide(from: from, to: start, steps: 6, every: 12)
        post(mouse: .leftMouseUp, at: start)
        try? await Task.sleep(for: .milliseconds(200))
        return result
    }

    /// The window's picture in Mission Control (where CGWindowList puts the window while it's open), once it
    /// has stopped gliding.
    private func settledPicture(of id: CGWindowID) async -> CGRect? {
        var last = WindowQuery.bounds(of: id)
        for _ in 0..<34 {   // 1 s
            try? await Task.sleep(for: .milliseconds(30))
            let now = WindowQuery.bounds(of: id)
            if MissionControlGeometry.isSettled(last, now) { return now }
            last = now
        }
        return last
    }

    /// A point on the picture that isn't covered by another one.
    private func grabPoint(on picture: CGRect) -> CGPoint {
        let spots: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.5, 0.3), (0.3, 0.5), (0.7, 0.5), (0.5, 0.75)]
        for (fx, fy) in spots {
            let point = CGPoint(x: picture.minX + picture.width * fx, y: picture.minY + picture.height * fy)
            if MissionControl.picture(picture, isAt: point) { return point }
        }
        return CGPoint(x: picture.midX, y: picture.midY)
    }

    /// Mission Control made the window full screen (it was let go between desktops): take it out of full
    /// screen and wait until it's back on its desktop, with Mission Control open there again.
    private func undoFullScreen(_ item: Item, back source: UInt64) async -> Bool {
        item.window.setFullScreen(false)
        for _ in 0..<60 {   // 3 s
            try? await Task.sleep(for: .milliseconds(50))
            if Spaces.space(of: item.id) == source { break }
        }
        guard Spaces.space(of: item.id) == source else {
            Log.tabs.error("Desktop move: \(item.name, privacy: .public) didn't come out of full screen")
            return false
        }
        return await showInMissionControl(source)
    }

    // MARK: Synthetic events

    private func glide(from a: CGPoint, to b: CGPoint, steps: Int, every milliseconds: Int) async {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(mouse: .leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private func post(mouse type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        event.flags = []
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Watching for the user

    /// A listen-only tap (it never holds input up) that notices the user's clicks and key presses. Moving the
    /// mouse doesn't stop a move (Henry, 2026-11-13): Paneful lets go of each window where it aims anyway, and
    /// Mission Control also sends mouse-moved events of its own while the pointer is still.
    private func startWatching() {
        guard watcher == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: desktopMoverWatchCallback, userInfo: nil) else {
            Log.tabs.error("Desktop move: couldn't watch for the user's input")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        watcher = port
        watcherSource = source
    }

    private func stopWatching() {
        if let watcher { CGEvent.tapEnable(tap: watcher, enable: false) }
        if let watcherSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), watcherSource, .commonModes) }
        watcher = nil
        watcherSource = nil
    }
}

/// Listen-only tap callback (a plain global function). Runs on the main run loop.
private func desktopMoverWatchCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                       _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else { return Unmanaged.passUnretained(event) }
    let tag = event.getIntegerValueField(.eventSourceUserData)
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    let point = event.location
    let what = type == .keyDown ? "a key press" : "a click"
    MainActor.assumeIsolated {
        // Paneful's own events don't count.
        guard tag != DesktopMover.eventTag, sourcePID != Int64(WindowQuery.ownPID) else { return }
        DesktopMover.shared.userInterrupted(what, at: point, sourcePID: sourcePID)
    }
    return Unmanaged.passUnretained(event)
}
