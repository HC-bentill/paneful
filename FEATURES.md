# Paneful feature list

Features are captured from reference screen recordings. Status: ✅ built · 🚧 in progress · 📋 planned

## 1. Side-by-side snapping ✅ (v0.1)
- Drag a window to the left/right screen edge → a blurred preview appears → release to snap to that half.
  When the Dock is on that side, reaching the Dock counts as the edge. Anywhere in the menu bar counts as the
  top edge.
- Drag to a corner → quarter; drag to the top edge → maximize.
- Keyboard shortcuts for halves, quarters, maximize and center.
- "Side by side with previous window": the focused window goes left, the window you used before goes right.
- Standard windows only: sheets, dialogs and full-screen windows are left to macOS.
- The menu-bar menu warns when macOS's own edge tiling or Stage Manager is on, since both fight drag-to-snap,
  and links to the System Settings pane that turns them off.

## 2. Cross-app tab groups ✅ (v0.1)
- Group windows from *different* apps (e.g. Brave + Microsoft Teams) into one frame.
- A floating tab bar sits above the group, showing each window's app icon and title.
- Click a tab to bring that window to the front; the group moves and resizes as one window.
- Create a group by dragging a window onto another window's title bar, or with ⌃⌥T.
- Remove a tab with its right-click menu (Move Out of Group), by dragging it out, or ⌃⌥W; dissolving a group gives the
  tab-bar space back.
- A tab's ✕ (shown on hover) minimizes its window, like the red close button (changed 2026-11-09; it used to
  take the window out of the group and leave it floating). The window keeps its place in the group and comes
  back as the active tab when restored from the Dock. Right-click → Minimize Window does the same.
- The drop zone is the top part of the other window (title bar + toolbar, ~80 pt) or its tab bar. Hovering
  there shows "Hold to add as a tab". After ~0.3 s it turns into "Release to add as a tab". So dragging a window
  across other windows doesn't group them by accident, and it's clear where to hold.
- Every group whose window is on screen shows its tab bar. The bar stacks with its group: other windows in
  front of the group cover its bar too. The group you're working in is drawn at full strength; others are
  slightly muted.
- The active tab is outlined in the system accent colour.
- The tab bar always fits: if a group's window is resized up to the menu bar, the group moves down so the bar
  stays visible and never covers the window.
- Drag a tab sideways to reorder it, like browser tabs: the other tabs slide aside to open a gap, and the tab
  stays where it's dropped. The order is remembered with the group. A tab passes a neighbour once its edge
  crosses that neighbour's middle, so it can go all the way to the first or last position (fixed 2026-11-09:
  before, only in-between positions worked). A pill under the bar says what letting go
  will do ("Drag sideways to reorder, or down to pull out" → "Release to move the tab here").
- Drag a tab well down (or up) out of the tab bar, 44 pt, to tear it off. The pill turns into "Release to pull
  out of the group", and the window becomes a separate window again, under the cursor. Moving back toward the
  bar cancels, so a sideways drag that wanders a little never tears a tab off by accident.
