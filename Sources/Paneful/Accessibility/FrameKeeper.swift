import AppKit

/// Moves windows and makes sure the move sticks.
///
/// Some apps animate Accessibility frame changes, apply them late, or put their own frame back a moment
/// later (Chromium/Electron after a drag, apps restoring a saved window frame at launch). So every
/// placement is checked after 0.12 s and 0.4 s and re-applied if the window isn't where it should be.
/// While a placement is being checked, `isPlacing` is true so observers can ignore the in-between frames.
@MainActor
final class FrameKeeper {
    static let shared = FrameKeeper()

    private var pending: [AXWindow: Int] = [:]   // window → token of its latest placement
    private var nextToken = 0

    func place(_ window: AXWindow, _ rect: CGRect) {
        window.setFrame(rect)
        nextToken += 1
        let token = nextToken
        pending[window] = token
        check(window, rect, token: token, after: 0.12, reapply: true)
        check(window, rect, token: token, after: 0.4, reapply: true)
        check(window, rect, token: token, after: 0.75, reapply: false)
    }

    func isPlacing(_ window: AXWindow) -> Bool { pending[window] != nil }

    func cancel(_ window: AXWindow) { pending[window] = nil }

    private func check(_ window: AXWindow, _ rect: CGRect, token: Int, after delay: TimeInterval, reapply: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending[window] == token else { return }
                // The user grabbed the window (dragging or resizing it): stop insisting.
                if NSEvent.pressedMouseButtons != 0 {
                    self.pending[window] = nil
                    return
                }
                guard let frame = window.frame else {
                    self.pending[window] = nil
                    return
                }
                if frame.isRoughly(rect) {
                    if !reapply { self.pending[window] = nil }
                    return
                }
                let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
                if reapply {
                    Log.frames.notice("\(app, privacy: .public) didn't take frame \(rect.debugDescription, privacy: .public) (is \(frame.debugDescription, privacy: .public)); re-applying")
                    window.setFrame(rect)
                } else {
                    Log.frames.error("\(app, privacy: .public) kept its own frame \(frame.debugDescription, privacy: .public) instead of \(rect.debugDescription, privacy: .public)")
                    self.pending[window] = nil
                }
            }
        }
    }
}
