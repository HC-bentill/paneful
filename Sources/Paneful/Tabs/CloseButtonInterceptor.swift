import AppKit
import ApplicationServices

/// In a tab group, the red close button sends the window to the Dock instead of closing it, so the tab isn't
/// lost: the next tab takes its place, and clicking the window in the Dock brings it back as the active tab.
/// ⌥-click still closes the window, as does right-click → Close Window on its tab. ⌘W isn't intercepted.
///
/// How: an event tap sees every left click before the app does. Where each group's visible window has its
/// close button is read ahead of time, on the tick, from the window's own close-button attribute. A click
/// is then checked with plain geometry, without asking the app anything while the click waits. (Asking the
/// app what's under the cursor doesn't work for Electron apps such as VS Code or Postman: their web content
/// extends under the traffic lights, so the answer is page content, not the button.) A click on a grouped
/// window's close button is swallowed, along with its mouse-up, and the window is minimized instead.
@MainActor
final class CloseButtonInterceptor {
    static let shared = CloseButtonInterceptor()

    private struct Target {
        let rect: CGRect      // AX coordinates
        let window: AXWindow
    }

    /// Where a window's close button sits, relative to the window's top-left corner.
    private struct ButtonSpot {
        let offset: CGPoint
        let size: CGSize
        let readAt: TimeInterval
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var targets: [Target] = []
    private var spots: [AXWindow: ButtonSpot] = [:]
    /// The window whose close button was pressed; minimized when the mouse comes up.
    private var pressed: AXWindow?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: closeButtonTapCallback, userInfo: nil) else {
            Log.tabs.error("Could not install the close-button event tap")
            return
        }
        tap = port
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.tabs.info("Close-button event tap installed")
    }

    /// Called on the tick: where each formed group's visible window has its close button right now.
    /// The button's offset inside a window is read once (and refreshed every few seconds); the group's frame
    /// gives the rest, so this stays cheap and follows the group while it's dragged.
    func updateTargets(_ groups: [TabGroup]) {
        guard tap != nil, Settings.closeButtonMinimizesTabs else { targets = []; return }
        let time = now
        var next: [Target] = []
        var keep = Set<AXWindow>()
        for group in groups where group.isFormed && (group.bar?.isVisible ?? false) {
            guard let window = group.active else { continue }
            keep.insert(window)
            if spots[window].map({ time - $0.readAt > 3 }) ?? true {
                spots[window] = readSpot(of: window, at: time) ?? spots[window]
            }
            guard let spot = spots[window] else { continue }
            let origin = group.contentFrame.origin
            next.append(Target(rect: CGRect(x: origin.x + spot.offset.x, y: origin.y + spot.offset.y,
                                            width: spot.size.width, height: spot.size.height),
                               window: window))
        }
        targets = next
        spots = spots.filter { keep.contains($0.key) }
    }

    private func readSpot(of window: AXWindow, at time: TimeInterval) -> ButtonSpot? {
        guard let origin = window.position,
              let raw = AXWindow.value(of: window.element, kAXCloseButtonAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let button = AXWindow(element: raw as! AXUIElement, pid: window.pid)
        guard let position = button.position, let size = button.size, size.width > 0, size.height > 0 else { return nil }
        return ButtonSpot(offset: CGPoint(x: position.x - origin.x, y: position.y - origin.y), size: size, readAt: time)
    }

    /// Returns false to swallow the event. `point` is the click in AX coordinates.
    fileprivate func handle(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever answers too slowly; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true

        case .leftMouseDown:
            pressed = nil
            guard Settings.closeButtonMinimizesTabs, !flags.contains(.maskAlternate),
                  let target = targets.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }),
                  TabGroupManager.shared.group(containing: target.window) != nil   // still grouped
            else { return true }
            pressed = target.window
            return false

        case .leftMouseUp:
            guard let window = pressed else { return true }
            pressed = nil
            Log.tabs.notice("Close button on a grouped window: minimizing it instead")
            TabGroupManager.shared.minimizeTab(window)
            return false

        default:
            return true
        }
    }
}

/// Event-tap C callback (must be a plain global function). Runs on the main run loop.
private func closeButtonTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                    _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let point = event.location, flags = event.flags
    let pass = MainActor.assumeIsolated { CloseButtonInterceptor.shared.handle(type, at: point, flags: flags) }
    return pass ? Unmanaged.passUnretained(event) : nil
}