- Right-click a tab: Minimize Window, Move Out of Group, Close Window, Minimize Group, Ungroup All.
- Minimize Group (⌃⌥M, or from the menu-bar menu or a tab's right-click menu) sends every window in the
  group to the Dock. Restoring any one of them brings the whole group back, stacked, with that window as
  the active tab. On a window that isn't grouped, ⌃⌥M just minimizes it.
- Minimizing a tab takes it out of the group and the next tab takes its place. Un-minimizing puts it back as
  the active tab.
- Quitting Paneful leaves every window visible at the group's full frame.
- Sleep, screen lock and display changes don't move groups (fixed 2026-11-09). While the screen is locked,
  Accessibility can't read windows, which used to look like every grouped window had closed; on wake the
  groups re-formed and made room for the tab bar a second time, so the window lost a bar's height (32 pt) from
  the top after every sleep, and on waking the windows visibly rejoined their groups one by one over a few
  seconds. Now groups stay intact: Paneful touches nothing while asleep, the displays are off or the screen is
  locked (`SystemState`), only treats a window as closed when Accessibility says it no longer exists, and never
  makes room for the bar twice. Waking up shows the screen exactly as it was. For a second or two afterwards
  (while macOS rearranges the screens) tab bars stay glued to their windows, anything macOS moved is put back
  right at unlock and again once settled, and the user's own drags and resizes are followed.

## 3. Auto-tiling ✅ (v0.3.0, awaiting manual test)
Observed in recording #2, built as an optional mode, **off by default**: menu bar → **Auto-tile New Windows**.
- When a new window opens (e.g. *New Finder Window* from the Dock), the window you were using shrinks to the left
  half and the new window takes the right half.
- Further new windows stack in the right column, top to bottom, sharing it equally.
- While an app is launching, a dark placeholder tile with the app's icon and name ("Opening…") holds its slot
  until the real window arrives (or 6 s pass). A new window of a running app gets the same placeholder for a
  moment while it moves into its tile.
- Closing or minimizing a window reflows the layout; when only one window (or tab group) is left, it fills the
  screen again. Un-minimizing returns a window to the same slot.
- A tab group counts as a single tile, and its tab bar spans the tile.
- Menu bar → **Auto-tiling** submenu:
  - **Float Focused Window / Tile Focused Window** (⌃⌥F) takes a window out of the layout or puts it in.
  - **Always Float <frontmost app>**: that app's windows are never tiled. No rule files are needed. System
    Settings, Archive Utility and Installer always float.
  - **Float All Windows**: stops arranging the current windows and leaves them where they are. New windows
    are still tiled, into a fresh layout.
- Dialogs, sheets, panels, full-screen windows and windows that can't be resized always float. Snapping a tiled
  window (edge drag or shortcut) takes it out of the layout.
- Each display has its own layout. Each Space shows only its own windows: tiles whose window is on another
  Space (or minimized, or hidden) take no space here.
- Drag a tiled window onto another tile to swap them. Drag it to another display to join that display's
  layout. Let go anywhere else and it slides back into its tile.
- Drag the edge of a tile to resize it: the main/stack border, or a border between two stack tiles. The
  neighbour on the other side of that border resizes to match; the other tiles stay put.
- Windows that were open before auto-tiling was turned on stay where they are. Only new windows are tiled,
  plus the window you were using when the first one opens. The layout isn't saved across Paneful relaunches.
- How it works: each tick compares the window server's on-screen list with every window ever seen (cheap);
  Accessibility is only asked about windows that are actually new. Switching Spaces or waking re-baselines the
  list, so windows that merely reappear aren't treated as new. Layout math is in `Tiling/TileLayout.swift`
  (tested).

## 4. Remembered tab groups + floating new windows ✅ (built, awaiting manual test)
Requested by Henry:
- Paneful remembers which windows were tabbed together, and keeps that memory across app restarts,
  reboots and Paneful relaunches.
- When a remembered window opens again, it joins its group as a tab automatically, with no dragging needed.
  - Example: Brave + Microsoft Teams were tabbed. Quit Teams and reopen it, and its window snaps back into
    the Brave group as a tab.
  - If no other member of the group is open yet, the first one to open floats normally. Members that open
    later tab onto it.
- **New windows float.** A window Paneful has never seen in a group opens wherever the app puts it.
  It only joins a group when the user drags it onto another window's title bar or tab bar, or presses ⌃⌥T.
- Removing a tab (Move Out of Group, ⌃⌥W, dragging it out) or ungrouping deletes that window from the remembered group, so
  it won't auto-tab next time. Closing a window, quitting its app or quitting Paneful does *not* forget it.
- Only windows that have just opened can auto-tab: a window must join within ~5 s of appearing. Windows that
  were already open when a member went offline never get pulled into a group.
- How windows are recognised:
  - by app (bundle ID), plus the window title when an app has several windows;
  - browser-style titles that change all the time match on app alone. Paneful keeps the last title it saw. If a
    member's title keeps changing (3+ times), Paneful stops using the title for it.
  - When several windows could match, the one sitting at the group's saved frame wins.
- Menu-bar: "Remembered Groups…" list to review/forget saved groups; toggle "Auto-tab remembered windows".
- Implementation notes: save groups as JSON in Application Support; watch `kAXWindowCreatedNotification`
  on every running app and `NSWorkspace.didLaunchApplication` for new apps; restore groups at Paneful launch
  for windows that are already open.

## 5. Drop files onto tabs ✅ (v0.3.0, awaiting manual test)
Requested by Henry: move a file from one folder to another, or into an app's drop area, when the target is a
background tab.
- Drag a file, folder, text or image from anywhere and hold it over a tab. The tab lights up and a pill says
  **Hold to open this tab**. After 0.5 s the tab opens (its window comes to the front) and the pill says
  **Now drop it onto the window**. Move down into the window and drop it there.
- Holding it over the tab that's already open says **Now drop it onto the window** right away.
- Dropping onto the tab itself just opens it; the drop bounces back so nothing is lost.
- Works on every visible tab bar, focused or not.
- How it works: the tab strip's host view registers as a drag destination (spring-loading, like Finder's
  folders). It never accepts the drop; the window below does.

## 6. Close button minimizes tabs ✅ (v0.3.0, awaiting manual test)
Requested by Henry: closing a tabbed window with the red button shouldn't lose it.
- In a tab group, the red close button sends that window to the Dock instead of closing it. The next tab
  takes its place. Click the window in the Dock to bring it back as the active tab.
- To really close it: ⌥-click the red button, or right-click its tab → Close Window. ⌘W isn't intercepted.
- On by default; switch it off with menu bar → **Close Button Minimizes Tabs**. Windows that aren't in a tab
  group are never affected.
- Apps that hide a window when you close it instead of closing it (Postman, Microsoft Teams, Slack…) are handled
  the same way: if such a window leaves the screen while its groupmates are still showing (e.g. after ⌘W), its
  tab steps aside like a minimized tab and the next tab takes over. When the app shows the window again, it
  comes back as the active tab. Before, the hidden window kept its tab, the bar disappeared and the group looked
  like loose windows (Henry saw this with Postman on 2026-11-09).
