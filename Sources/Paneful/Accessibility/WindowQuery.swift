import AppKit
import ApplicationServices

/// Finds windows on screen: the focused one, the one under the cursor, the one beneath a dragged window.
@MainActor
enum WindowQuery {
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// The focused window of the frontmost app (ignoring Paneful itself).
    static func focusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID else { return nil }
        return AXWindow.focused(inApp: app.processIdentifier)
    }

    /// The top-level window at a point in AX coordinates.
    static func window(atAX point: CGPoint) -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }

        // Walk up from the clicked element to its window.
        for _ in 0..<32 {
            if (AXWindow.value(of: element, kAXRoleAttribute) as? String) == kAXWindowRole {
                guard let window = AXWindow(element: element), window.pid != ownPID else { return nil }
                return window
            }
            if let raw = AXWindow.value(of: element, kAXWindowAttribute),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                element = raw as! AXUIElement
                continue
            }
            guard let parent = AXWindow.value(of: element, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// The front-most normal window containing `point` (AX coords), skipping `excluded`.
    /// Used while dragging, where the dragged window itself is under the cursor.
    static func window(belowAX point: CGPoint, excluding excluded: AXWindow?) -> AXWindow? {
        let excludedFrame = excluded?.frame
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }

        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point) else { continue }

            if let excluded, let excludedFrame, pid == excluded.pid, bounds.isClose(to: excludedFrame) {
                continue
            }
            return AXWindow.windows(ofApp: pid).first { $0.frame?.isClose(to: bounds) == true }
        }
        return nil
    }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
