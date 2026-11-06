import AppKit
import ApplicationServices

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

    /// Frame in AX coordinates. `nil` when the window no longer exists.
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
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
    func setFrame(_ rect: CGRect) {
        setSize(rect.size)
        setPosition(rect.origin)
        setSize(rect.size)
    }

    /// Brings this window to the front and activates its app.
    @MainActor
    func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
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
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let list = value(of: app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.map { AXWindow(element: $0, pid: pid) }
    }
}
