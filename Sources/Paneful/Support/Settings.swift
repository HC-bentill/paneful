import Foundation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
enum Settings {
    private static let defaults = UserDefaults.standard

    static var dragToSnap: Bool {
        get { defaults.object(forKey: "dragToSnap") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dragToSnap") }
    }

    static var dragToTab: Bool {
        get { defaults.object(forKey: "dragToTab") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dragToTab") }
    }

    /// Windows that belonged to a remembered tab group rejoin it as a tab when they open again.
    static var autoTabRemembered: Bool {
        get { defaults.object(forKey: "autoTabRemembered") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoTabRemembered") }
    }

    /// Works only when running from the bundled Paneful.app.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Paneful: launch-at-login change failed: \(error)")
            }
        }
    }
}
