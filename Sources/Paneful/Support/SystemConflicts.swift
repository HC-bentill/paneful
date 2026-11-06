import AppKit

/// macOS features that fight Paneful: built-in edge tiling (drag to a screen edge or the menu bar)
/// and Stage Manager, which moves windows on its own.
@MainActor
enum SystemConflicts {
    private static var windowManager: UserDefaults? { UserDefaults(suiteName: "com.apple.WindowManager") }

    /// macOS tiles windows dragged to a screen edge (on unless the user turned it off).
    static var edgeTilingOn: Bool {
        let wm = windowManager
        let edge = wm?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
        let top = wm?.object(forKey: "EnableTopTilingByEdgeDrag") as? Bool ?? true
        return edge || top
    }

    static var stageManagerOn: Bool { windowManager?.bool(forKey: "GloballyEnabled") ?? false }

    /// System Settings → Desktop & Dock, where both can be turned off.
    static func openDesktopSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
