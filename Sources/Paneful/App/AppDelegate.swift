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
        // Leave every window visible at its group's full frame, but keep the groups remembered.
        TabGroupManager.shared.suspendAll()
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
            button.image = Brand.menuBarIcon()
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
        if SystemConflicts.edgeTilingOn || SystemConflicts.stageManagerOn {
            let what = [SystemConflicts.edgeTilingOn ? "macOS edge tiling" : nil,
                        SystemConflicts.stageManagerOn ? "Stage Manager" : nil].compactMap { $0 }
            let warning = item("⚠︎ Turn Off \(what.joined(separator: " and "))…", #selector(openDesktopSettings))
            warning.toolTip = "These macOS features also move windows and conflict with Paneful."
            menu.addItem(warning)
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
        ungroup.isEnabled = TabGroupManager.shared.groups.contains { $0.isFormed }
        menu.addItem(ungroup)
        menu.addItem(rememberedGroupsItem())
        menu.addItem(.separator())

        menu.addItem(toggle("Drag to Screen Edge to Snap", Settings.dragToSnap, #selector(toggleDragSnap)))
        menu.addItem(toggle("Drag onto Title Bar to Tab", Settings.dragToTab, #selector(toggleDragTab)))
        menu.addItem(toggle("Auto-tab Remembered Windows", Settings.autoTabRemembered, #selector(toggleAutoTab)))
        menu.addItem(toggle("Launch at Login", Settings.launchAtLogin, #selector(toggleLaunchAtLogin)))
        menu.addItem(.separator())
        menu.addItem(item("About Paneful", #selector(about)))
        menu.addItem(NSMenuItem(title: "Quit Paneful", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "Remembered Groups" submenu: review and forget saved groups.
    private func rememberedGroupsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Remembered Groups", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let groups = TabGroupManager.shared.groups
        if groups.isEmpty {
            let none = NSMenuItem(title: "No remembered groups", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for group in groups {
            let open = group.windows.count
            let entry = NSMenuItem(title: group.displayName, action: nil, keyEquivalent: "")
            let detail = NSMenu()
            for member in group.members {
                let state = member.window == nil ? "closed" : (member.minimized ? "minimized" : "open")
                let hint = member.signature.titleHint.map { " — \($0)" } ?? ""
                let line = NSMenuItem(title: "\(member.signature.appName)\(hint) (\(state))", action: nil, keyEquivalent: "")
                line.isEnabled = false
                detail.addItem(line)
            }
            detail.addItem(.separator())
            let forget = item("Forget This Group", #selector(forgetGroup(_:)))
            forget.representedObject = group.id
            detail.addItem(forget)
            entry.submenu = detail
            if open >= 2 { entry.state = .on }   // ✓ = currently formed on screen
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let forgetAll = item("Forget All Remembered Groups", #selector(forgetAllGroups))
        forgetAll.isEnabled = !groups.isEmpty
        sub.addItem(forgetAll)
        root.submenu = sub
        return root
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
    @objc private func openDesktopSettings() { SystemConflicts.openDesktopSettings() }

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

    @objc private func forgetGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        TabGroupManager.shared.forgetGroup(id: id)
    }

    @objc private func forgetAllGroups() { TabGroupManager.shared.forgetAll() }

    @objc private func toggleDragSnap() { Settings.dragToSnap.toggle() }
    @objc private func toggleDragTab() { Settings.dragToTab.toggle() }
    @objc private func toggleAutoTab() { Settings.autoTabRemembered.toggle() }
    @objc private func toggleLaunchAtLogin() { Settings.launchAtLogin.toggle() }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Paneful Desktop Manager",
            .credits: NSAttributedString(string: "Snap windows side by side and group any apps into tabs that are remembered across restarts.\nOpen source under the MIT License."),
        ])
    }
}
