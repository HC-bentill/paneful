# Paneful Desktop Manager

**Snap windows side by side and group windows from any app into tabs, on macOS.**

Paneful is a free, open-source menu-bar app for macOS. It brings two things macOS doesn't have:

- **Window snapping.** Drag a window to a screen edge (or press a shortcut) and it snaps to half, a quarter
  or full screen, with a live blurred preview of where it will land.
- **Cross-app tab groups.** Stack windows from *different* apps (say, a browser and Microsoft Teams) into
  one frame with a floating tab bar on top. Click a tab to switch, and move or resize the group as one window.

See [FEATURES.md](FEATURES.md) for the full and upcoming feature list (auto-tiling is next).

## Requirements
- macOS 27.2 or later
- Swift toolchain 5.10+ (Xcode or Command Line Tools) to build from source

## Build & run

```bash
git clone https://github.com/<your-username>/paneful.git
cd paneful
./scripts/bundle.sh          # builds build/Paneful.app
open build/Paneful.app
```

On first launch macOS asks for **Accessibility** access
(System Settings → Privacy & Security → Accessibility). Paneful needs it to move, resize and raise other
apps' windows. After you allow it, Paneful starts working without a relaunch.

> If you rebuild and Paneful stops working, remove it from the Accessibility list and add it again.
> macOS ties the permission to the app's signature.

## How to use

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
| Make a group / add a tab | Drag a window onto another window's title bar (or an existing tab bar), or ⌃⌥T to tab the focused window with the previous one |
| Switch tab | Click it, or ⌃⌥] / ⌃⌥[ |
| Remove a tab | Hover and click ✕, right-click → Remove from Group, or ⌃⌥W |
| Ungroup everything | Right-click a tab → Ungroup All, or the menu-bar menu |

Everything is also in the menu-bar icon, where you can switch off drag-to-snap and drag-to-tab, and turn on
Launch at Login.

## How it works
- **Accessibility API (`AXUIElement`)** moves, resizes and raises other apps' windows.
- **A global mouse monitor** detects window drags, and a borderless blurred `NSPanel` shows the snap preview.
- **Tab groups** keep every window in the group at the same frame and raise the selected one. An `AXObserver`
  watches the visible window, so when you move or resize it, the hidden tabs follow and the SwiftUI tab bar
  repositions.
- **Carbon `RegisterEventHotKey`** handles the global shortcuts.

```
Sources/Paneful/
├── App/            AppDelegate, menu-bar menu
├── Accessibility/  AXWindow wrapper, window queries, permissions
├── Snapping/       snap zones, drag controller, preview panel, window actions
├── Tabs/           tab-group manager and floating tab bar
├── Hotkeys/        global shortcuts
└── Support/        coordinate conversion, settings
```

## Known limitations
- Some apps enforce minimum sizes or animate their own resizes, so they may not fill a tile exactly.
- Full-screen (green button) windows can't be tiled or grouped.
- Shortcuts that clash with other window managers (e.g. Rectangle's ⌃⌥ arrows) fail to register. Quit the
  other app or change one of them.
- Not on the Mac App Store: window managers can't run inside the App Store sandbox.

## Contributing
Issues and pull requests are welcome. Please describe the app(s) involved when reporting window glitches.

## License
[MIT](LICENSE) © 2026 Henry Bentil
