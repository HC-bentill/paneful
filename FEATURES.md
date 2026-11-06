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

## More to come
More features will be added from additional reference recordings.
