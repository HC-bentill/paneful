import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dragController = DragController()
    private var permissionTimer: Timer?
    private var tickTimer: Timer?
    private var engineStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        if Permissions.isTrusted {
            startEngine()
        } else {
            Permissions.prompt()
            // Poll until the user grants Accessibility access, then start without a relaunch.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard Permissions.isTrusted else { return }
                    timer.invalidate()
                    self?.startEngine()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave windows in a sane state when quitting.
        TabGroupManager.shared.ungroupAll()
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        DefaultShortcuts.registerAll()
        dragController.start()
        TabGroupManager.shared.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                FocusTracker.shared.update()
                TabGroupManager.shared.refresh()
            }
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Paneful")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt every time it opens so toggles and permission state are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Paneful Desktop Manager", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !Permissions.isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        let snapMenu = NSMenu()
        let zones: [(SnapZone, String)] = [
            (.leftHalf, "←"), (.rightHalf, "→"), (.topHalf, "↑"), (.bottomHalf, "↓"),
            (.maximize, "↩"), (.center, "C"),
            (.topLeft, "U"), (.topRight, "I"), (.bottomLeft, "J"), (.bottomRight, "K"),
        ]
        for (zone, key) in zones {
            let mi = item("\(zone.title)\t⌃⌥\(key)", #selector(snapFromMenu(_:)))
            mi.representedObject = zone.rawValue
            snapMenu.addItem(mi)
        }
        let snapRoot = NSMenuItem(title: "Snap Window", action: nil, keyEquivalent: "")
        snapRoot.submenu = snapMenu
        menu.addItem(snapRoot)

        menu.addItem(item("Side by Side with Previous Window\t⌃⌥S", #selector(sideBySide)))
        menu.addItem(.separator())
        menu.addItem(item("Tab with Previous Window\t⌃⌥T", #selector(tabWithPrevious)))
        menu.addItem(item("Next Tab\t⌃⌥]", #selector(nextTab)))
        menu.addItem(item("Previous Tab\t⌃⌥[", #selector(previousTab)))
        menu.addItem(item("Remove Window from Group\t⌃⌥W", #selector(removeFromGroup)))
        let ungroup = item("Ungroup All", #selector(ungroupAll))
        ungroup.isEnabled = !TabGroupManager.shared.groups.isEmpty
        menu.addItem(ungroup)
        menu.addItem(.separator())

        menu.addItem(toggle("Drag to Screen Edge to Snap", Settings.dragToSnap, #selector(toggleDragSnap)))
        menu.addItem(toggle("Drag onto Title Bar to Tab", Settings.dragToTab, #selector(toggleDragTab)))
        menu.addItem(toggle("Launch at Login", Settings.launchAtLogin, #selector(toggleLaunchAtLogin)))
        menu.addItem(.separator())
        menu.addItem(item("About Paneful", #selector(about)))
        menu.addItem(NSMenuItem(title: "Quit Paneful", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let mi = item(title, action)
        mi.state = on ? .on : .off
        return mi
    }

    // MARK: - Actions

    @objc private func openAccessibility() { Permissions.openSystemSettings() }

    @objc private func snapFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let zone = SnapZone(rawValue: raw) else { return }
        WindowActions.snap(zone)
    }

    @objc private func sideBySide() { WindowActions.sideBySide() }
    @objc private func tabWithPrevious() { WindowActions.tabWithPrevious() }
    @objc private func nextTab() { WindowActions.nextTab() }
    @objc private func previousTab() { WindowActions.previousTab() }
    @objc private func removeFromGroup() { WindowActions.removeFromGroup() }
    @objc private func ungroupAll() { WindowActions.ungroupAll() }

    @objc private func toggleDragSnap() { Settings.dragToSnap.toggle() }
    @objc private func toggleDragTab() { Settings.dragToTab.toggle() }
    @objc private func toggleLaunchAtLogin() { Settings.launchAtLogin.toggle() }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Paneful Desktop Manager",
            .credits: NSAttributedString(string: "Snap windows side by side and group any apps into tabs.\nOpen source under the MIT License."),
        ])
    }
}
