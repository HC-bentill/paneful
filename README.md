<p align="center"><img src="Resources/Logo/AppIcon-1024.png" width="160" alt="Paneful icon"></p>

# Paneful Desktop Manager

**Snap windows side by side, group windows from any app into tabs, and auto-tile new windows, on macOS.**

<p align="center">
  <a href="https://paneful.vercel.app"><b>Website</b></a> ·
  <a href="https://paneful.vercel.app/docs/"><b>Docs &amp; demos</b></a> ·
  <a href="https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg"><b>Download</b></a>
</p>

<p align="center">
  <a href="https://github.com/HC-bentill/paneful/actions/workflows/build.yml"><img src="https://github.com/HC-bentill/paneful/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="https://github.com/HC-bentill/paneful/releases/latest"><img src="https://img.shields.io/github/v/release/HC-bentill/paneful" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
  <a href="https://github.com/HC-bentill/paneful/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22"><img src="https://img.shields.io/github/issues/HC-bentill/paneful/good%20first%20issue?color=7057ff&label=good%20first%20issues" alt="Good first issues"></a>
  <img src="https://img.shields.io/badge/macOS-27.2%2B-black" alt="macOS 27.2+">
</p>

Paneful is a free, open-source menu-bar app for macOS. It brings things macOS doesn't have:

- **Window snapping.** Drag a window to a screen edge (or press a shortcut) and it snaps to half, a quarter
  or full screen, with a live blurred preview of where it will land.
- **Cross-app tab groups.** Stack windows from *different* apps (say, a browser and Microsoft Teams) into
  one frame with a floating tab bar on top. Click a tab to switch, and move or resize the group as one window.
- **Remembered groups.** Paneful remembers your tab groups across app restarts, reboots and its own
  relaunches. Quit Teams, reopen it, and its window tabs itself back into the group. New windows float.
- **Auto-tiling (optional, off by default).** New windows take a tile: the window you were using moves to the
  left half and new windows stack on the right. Closing one gives its space back. A tab group is one tile.
- **Drop files onto tabs.** Hold a dragged file over a tab and that tab opens, so you can drop the file into
  its window.
- **Auto-tab new windows (optional, off by default).** New windows join the tab group of the window you were
  using.
- **Saved layouts.** Press ⌃⌥⇧1 to ⌃⌥⇧9 to save where every window is (tab groups included) under that number,
  and ⌃⌥1 to ⌃⌥9 to bring the arrangement back.

