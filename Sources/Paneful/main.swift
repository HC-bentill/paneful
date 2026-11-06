import AppKit

// Paneful runs as a menu-bar–only (accessory) app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // NSApplication.delegate is weak, and Swift may release a local after its last use in
    // optimized builds, so keep the delegate alive for the whole run loop explicitly.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
