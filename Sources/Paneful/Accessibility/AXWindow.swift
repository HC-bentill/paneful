import AppKit
import ApplicationServices

/// Private but long-stable HIServices call (used by Rectangle, AltTab, Hammerspoon…): the CGWindowID
/// behind an Accessibility window element.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// A thin wrapper around another app's window, controlled through the Accessibility API.
///
/// Coordinates are in "AX space": origin at the top-left of the primary screen, y grows downward.
/// Use `Geometry` to convert to/from Cocoa (bottom-left origin) coordinates.
struct AXWindow: Hashable {
    let element: AXUIElement
    let pid: pid_t

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
        // Don't let a hung app freeze Paneful.
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    init?(element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        self.init(element: element, pid: pid)
    }

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    // MARK: - Reading attributes

    static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    var title: String? { Self.value(of: element, kAXTitleAttribute) as? String }
    var role: String? { Self.value(of: element, kAXRoleAttribute) as? String }
    var subrole: String? { Self.value(of: element, kAXSubroleAttribute) as? String }
    var isMinimized: Bool { (Self.value(of: element, kAXMinimizedAttribute) as? Bool) ?? false }

    var isStandardWindow: Bool {
        role == kAXWindowRole && (subrole == nil || subrole == kAXStandardWindowSubrole)
    }

    /// Native full-screen (green button) windows live in their own Space; Paneful leaves them alone.
    var isFullScreen: Bool { (Self.value(of: element, "AXFullScreen") as? Bool) ?? false }

    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    var position: CGPoint? {
        guard let raw = Self.value(of: element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let raw = Self.value(of: element, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Frame in AX coordinates. `nil` when the window no longer exists, or can't be read right now (a hung
    /// app, or any app while the screen is locked).
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// True only when the window has really closed. A slow or hung app, or the locked screen, makes reads
    /// fail with other errors; those don't count, so a window isn't dropped from its group while the Mac
    /// sleeps.
    var isGone: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    /// Whether the window's size can be changed (fixed-size windows such as Calculator can't be tiled).
    var isResizable: Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    // MARK: - Changing the window

    func setPosition(_ point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    func setSize(_ size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    /// Size → position → size: the second resize fixes apps that clamp size to the current screen.
    ///
    /// Chromium and Electron apps (Brave, Chrome, VS Code, Teams, Notion…) often have
    /// `AXEnhancedUserInterface` switched on. Their windows then animate Accessibility frame changes and
    /// drop some of them, so it is switched off while the frame is set (the same workaround Rectangle uses).
    /// Prefer `FrameKeeper.place`, which also checks that the change stuck.
    func setFrame(_ rect: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let enhanced = (Self.value(of: app, Self.enhancedUserInterface) as? Bool) == true
        if enhanced {
            AXUIElementSetAttributeValue(app, Self.enhancedUserInterface as CFString, kCFBooleanFalse)
        }
        setSize(rect.size)
        setPosition(rect.origin)
        setSize(rect.size)
        if enhanced {
            AXUIElementSetAttributeValue(app, Self.enhancedUserInterface as CFString, kCFBooleanTrue)
        }
    }

    private static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// The window's CoreGraphics window number (same as `kCGWindowNumber`), used to match it in
    /// CGWindowList and to order Paneful's tab bar directly above it.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Brings this window to the front and activates its app.
    @MainActor
    func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Brings the window in front of the others without activating its app.
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Minimizes the window into the Dock, or restores it.
    func setMinimized(_ minimized: Bool) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Presses the window's close button, as if the user clicked it.
    func close() {
        guard let raw = Self.value(of: element, kAXCloseButtonAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString)
    }

    // MARK: - Lookup helpers

    static func focused(inApp pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let raw = value(of: app, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: raw as! AXUIElement, pid: pid)
    }

    static func windows(ofApp pid: pid_t) -> [AXWindow] {
        windowsIfResponsive(ofApp: pid) ?? []
    }

    /// The app's windows, or `nil` when the app didn't answer (hung, or not an AX-capable app).
    static func windowsIfResponsive(ofApp pid: pid_t) -> [AXWindow]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        switch error {
        case .success:
            guard let list = value as? [AXUIElement] else { return [] }
            return list.map { AXWindow(element: $0, pid: pid) }
        case .noValue, .attributeUnsupported:
            return []
        default:
            return nil
        }
    }
}
