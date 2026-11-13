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

    /// In a tab group, the red close button sends the window to the Dock instead of closing it.
    static var closeButtonMinimizesTabs: Bool {
        get { defaults.object(forKey: "closeButtonMinimizesTabs") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "closeButtonMinimizesTabs") }
    }

    /// In a tab group, the green button makes the whole group fill the screen (and clicking it again puts it
    /// back). ⌥-click gives just that window macOS's own full screen.
    static var greenButtonFillsGroups: Bool {
        get { defaults.object(forKey: "greenButtonFillsGroups") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "greenButtonFillsGroups") }
    }

    /// Dragging a tab bar onto another desktop in Mission Control carries the whole group there. Off: the bar
    /// goes back to its windows.
    static var dragBarMovesGroup: Bool {
        get { defaults.object(forKey: "dragBarMovesGroup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dragBarMovesGroup") }
    }

    /// New windows take a tile: the screen splits into a main column and a stack. Off by default.
    static var autoTiling: Bool {
        get { defaults.object(forKey: "autoTiling") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "autoTiling") }
    }

    /// New windows join the tab group of the window you were using (or start one with it). Off by default.
    static var autoTabNewWindows: Bool {
        get { defaults.object(forKey: "autoTabNewWindows") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "autoTabNewWindows") }
    }

    /// Apps whose new windows are never tiled or auto-tabbed ("Always Float <app>").
    static var alwaysFloatBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "alwaysFloatBundleIDs") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "alwaysFloatBundleIDs") }
    }

    /// Works only when running from the bundled Paneful.app.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Launch-at-login change failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
