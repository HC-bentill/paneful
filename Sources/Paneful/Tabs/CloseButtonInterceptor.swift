import AppKit
import ApplicationServices

/// The traffic-light buttons of a tabbed window act on the tab group:
/// - Red: sends the window to the Dock instead of closing it, so the tab isn't lost. The next tab takes its
///   place, and clicking the window in the Dock brings it back as the active tab. ⌥-click still closes the
///   window, as does right-click → Close Window on its tab. ⌘W isn't intercepted.
/// - Green: the whole group fills the screen, tab bar on top (see `TabGroupManager.toggleFill`); clicking it
///   again puts the group back. ⌥-click gives that one window macOS's own full screen instead, and its tab
///   steps aside until it leaves full screen. The green button's hover menu isn't touched.
///
/// How: an event tap sees every left click before the app does. Where each group's visible window has these
/// buttons is read ahead of time, on the tick, from the window's own button attributes. A click is then
/// checked with plain geometry, without asking the app anything while the click waits. (Asking the app what's
/// under the cursor doesn't work for Electron apps such as VS Code or Postman: their web content extends under
/// the traffic lights, so the answer is page content, not the button.) A click on one of the buttons of a
/// grouped window is swallowed, along with its mouse-up, and Paneful does the group's version instead.
@MainActor
final class CloseButtonInterceptor {
    static let shared = CloseButtonInterceptor()

    private enum Button {
        case close   // red
        case fill    // green
    }

    private struct Target {
        let rect: CGRect      // AX coordinates
        let window: AXWindow
        let button: Button
    }

    /// Where a button sits, relative to the window's top-left corner.
    private struct ButtonSpot {
        let offset: CGPoint
        let size: CGSize

        func rect(inWindowAt origin: CGPoint) -> CGRect {
            CGRect(x: origin.x + offset.x, y: origin.y + offset.y, width: size.width, height: size.height)
        }
    }

    /// A window's red and green buttons, as last read.
    private struct ButtonSpots {
        let close: ButtonSpot?
        let fill: ButtonSpot?
        let readAt: TimeInterval
    }

    private struct Press {
        let window: AXWindow
        let button: Button
        let option: Bool
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var targets: [Target] = []
    private var spots: [AXWindow: ButtonSpots] = [:]
    /// The button pressed on a grouped window; acted on when the mouse comes up.
    private var pressed: Press?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: closeButtonTapCallback, userInfo: nil) else {
            Log.tabs.error("Could not install the traffic-light event tap")
            return
        }
        tap = port
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.tabs.info("Traffic-light event tap installed")
    }

    /// Called on the tick: where each formed group's visible window has its red and green buttons right now.
    /// The buttons' offsets inside a window are read once (and refreshed every few seconds); the group's frame
    /// gives the rest, so this stays cheap and follows the group while it's dragged. Only groups whose bar is
    /// showing on this desktop count: a group on another desktop isn't under the mouse.
    func updateTargets(_ groups: [TabGroup]) {
        let close = Settings.closeButtonMinimizesTabs, fill = Settings.greenButtonFillsGroups
        guard tap != nil, close || fill else { targets = []; return }
        let time = now
        var next: [Target] = []
        var keep = Set<AXWindow>()
        for group in groups where group.isFormed && (group.bar?.isShowingHere ?? false) {
            guard let window = group.active else { continue }
            keep.insert(window)
            if spots[window].map({ time - $0.readAt > 3 }) ?? true {
                spots[window] = readSpots(of: window, at: time) ?? spots[window]
            }
            guard let spot = spots[window] else { continue }
            let origin = group.contentFrame.origin
            if close, let red = spot.close {
                next.append(Target(rect: red.rect(inWindowAt: origin), window: window, button: .close))
            }
            if fill, let green = spot.fill {
                next.append(Target(rect: green.rect(inWindowAt: origin), window: window, button: .fill))
            }
        }
        targets = next
        spots = spots.filter { keep.contains($0.key) }
    }

    private func readSpots(of window: AXWindow, at time: TimeInterval) -> ButtonSpots? {
        guard let origin = window.position else { return nil }
        func spot(_ attribute: String) -> ButtonSpot? {
            guard let raw = AXWindow.value(of: window.element, attribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let button = AXWindow(element: raw as! AXUIElement, pid: window.pid)
            guard let position = button.position, let size = button.size, size.width > 0, size.height > 0 else {
                return nil
            }
            return ButtonSpot(offset: CGPoint(x: position.x - origin.x, y: position.y - origin.y), size: size)
        }
        let close = spot(kAXCloseButtonAttribute)
        // The green button is the full-screen button; windows that can't go full screen call it zoom.
        let fill = spot(kAXFullScreenButtonAttribute) ?? spot(kAXZoomButtonAttribute)
        guard close != nil || fill != nil else { return nil }
        return ButtonSpots(close: close, fill: fill, readAt: time)
    }

    /// Returns false to swallow the event. `point` is the click in AX coordinates. `tag` is the event's
    /// source user data (`DesktopMover.eventTag` on Paneful's own clicks); `sourcePID` is the process that
    /// posted it (0 for real input).
    fileprivate func handle(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags, tag: Int64,
                            sourcePID: Int64) -> Bool {
        if type == .leftMouseDown || type == .leftMouseUp {
            // Paneful's own clicks, carrying a window to another desktop: let them through untouched.
            if tag == DesktopMover.eventTag || sourcePID == Int64(WindowQuery.ownPID) { return true }
            // The user clicked while windows are being carried: stop after the current one.
            if DesktopMover.shared.isBusy {
                if type == .leftMouseDown { DesktopMover.shared.userClicked(at: point, sourcePID: sourcePID) }
                return true
            }
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever answers too slowly; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true

        case .leftMouseDown:
            pressed = nil
            let option = flags.contains(.maskAlternate)
            guard let target = targets.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }),
                  TabGroupManager.shared.group(containing: target.window) != nil   // still grouped
            else { return true }
            switch target.button {
            case .close:
                guard Settings.closeButtonMinimizesTabs, !option else { return true }   // ⌥: really close
            case .fill:
                guard Settings.greenButtonFillsGroups else { return true }
            }
            pressed = Press(window: target.window, button: target.button, option: option)
            return false

        case .leftMouseUp:
            guard let press = pressed else { return true }
            pressed = nil
            switch press.button {
            case .close:
                Log.tabs.notice("Close button on a grouped window: minimizing it instead")
                TabGroupManager.shared.minimizeTab(press.window)
            case .fill:
                if press.option {
                    Log.tabs.notice("⌥-click on a grouped window's green button: macOS full screen for that window")
                    TabGroupManager.shared.enterNativeFullScreen(press.window)
                } else if let group = TabGroupManager.shared.group(containing: press.window) {
                    TabGroupManager.shared.toggleFill(group)
                }
            }
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
    let tag = event.getIntegerValueField(.eventSourceUserData)
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    let pass = MainActor.assumeIsolated {
        CloseButtonInterceptor.shared.handle(type, at: point, flags: flags, tag: tag, sourcePID: sourcePID)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}