The **[documentation](https://paneful.vercel.app/docs/)** has an animated demo for every feature.
See [FEATURES.md](FEATURES.md) for the full feature list.

## Download
Get **[Paneful.dmg](https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg)** (latest release),
open it and drag Paneful to Applications. If macOS says it can't verify the developer, open
System Settings → Privacy & Security and click **Open Anyway**. Then allow Paneful under Accessibility.
All versions are on the [Releases](https://github.com/HC-bentill/paneful/releases) page.

**Updating?** Quit Paneful, replace it in Applications and open the new version. If macOS asks for
Accessibility again, just switch Paneful on: Paneful removes the old version's entry itself, so there's no need
to remove it with – or to relaunch. If it still doesn't start, choose **Grant Accessibility Access…** in the
menu-bar menu.

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
[reordering tabs](https://paneful.vercel.app/docs/#reorder-tabs), [remembered groups](https://paneful.vercel.app/docs/#remembered),
[dropping files onto tabs](https://paneful.vercel.app/docs/#drop-on-tabs),
[the close button](https://paneful.vercel.app/docs/#close-button), [auto-tab new windows](https://paneful.vercel.app/docs/#auto-tab-new),
[auto-tiling](https://paneful.vercel.app/docs/#auto-tiling), [arranging tiles](https://paneful.vercel.app/docs/#arrange-tiles),
[full-screen tab groups](https://paneful.vercel.app/docs/#full-screen),
[moving a group to another desktop](https://paneful.vercel.app/docs/#desktops),
[saved layouts](https://paneful.vercel.app/docs/#saved-layouts),
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
| Reorder tabs | Drag a tab sideways. The other tabs slide aside, and it stays where you let go (**Release to move the tab here**). The order is remembered |
| Remove a tab | Drag the tab down out of the bar until it says **Release to pull out of the group**, right-click → Move Out of Group, or ⌃⌥W |
| Tab's ✕ | Hover a tab and click ✕: its window goes to the Dock and the next tab takes its place. Click it in the Dock to bring it back as the active tab (right-click → Minimize Window does the same) |
| Red close button | Sends a tabbed window to the Dock instead of closing it, and the next tab takes its place. Click it in the Dock to bring it back as the active tab. ⌥-click the button to really close the window. Switch this off with **Close Button Minimizes Tabs** in the menu. Apps that only hide their window when closed (Postman, Teams, Slack) step aside the same way |
| Green button (fill the screen) | The whole group fills the screen: tab bar along the top, windows below. Click it again to put the group back where it was. Paneful remembers this across restarts. ⌥-click it for macOS's own full screen for that window alone. Switch this off with **Green Button Fills Screen** in the menu |
| A tab goes full screen | If a tabbed window goes into macOS's own full screen (⌥-click on the green button, ⌃⌘F, or the app's View menu), its tab steps aside and the other tabs keep their size. When it leaves full screen, it comes back as the active tab |
| Tab every new window automatically | Menu bar → **Auto-tab New Windows** (off by default). A new window joins the tab group of the window you were using, or starts one with it |
| Close a tab's window | ⌥-click its red button, or right-click its tab → Close Window (the group still remembers it) |
| Drop a file into a tab | Drag a file, folder, text or image onto a tab and hold it there (**Hold to open this tab**). The tab opens (**Now drop it onto the window**); drop it into the window below |
| Ungroup | Right-click a tab → Ungroup All, or the menu-bar menu |
| Minimize a tab | Its ✕, its red button, or ⌘M. It steps out of the bar while minimized and comes back as the active tab when restored |
| Minimize the whole group | ⌃⌥M, menu bar → Minimize Group, or right-click a tab → Minimize Group. Restoring any of its windows from the Dock brings the whole group back |

**Moving a group to another desktop.** A tab group lives on one desktop (Space). In Mission Control, drag the
group's tab bar onto another desktop, and the rest of the group follows it there. macOS has no way for an app to
move another app's window between desktops, so Paneful does what you would: while Mission Control is still open,
it drags each of the group's windows onto the same desktop. That works for every app and needs no keyboard
shortcuts. You'll see the pointer do it, about a second per window. Moving the mouse meanwhile is fine; a click
or a key press stops it. Dragging just one of the group's windows to another desktop works too: the rest
of the group follows it. A window that can't be moved (say, it's in full screen) keeps a dimmed "away" tab; click
it and Paneful fetches the window through Mission Control. Switch all this off with **Move Whole Group Between
Desktops** in the menu (a moved window's tab is then dimmed until it's back with the group). Groups remember their desktop.

**Full-screen tab groups, one per desktop.** macOS's own full screen holds just one window in a Space of its
own, so a group of several apps' windows can't go there. You can get the same feel with desktops: in Mission
Control, click **+** to add a desktop for each group. Switch to it, open and group the windows there, then click
the green button. Swipe left or right with three fingers to move between groups, just like full-screen apps.
Each group's tab bar stays on its own desktop and slides in with it. For the best results, go to System Settings
→ Desktop & Dock and turn off **Automatically rearrange Spaces based on most recent use** and **When switching to
an application, switch to a Space with open windows for the application**. Set the menu bar to hide
automatically (**Always**) and the Dock to hide automatically, so the group gets the whole screen.

### Auto-tiling
Off by default. Turn it on in the menu bar: **Auto-tile New Windows**.

| Action | How |
|---|---|
| Open a new window | The window you were using moves to the left half and the new one takes the right half. More new windows stack top to bottom on the right. While an app launches, a dark placeholder with its icon holds the slot |
| Close or minimize a tiled window | The others take its space; the last one fills the screen. A minimized window comes back to the same slot |
| Swap two tiles | Drag a tiled window onto another tile and let go |
| Move a tile to another display | Drag it there; it joins that display's layout |
| Resize tiles | Drag the edge between two tiles |
| Float or tile the focused window | ⌃⌥F, or menu bar → Auto-tiling |
| Never tile an app | Menu bar → Auto-tiling → **Always Float** *app* (for the app in front) |
| Stop arranging the current windows | Menu bar → Auto-tiling → **Float All Windows** (new windows are still tiled) |

- A tab group is one tile; its tab bar spans the tile.
- Windows that were open before you turned auto-tiling on stay where they are.
- Dialogs, sheets, full-screen windows and windows that can't be resized always float. So does a window you snap
  to an edge or with a shortcut.
- Each display has its own layout, and each Space shows only its own windows.

### Saved layouts
| Action | How |
|---|---|
| Save the current arrangement | ⌃⌥⇧1 … ⌃⌥⇧9, or menu bar → Saved Layouts → **Save Current Layout As** → number. Saving under a used number replaces it |
| Bring it back | ⌃⌥1 … ⌃⌥9, or menu bar → Saved Layouts → **Layout** *n* |
| Delete one | Menu bar → Saved Layouts → **Forget Layout** |

- A layout holds every window on the current desktop (all displays): where each one sits, which is in front, and
  your tab groups with their tabs and the visible tab.
- Restoring finds each saved window among the open ones by app and title (for an app with several windows whose
  titles changed, the one nearest to where it was). It brings back minimized windows and hidden apps, forms the
  tab groups again (and splits off windows you grouped since), and restores the stacking order.
- Windows that aren't open are skipped: Paneful doesn't launch apps. Windows that aren't in the layout stay put.
- If a display is gone or changed size, its windows keep their relative place and size on the closest display.
- With auto-tiling on, restoring a layout floats the current windows. New windows are still tiled.
- Layouts are saved in `~/Library/Application Support/Paneful/layouts.json`.

### Remembered groups
- Groups are saved in `~/Library/Application Support/Paneful/groups.json`.
- When a window from a remembered group opens again, it joins its group as a tab within a few seconds of
  appearing. Windows are matched by app, plus the window title when the app has several windows.
- Windows that Paneful has never seen in a group float. They only join a group when you drag them in or press ⌃⌥T.
- Removing a tab or ungrouping forgets it. Closing a window, quitting the app or quitting Paneful does not.
- Menu bar → **Remembered Groups** lists saved groups, so you can forget one or all of them. Switch auto-tabbing
  off with **Auto-tab Remembered Windows**.

Everything is also in the menu-bar icon, where you can switch off drag-to-snap, drag-to-tab and the
close-button behaviour, turn on auto-tiling, manage saved layouts, and turn on Launch at Login. If macOS's own edge tiling or Stage Manager is on, the menu warns you, because both fight
Paneful, and links to the setting that turns them off.

## How it works
- **Accessibility API (`AXUIElement`)** moves, resizes and raises other apps' windows.
- **A global mouse monitor** detects window drags, and a borderless blurred `NSPanel` shows the snap preview.
- **Tab groups** keep every window in the group at the same frame and raise the selected one. An `AXObserver`
  watches the visible window, so when you move or resize it, the hidden tabs follow and the SwiftUI tab bar
  repositions.
- **Remembered groups** are stored as JSON. Paneful watches the apps that have closed group members, and when
  one opens a new window that matches, it tabs that window back in.
- **Auto-tiling** compares the window server's window list with every window seen before to spot new windows,
  and keeps a main-and-stack layout per display.
- **An event tap** sees clicks on a tabbed window's red and green buttons: red minimizes the window instead,
  green makes the whole group fill the screen.
- **Desktops (Spaces)** are read with private, read-only window-server calls (as AltTab and Hammerspoon do). To
  carry a group to another desktop, Paneful drags each window onto it in Mission Control, reading where
  everything is through Accessibility; the private "move window to space" calls only work on Paneful's own
  windows.
- **The tab bar is a drag destination**, so holding a dragged file over a tab opens it (spring-loading).
- **Saved layouts** record each window's app, title and frame, front to back. Restoring pairs them with the open
  windows (same title, then similar title, then nearest) and fits frames to the displays connected now.
- **Sleep, lock and display changes** pause Paneful's window checks until the screens have settled, so groups
  don't drift.
- **Carbon `RegisterEventHotKey`** handles the global shortcuts.

```
Sources/Paneful/
├── App/            AppDelegate, menu-bar menu
├── Accessibility/  AXWindow wrapper, window queries, permissions
├── Snapping/       snap zones, drag controller, preview panel, window actions
├── Tabs/           tab-group manager, floating tab bar, remembered-group store, close-button interceptor
├── Tiling/         auto-tiler, layout math, placeholder tiles
├── Layouts/        saved layouts: capture and restore, window matching, layouts.json store
├── Hotkeys/        global shortcuts
└── Support/        coordinate conversion, settings, sleep/lock state, macOS conflict checks
Tests/PanefulTests/ unit tests (swift test)
```

## Known limitations
- Some apps enforce minimum sizes or animate their own resizes, so they may not fill a tile exactly.
- Windows in macOS's own full screen can't be tiled, snapped or added to a group (the snap shortcuts beep).
  A tab group fills the screen with the green button instead, on its normal desktop.
- Paneful can't create desktops. It moves a group between desktops by switching desktops while holding each
  window, so you see the desktops slide, and it only works between desktops of the same display.
- Shortcuts that clash with other window managers (e.g. Rectangle's ⌃⌥ arrows) fail to register. Quit the
  other app or change one of them.
- Not on the Mac App Store: window managers can't run inside the App Store sandbox.

## Contributing
Contributions are very welcome, from your first PR to a whole new feature.

- Read **[CONTRIBUTING.md](CONTRIBUTING.md)** for setup, the code tour and how to test window behaviour.
- Pick an issue labelled **[good first issue](https://github.com/HC-bentill/paneful/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)**
  or **[help wanted](https://github.com/HC-bentill/paneful/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)**.
- Have a question or idea? Start a [Discussion](https://github.com/HC-bentill/paneful/discussions).
- Found a bug? Use the bug report template and say which apps are involved.

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately (see [SECURITY.md](SECURITY.md)).

The website and the animated docs live in a separate repo,
[paneful-desktop-manager-landing-page](https://github.com/HC-bentill/paneful-desktop-manager-landing-page).

## License
[MIT](LICENSE) © 2026 Henry Bentil
