<p align="center"><img src="Resources/Logo/AppIcon-1024.png" width="160" alt="Paneful icon"></p>

# Paneful Desktop Manager

**Snap windows side by side and group windows from any app into tabs, on macOS.**

<p align="center">
  <a href="https://paneful.vercel.app"><b>Website</b></a> ·
  <a href="https://paneful.vercel.app/docs/"><b>Docs &amp; demos</b></a> ·
  <a href="https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg"><b>Download</b></a>
</p>

Paneful is a free, open-source menu-bar app for macOS. It brings two things macOS doesn't have:

- **Window snapping.** Drag a window to a screen edge (or press a shortcut) and it snaps to half, a quarter
  or full screen, with a live blurred preview of where it will land.
- **Cross-app tab groups.** Stack windows from *different* apps (say, a browser and Microsoft Teams) into
  one frame with a floating tab bar on top. Click a tab to switch, and move or resize the group as one window.
- **Remembered groups.** Paneful remembers your tab groups across app restarts, reboots and its own
  relaunches. Quit Teams, reopen it, and its window tabs itself back into the group. New windows float.

The **[documentation](https://paneful.vercel.app/docs/)** has an animated demo for every feature.
See [FEATURES.md](FEATURES.md) for the full and upcoming feature list (auto-tiling is next).

## Download
Get **[Paneful.dmg](https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg)** (latest release),
open it and drag Paneful to Applications. If macOS says it can't verify the developer, open
System Settings → Privacy & Security and click **Open Anyway**. Then allow Paneful under Accessibility.
All versions are on the [Releases](https://github.com/HC-bentill/paneful/releases) page.

## Requirements
- macOS 27.2 or later
- Swift toolchain 5.10+ (Xcode or Command Line Tools) to build from source

## Build & run

```bash
git clone https://github.com/HC-bentill/paneful.git
cd paneful
./scripts/bundle.sh          # builds build/Paneful.app
open build/Paneful.app
```

On first launch macOS asks for **Accessibility** access
(System Settings → Privacy & Security → Accessibility). Paneful needs it to move, resize and raise other
apps' windows. After you allow it, Paneful starts working without a relaunch.

> `bundle.sh` signs with your "Apple Development" certificate if you have one (or `$PANEFUL_SIGN_IDENTITY`),
> so the permission survives rebuilds. Without one it signs ad-hoc. In that case, if Paneful stops working
> after a rebuild, remove it from the Accessibility list and add it again.

Run the unit tests with `swift test`.

## How to use
To see each of these in action, watch the animated demos in the [docs](https://paneful.vercel.app/docs/):
[snapping](https://paneful.vercel.app/docs/#drag-to-snap), [tab groups](https://paneful.vercel.app/docs/#tab-groups),
[remembered groups](https://paneful.vercel.app/docs/#remembered),
[shortcuts](https://paneful.vercel.app/docs/#shortcuts) and
[troubleshooting](https://paneful.vercel.app/docs/#troubleshooting).

### Snapping
| Action | How |
|---|---|
| Snap to left / right half | Drag the window to the left / right edge, or ⌃⌥← / ⌃⌥→ |
| Top / bottom half | ⌃⌥↑ / ⌃⌥↓ |
| Quarters | Drag to a corner, or ⌃⌥U / I / J / K |
| Maximize | Drag to the top edge, or ⌃⌥↩ |
| Center | ⌃⌥C |
| Side by side with previous window | ⌃⌥S |

### Tab groups
| Action | How |
|---|---|
| Make a group / add a tab | Drag a window onto the top of another window (its title bar or toolbar) or onto a tab bar. Hold it there until the preview says **Release to add as a tab**, then let go. Or press ⌃⌥T to tab the focused window with the previous one |
| Switch tab | Click it, or ⌃⌥] / ⌃⌥[ |
| Remove a tab | Hover and click ✕, drag the tab down out of the bar, right-click → Move Out of Group, or ⌃⌥W |
| Close a tab's window | Right-click → Close Window (the group still remembers it) |
| Ungroup | Right-click a tab → Ungroup All, or the menu-bar menu |
| Minimize a tab | It leaves the group while minimized and comes back as the active tab when restored |
| Minimize the whole group | ⌃⌥M, menu bar → Minimize Group, or right-click a tab → Minimize Group. Restoring any of its windows from the Dock brings the whole group back |

### Remembered groups
- Groups are saved in `~/Library/Application Support/Paneful/groups.json`.
- When a window from a remembered group opens again, it joins its group as a tab within a few seconds of
  appearing. Windows are matched by app, plus the window title when the app has several windows.
- Windows that Paneful has never seen in a group float. They only join a group when you drag them in or press ⌃⌥T.
- Removing a tab or ungrouping forgets it. Closing a window, quitting the app or quitting Paneful does not.
- Menu bar → **Remembered Groups** lists saved groups, so you can forget one or all of them. Switch auto-tabbing
  off with **Auto-tab Remembered Windows**.

Everything is also in the menu-bar icon, where you can switch off drag-to-snap and drag-to-tab, and turn on
Launch at Login. If macOS's own edge tiling or Stage Manager is on, the menu warns you, because both fight
Paneful, and links to the setting that turns them off.

## How it works
- **Accessibility API (`AXUIElement`)** moves, resizes and raises other apps' windows.
- **A global mouse monitor** detects window drags, and a borderless blurred `NSPanel` shows the snap preview.
- **Tab groups** keep every window in the group at the same frame and raise the selected one. An `AXObserver`
  watches the visible window, so when you move or resize it, the hidden tabs follow and the SwiftUI tab bar
  repositions.
- **Remembered groups** are stored as JSON. Paneful watches the apps that have closed group members, and when
  one opens a new window that matches, it tabs that window back in.
- **Carbon `RegisterEventHotKey`** handles the global shortcuts.

```
Sources/Paneful/
├── App/            AppDelegate, menu-bar menu
├── Accessibility/  AXWindow wrapper, window queries, permissions
├── Snapping/       snap zones, drag controller, preview panel, window actions
├── Tabs/           tab-group manager, floating tab bar, remembered-group store
├── Hotkeys/        global shortcuts
└── Support/        coordinate conversion, settings, macOS conflict checks
Tests/PanefulTests/ unit tests (swift test)
```

## Known limitations
- Some apps enforce minimum sizes or animate their own resizes, so they may not fill a tile exactly.
- Full-screen (green button) windows can't be tiled or grouped.
- Shortcuts that clash with other window managers (e.g. Rectangle's ⌃⌥ arrows) fail to register. Quit the
  other app or change one of them.
- Not on the Mac App Store: window managers can't run inside the App Store sandbox.

## Contributing
Issues and pull requests are welcome. Please describe the app(s) involved when reporting window glitches.
The website and docs live in a separate repo,
[paneful-desktop-manager-landing-page](https://github.com/HC-bentill/paneful-desktop-manager-landing-page).

## License
[MIT](LICENSE) © 2026 Henry Bentil
