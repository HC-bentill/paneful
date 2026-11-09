import AppKit

/// Knows when other apps' windows can't be trusted, so Paneful leaves everything exactly as it was:
///
/// - **Frozen** while the Mac sleeps, the displays are off, the screen is locked or another user is switched
///   in. Accessibility can't read windows then (frames come back empty), which used to look like every grouped
///   window had closed: groups came apart and were rebuilt window by window after waking. Nothing is touched.
/// - **Settling** for a moment after waking, unlocking or a display change, while macOS rearranges the screens.
///   Tab bars stay glued to their windows, but nothing is decided yet (no window is treated as closed, and
///   moves macOS makes aren't followed).
///
/// `onWake` handlers run as soon as the Mac is usable again (to put anything macOS moved straight back), and
/// `onResume` handlers once it has settled.
@MainActor
final class SystemState {
    static let shared = SystemState()

    private(set) var isAsleep = false
    private(set) var screensAsleep = false
    private(set) var isLocked = false
    private var settleUntil: TimeInterval = 0
    private var wakeHandlers: [@MainActor () -> Void] = []
    private var resumeHandlers: [@MainActor () -> Void] = []
    private var pendingWake: DispatchWorkItem?
    private var pendingResume: DispatchWorkItem?
    private var started = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Asleep, displays off, or locked: don't touch any window.
    var isFrozen: Bool { isAsleep || screensAsleep || isLocked }

    /// Usable again, but macOS may still be rearranging the screens.
    var isSettling: Bool { !isFrozen && now < settleUntil }

    /// True while windows shouldn't be followed, re-stacked or treated as closed.
    var isPaused: Bool { isFrozen || isSettling }

    static var screenIsLockedNow: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Runs `handler` right after the Mac becomes usable again (woken, displays on, unlocked).
    func onWake(_ handler: @escaping @MainActor () -> Void) {
        wakeHandlers.append(handler)
    }

    /// Runs `handler` every time Paneful resumes after a pause, once things have settled.
    func onResume(_ handler: @escaping @MainActor () -> Void) {
        resumeHandlers.append(handler)
    }

    func start() {
        guard !started else { return }
        started = true
        isLocked = Self.screenIsLockedNow

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false; $0.settle(for: 2) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.settle(for: 2) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isLocked = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isLocked = false; $0.settle(for: 1) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false; $0.settle(for: 1) }

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.settle(for: 1.5) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ change: @escaping @MainActor @Sendable (SystemState) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let state = SystemState.shared
                let wasFrozen = state.isFrozen
                change(state)
                Log.app.notice("\(name.rawValue, privacy: .public): \(state.isFrozen ? "frozen" : state.isSettling ? "settling" : "running", privacy: .public)")
                if wasFrozen && !state.isFrozen { state.scheduleWake() }
                state.scheduleResume()
            }
        }
    }

    /// Keeps Paneful settling for `seconds` more, while apps and the window server catch up.
    private func settle(for seconds: TimeInterval) {
        settleUntil = max(settleUntil, now + seconds)
    }

    /// Just became usable: give the window server a moment to show everything again, then run the wake
    /// handlers.
    private func scheduleWake() {
        pendingWake?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let state = SystemState.shared
                state.pendingWake = nil
                guard !state.isFrozen else { return }
                state.wakeHandlers.forEach { $0() }
            }
        }
        pendingWake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Calls the resume handlers once the pause is over.
    private func scheduleResume() {
        pendingResume?.cancel()
        guard !isFrozen else { return }
        let delay = max(0, settleUntil - now) + 0.05
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let state = SystemState.shared
                guard !state.isPaused else { state.scheduleResume(); return }
                state.pendingResume = nil
                state.resumeHandlers.forEach { $0() }
            }
        }
        pendingResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
