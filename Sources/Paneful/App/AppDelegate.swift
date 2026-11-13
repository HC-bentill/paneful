import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dragController = DragController()
    private var permissionTimer: Timer?
    private var tickTimer: Timer?
    private var engineStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard resolveOtherCopies() else { return }
        setupStatusItem()

        if Permissions.isTrusted {
            Permissions.recordTrusted()
            startEngine()
        } else {
            // After an update, macOS may still list the previous version's entry, which no longer applies
            // and stops it from asking again. Clear it so the prompt below appears.
            Permissions.clearStaleGrantIfUpdated()
            Permissions.prompt()
            // Poll until the user grants Accessibility access, then start without a relaunch.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard Permissions.isTrusted else { return }
                    timer.invalidate()
                    Permissions.recordTrusted()
                    self?.startEngine()
                }
            }
        }
    }

    /// Two copies of Paneful (say, an installed one and a development build) would fight over the same windows,
    /// and resetting this copy's Accessibility entry would also cut the other one off. Offers to quit the
    /// other copy. Returns false when this copy is quitting instead.
    private func resolveOtherCopies() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != WindowQuery.ownPID }
        guard !others.isEmpty else { return true }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Another copy of Paneful is running"
        let path = others.first?.bundleURL?.path ?? "another location"
        alert.informativeText = "It's running from \(path). Two copies would fight over the same windows. Quit it and use this one?"
        alert.addButton(withTitle: "Quit the Other Copy")
        alert.addButton(withTitle: "Quit This One")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }
        others.forEach { $0.terminate() }
        // Give it a moment to put its windows back and save its groups.
        let deadline = Date().addingTimeInterval(4)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        Log.app.notice("Quit the other copy of Paneful at \(path, privacy: .public)")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The groups are loaded when the engine starts. Quitting before that (still waiting for Accessibility,
        // or "Quit This One") would save an empty list over the remembered groups.
        guard engineStarted else { return }
        // Leave every window visible at its group's full frame, but keep the groups remembered.
        TabGroupManager.shared.suspendAll()
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        SystemState.shared.start()
        DefaultShortcuts.registerAll()
        dragController.start()
        TabGroupManager.shared.start()
        CloseButtonInterceptor.shared.start()
        AutoTiler.shared.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                FocusTracker.shared.update()
                TabGroupManager.shared.refresh()
                // Not while a tab group is carried to another desktop: windows change desktops on purpose.
                if !DesktopMover.shared.isBusy { AutoTiler.shared.update() }
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
            if Permissions.clearedStaleGrant {
                let note = NSMenuItem(title: "Paneful was updated: switch it on again in Accessibility",
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
            let grant = item("⚠︎ Grant Accessibility Access…", #selector(openAccessibility))
            grant.toolTip = "Removes any old Paneful entry, asks again and opens the Accessibility settings, where you switch Paneful on."
            menu.addItem(grant)
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
        menu.addItem(savedLayoutsItem())
        menu.addItem(.separator())
        menu.addItem(item("Tab with Previous Window\t⌃⌥T", #selector(tabWithPrevious)))
        menu.addItem(item("Next Tab\t⌃⌥]", #selector(nextTab)))
        menu.addItem(item("Previous Tab\t⌃⌥[", #selector(previousTab)))
        menu.addItem(item("Remove Window from Group\t⌃⌥W", #selector(removeFromGroup)))
        menu.addItem(item("Minimize Group\t⌃⌥M", #selector(minimizeGroup)))
        let ungroup = item("Ungroup All", #selector(ungroupAll))
        ungroup.isEnabled = TabGroupManager.shared.groups.contains { $0.isFormed }
        menu.addItem(ungroup)
        menu.addItem(rememberedGroupsItem())
        menu.addItem(.separator())

        let tiling = toggle("Auto-tile New Windows", Settings.autoTiling, #selector(toggleAutoTiling))
        tiling.toolTip = "New windows take a tile: the window you were using moves to the left half, new ones stack on the right."
        menu.addItem(tiling)
        let tabbing = toggle("Auto-tab New Windows", Settings.autoTabNewWindows, #selector(toggleAutoTabNew))
        tabbing.toolTip = "New windows join the tab group of the window you were using (or start one with it)."
        menu.addItem(tabbing)
        menu.addItem(autoTilingItem())
        menu.addItem(.separator())

        menu.addItem(toggle("Drag to Screen Edge to Snap", Settings.dragToSnap, #selector(toggleDragSnap)))
        menu.addItem(toggle("Drag onto Title Bar to Tab", Settings.dragToTab, #selector(toggleDragTab)))
        menu.addItem(toggle("Auto-tab Remembered Windows", Settings.autoTabRemembered, #selector(toggleAutoTab)))
        let closeMinimizes = toggle("Close Button Minimizes Tabs", Settings.closeButtonMinimizesTabs,
                                    #selector(toggleCloseMinimizes))
        closeMinimizes.toolTip = "In a tab group, the red close button sends the window to the Dock instead of closing it. ⌥-click it to close."
        menu.addItem(closeMinimizes)
        let greenFills = toggle("Green Button Fills Screen", Settings.greenButtonFillsGroups,
                                #selector(toggleGreenFills))
        greenFills.toolTip = "In a tab group, the green button makes the whole group fill the screen, and clicking it again restores its size. ⌥-click it for macOS full screen for that window alone."
        menu.addItem(greenFills)
        let barMoves = toggle("Move Whole Group Between Desktops", Settings.dragBarMovesGroup,
                              #selector(toggleBarMovesGroup))
        barMoves.toolTip = "In Mission Control, drag a group's tab bar, or one of its windows, onto another desktop and Paneful drags the rest of the group there too (macOS has no faster way). Off: the bar goes back to its windows, and a moved window's tab is dimmed."
        menu.addItem(barMoves)
        menu.addItem(toggle("Launch at Login", Settings.launchAtLogin, #selector(toggleLaunchAtLogin)))
        menu.addItem(.separator())
        menu.addItem(item("About Paneful", #selector(about)))
        menu.addItem(NSMenuItem(title: "Quit Paneful", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "Auto-tiling" submenu: float or tile the focused window, per-app float rule, float everything.
    private func autoTilingItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Auto-tiling", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let on = AutoTiler.shared.isEnabled

        let window = WindowActions.currentWindow
        let tiled = window.map { AutoTiler.shared.isTiled($0) } ?? false
        let focus = item(tiled ? "Float Focused Window\t⌃⌥F" : "Tile Focused Window\t⌃⌥F", #selector(toggleTiling))
        focus.isEnabled = on && window != nil
        sub.addItem(focus)

        let app = NSWorkspace.shared.frontmostApplication
        if let app, let bundle = app.bundleIdentifier, app.processIdentifier != WindowQuery.ownPID {
            let floats = AutoTiler.shared.alwaysFloats(bundleID: bundle)
            let rule = toggle("Always Float \(app.localizedName ?? bundle)", floats, #selector(toggleAlwaysFloat(_:)))
            rule.representedObject = bundle
            // Built-in rules (System Settings, installers) can't be switched off; a rule of your own can
            // be removed even while auto-tiling and auto-tab are off.
            rule.isEnabled = !AutoTiler.shared.floatsByDefault(bundleID: bundle)
                && (on || AutoTiler.shared.autoTabsNewWindows || floats)
            rule.toolTip = "Paneful never tiles or auto-tabs this app's new windows."
            sub.addItem(rule)
        }

        let floatAll = item("Float All Windows", #selector(floatAllWindows))
        floatAll.isEnabled = on
        floatAll.toolTip = "Stop arranging the current windows and leave them where they are. New windows are still tiled."
        sub.addItem(floatAll)

        root.submenu = sub
        return root
    }

    /// "Saved Layouts" submenu: restore (⌃⌥1…9), save (⌃⌥⇧1…9) and forget numbered layouts.
    private func savedLayoutsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Saved Layouts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let layouts = SavedLayouts.shared.all
        if layouts.isEmpty {
            for line in ["No saved layouts yet", "Arrange your windows, then press ⌃⌥⇧1…9"] {
                let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
            }
        }
        for layout in layouts {
            let restore = item("Layout \(layout.number): \(layout.summary)\t⌃⌥\(layout.number)", #selector(restoreLayout(_:)))
            restore.representedObject = layout.number
            let windows = layout.windowCount == 1 ? "1 window" : "\(layout.windowCount) windows"
            restore.toolTip = "\(windows), saved \(layout.savedAt.formatted(date: .abbreviated, time: .shortened))"
            sub.addItem(restore)
        }
        sub.addItem(.separator())

        let saveMenu = NSMenu()
        for number in SavedLayouts.numbers {
            let title = SavedLayouts.shared.layout(number).map { "\(number) (replaces \($0.summary))" } ?? "\(number)"
            let save = item("\(title)\t⌃⌥⇧\(number)", #selector(saveLayout(_:)))
            save.representedObject = number
            saveMenu.addItem(save)
        }
        let saveRoot = NSMenuItem(title: "Save Current Layout As", action: nil, keyEquivalent: "")
        saveRoot.submenu = saveMenu
        sub.addItem(saveRoot)

        if !layouts.isEmpty {
            let forgetMenu = NSMenu()
            for layout in layouts {
                let forget = item("Layout \(layout.number): \(layout.summary)", #selector(forgetLayout(_:)))
                forget.representedObject = layout.number
                forgetMenu.addItem(forget)
            }
            let forgetRoot = NSMenuItem(title: "Forget Layout", action: nil, keyEquivalent: "")
            forgetRoot.submenu = forgetMenu
            sub.addItem(forgetRoot)
        }
        root.submenu = sub
        return root
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
            if let desktop = TabGroupManager.shared.desktopName(of: group) {
                let line = NSMenuItem(title: "On \(desktop)", action: nil, keyEquivalent: "")
                line.isEnabled = false
                detail.addItem(line)
            }
            for member in group.members {
                let state = member.window == nil ? "closed"
                    : member.minimized ? "minimized" : member.hidden ? "hidden"
                    : member.fullScreen ? "full screen" : member.elsewhere ? "on another desktop" : "open"
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

    @objc private func openAccessibility() { Permissions.repair() }
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
    @objc private func minimizeGroup() { WindowActions.minimizeGroup() }
    @objc private func ungroupAll() { WindowActions.ungroupAll() }

    @objc private func forgetGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        TabGroupManager.shared.forgetGroup(id: id)
    }

    @objc private func forgetAllGroups() { TabGroupManager.shared.forgetAll() }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        SavedLayouts.shared.restore(number)
    }

    @objc private func saveLayout(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        SavedLayouts.shared.save(number)
    }

    @objc private func forgetLayout(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        SavedLayouts.shared.forget(number)
    }

    @objc private func toggleDragSnap() { Settings.dragToSnap.toggle() }
    @objc private func toggleDragTab() { Settings.dragToTab.toggle() }
    @objc private func toggleAutoTab() { Settings.autoTabRemembered.toggle() }
    @objc private func toggleLaunchAtLogin() { Settings.launchAtLogin.toggle() }
    @objc private func toggleCloseMinimizes() { Settings.closeButtonMinimizesTabs.toggle() }
    @objc private func toggleGreenFills() { Settings.greenButtonFillsGroups.toggle() }
    @objc private func toggleBarMovesGroup() { Settings.dragBarMovesGroup.toggle() }
    @objc private func toggleAutoTiling() { AutoTiler.shared.setEnabled(!Settings.autoTiling) }
    @objc private func toggleAutoTabNew() { AutoTiler.shared.setAutoTab(!Settings.autoTabNewWindows) }
    @objc private func toggleTiling() { WindowActions.toggleTiling() }
    @objc private func floatAllWindows() { AutoTiler.shared.floatAll() }

    @objc private func toggleAlwaysFloat(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        AutoTiler.shared.toggleAlwaysFloat(bundleID: bundle)
    }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Paneful Desktop Manager",
            .credits: NSAttributedString(string: "Snap windows side by side, group any apps into tabs that are remembered across restarts, auto-tile new windows, and save layouts you can bring back with a shortcut.\nOpen source under the MIT License."),
        ])
    }
}