- How it works: an event tap sees left clicks before apps do. Each tick, Paneful reads where every group's
  visible window has its close button (the window's own close-button attribute, cached per window and refreshed
  every 3 s), so a click is checked with plain geometry and nothing is asked of the app while the click waits.
  If it's that window's close button, the click is swallowed and the window minimized. (The first version asked
  the app what was under the cursor; Electron apps such as VS Code and Postman answer with their web content,
  which extends under the traffic lights, so the click went through.)

## 7. Auto-tab new windows ✅ (v0.3.0, awaiting manual test)
Requested by Henry: like auto-tiling, but new windows become tabs.
- Off by default: menu bar → **Auto-tab New Windows** (below **Auto-tile New Windows**).
- When a new window opens, it joins the tab group of the window you were using, or starts a group with it, and
  becomes the active tab at that group's frame. Works across apps.
- Windows already open when it's turned on aren't touched. Dialogs, sheets, full-screen and fixed-size windows
  open normally, as do apps set to **Always Float <app>** (which means "never tile or auto-tab this app's new
  windows").
- With auto-tiling on too, a new window joins a tab first; a tab group is one tile, so it lands in that tile.
- Different from **Auto-tab Remembered Windows** (feature 4), which only brings back windows that were in a
  group before.
- How it works: the same new-window detection as auto-tiling (`AutoTiler.adoptNewWindows`), then
  `TabGroupManager.addToGroup(target: <most recent visible window>, window: <new window>)`.

## 8. Saved layouts ✅ (v0.3.0, awaiting manual test)
Requested by Henry (was a backlog idea): store the current arrangement under a number and bring it back with a
shortcut.
- **⌃⌥⇧1…9** saves, **⌃⌥1…9** restores. Menu bar → **Saved Layouts ▸** (after Side by Side) lists the layouts
  ("Layout 1: Safari, Xcode, Terminal +2 ⌃⌥1"), plus **Save Current Layout As ▸ 1…9** and **Forget Layout ▸**.
- Saved: every standard window on the current desktop, all displays, front to back. Per window: bundle ID, app
  name, title, frame (AX), and the visible frame of its display. A formed tab group is one item: its live tabs in
  order, its content frame and its visible tab. Stored in `~/Library/Application Support/Paneful/layouts.json`.
- Restore: open windows of the layout's apps are paired with the saved ones (`LayoutMatcher`: same app, then same
  title, similar title, else nearest frame; each window used once). Hidden apps are unhidden, minimized windows
  come back, windows saved alone leave their current tab group, saved groups are formed again with
  `TabGroupManager.arrange` (reuses the group most of them belong to, so remembered closed members survive), and
  frames are fitted with `LayoutGeometry` (same display: exact; display gone or resized: same relative place on
  the most overlapping display, kept on screen). Then windows are raised back to front and the front one focused.
- Windows not open are skipped (no app launching); windows not in the layout are left alone. With auto-tiling on,
  restoring calls Float All Windows first.
- A pop-up confirms: "Layout 1 saved · 5 windows · ⌃⌥1 brings them back", "Layout 1 restored · 4 of 5 windows ·
  not open: Mail", "No layout saved as 3".

## Install and updates
- Updating no longer needs removing Paneful from the Accessibility list and relaunching (fixed 2026-11-09).
  macOS ties the grant to the code signature, and ad-hoc builds get a new one every release, so the old entry
  stayed listed but no longer applied. Paneful now records the signature it was allowed with. When a new build
  at the same location isn't allowed (or it's the first launch of a version with this record), it removes its
  own stale entry with `tccutil reset Accessibility <bundle id>` (no admin needed) and macOS asks again: the
  user just switches it on. **Grant Accessibility Access…** in the menu does the same repair.
- Only one copy of Paneful runs at a time. Opening a second copy (say, a development build while the installed
  one is running) asks to quit the other one first. Two copies fought over the same windows, and the new copy's
  permission repair also cut off the running copy.
- At launch, a non-empty `groups.json` is copied to `groups.backup.json`, so remembered groups lost by mistake can
  be restored by hand.
- Releases can be signed with a stable self-signed certificate (`scripts/make-signing-cert.sh`, secrets
  `SELF_SIGNED_P12` + `SELF_SIGNED_P12_PASSWORD`). Every release then has the same identity and the grant carries
  over with no prompt at all. A Developer ID (with notarization) would also remove the Open Anyway step.

## Backlog ideas
- URL-scheme commands (`paneful://snap?zone=leftHalf`, `paneful://tab-with-previous`, …) for Shortcuts,
  Raycast or Alfred.
- Drag the tab bar itself to move the whole group (and drag it to an edge to snap the group).

Refinements marked in features 1–4 come from a review of a comparable window manager's docs (Trellis WM,
2026-11-06).

## More to come
More features will be added from additional reference recordings.
