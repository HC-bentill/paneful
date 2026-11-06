# Paneful feature list

Features are captured from reference screen recordings. Status: ✅ built · 🚧 in progress · 📋 planned

## 1. Side-by-side snapping ✅ (v0.1)
- Drag a window to the left/right screen edge → a blurred preview appears → release to snap to that half.
- Drag to a corner → quarter; drag to the top edge → maximize.
- Keyboard shortcuts for halves, quarters, maximize and center.
- "Side by side with previous window": the focused window goes left, the window you used before goes right.

## 2. Cross-app tab groups ✅ (v0.1)
- Group windows from *different* apps (e.g. Brave + Microsoft Teams) into one frame.
- A floating tab bar sits above the group, showing each window's app icon and title.
- Click a tab to bring that window to the front; the group moves and resizes as one window.
- Create a group by dragging a window onto another window's title bar, or with ⌃⌥T.
- Remove a tab with its ✕ / right-click menu, or ⌃⌥W; dissolving a group gives the tab-bar space back.

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
- **Default is OFF** (see feature 4): new windows float unless the user turns auto-tiling on.

## 4. Remembered tab groups + floating new windows 📋
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
- Removing a tab (✕, ⌃⌥W) or ungrouping deletes that window from the remembered group, so it won't
  auto-tab next time.
- How windows are recognised:
  - by app (bundle ID), plus the window title when an app has several windows;
  - browser-style titles that change all the time match on app alone.
- Menu-bar: "Remembered Groups…" list to review/forget saved groups; toggle "Auto-tab remembered windows".
- Implementation notes: save groups as JSON in Application Support; watch `kAXWindowCreatedNotification`
  on every running app and `NSWorkspace.didLaunchApplication` for new apps; restore groups at Paneful launch
  for windows that are already open.

## More to come
More features will be added from additional reference recordings.
