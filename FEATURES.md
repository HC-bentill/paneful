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
- Remove a tab with its ✕ / right-click menu, or ⌃⌥W; dissolving a group gives the tab-bar space back.
- The drop zone is the top part of the other window (title bar + toolbar, ~80 pt) or its tab bar. Hovering
  there shows "Hold to add as a tab". After ~0.3 s it turns into "Release to add as a tab". So dragging a window
  across other windows doesn't group them by accident, and it's clear where to hold.
- Every group whose window is on screen shows its tab bar. The bar stacks with its group: other windows in
  front of the group cover its bar too. The group you're working in is drawn at full strength; others are
  slightly muted.
- The active tab is outlined in the system accent colour.
- The tab bar always fits: if a group's window is resized up to the menu bar, the group moves down so the bar
  stays visible and never covers the window.
- Drag a tab down out of the tab bar to tear it off: it becomes a separate window again, under the cursor.
- Right-click a tab: Move Out of Group, Close Window, Minimize Group, Ungroup All.
- Minimize Group (⌃⌥M, or from the menu-bar menu or a tab's right-click menu) sends every window in the
  group to the Dock. Restoring any one of them brings the whole group back, stacked, with that window as
  the active tab. On a window that isn't grouped, ⌃⌥M just minimizes it.
- Minimizing a tab takes it out of the group and the next tab takes its place. Un-minimizing puts it back as
  the active tab.
- Quitting Paneful leaves every window visible at the group's full frame.

## 3. Auto-tiling 📋 (next)
Observed in recording #2:
- When a new window opens (e.g. *New Finder Window* from the Dock), existing windows shrink and the new
  window takes a tile automatically: first split is left/right halves.
- Further new windows split the newest column top/bottom (stack).
- While the new app's window is still appearing, a dark placeholder tile with the app icon and window name
  holds its slot.
- Closing/minimizing a window reflows the layout; closing the last extra window lets the remaining one
  (or tab group) expand back to full screen.
- A tab group counts as a single tile.
- Needs: global on/off toggle, per-app "always float" rules (System Settings, dialogs, sheets).
- Refinements:
  - "Always Float <frontmost app>" toggle in the menu-bar menu, applied to the app that's in front. No rule
    files are needed.
  - "Float All Windows" command: stop arranging everything at once and leave windows where they are.
  - Each display has its own layout. Dragging a window to another display joins that display's layout.
  - Drag the border between two tiles to resize both. The other tiles stay put.
  - Minimizing gives a window's tile to its neighbours. Un-minimizing returns it to the same slot.
  - The placeholder tile shows the app's icon and name until the real window arrives.
- **Default is OFF** (see feature 4): new windows float unless the user turns auto-tiling on.

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
- Removing a tab (✕, ⌃⌥W, dragging it out) or ungrouping deletes that window from the remembered group, so
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

## Backlog ideas
- URL-scheme commands (`paneful://snap?zone=leftHalf`, `paneful://tab-with-previous`, …) for Shortcuts,
  Raycast or Alfred.
- Drag the tab bar itself to move the whole group (and drag it to an edge to snap the group).
- Saved layouts: store the current arrangement under a number and bring it back with a shortcut.

Refinements marked in features 1–4 come from a review of a comparable window manager's docs (Trellis WM,
2026-11-06).

## More to come
More features will be added from additional reference recordings.
