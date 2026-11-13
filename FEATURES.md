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

## 9. Full-screen tab groups ✅ (built 2026-11-12, awaiting manual test)
Requested by Henry: make tab group 1 full screen, then tab group 2 full screen, and swipe between them with three
fingers, the way native full-screen windows work.
- macOS's own full screen can't do this: a full-screen Space holds one window (two with Split View), and there's
  no public API to create Spaces or move another app's windows into one (yabai needs SIP off for that). So a
  group fills the screen on an ordinary desktop instead. Desktops sit in the same row as full-screen apps, so
  one group per desktop plus the three-finger swipe feels the same.
- **Green button** on a grouped window: the whole group fills the screen (the display's visible frame; the tab
  bar along the top, windows below). Click it again: back to the frame it had before (`TabGroup.restoreFrame`).
  If the group was already maximized another way (⌃⌥↩), it goes to the centre zone. Moving, resizing,
  snapping, or restoring a layout onto the group ends the fill (`checkStillFilled`). Filling takes the group out
  of the auto-tiling layout. On by default; menu bar → **Green Button Fills Screen** switches it off.
- **⌥-click** on the green button: macOS's own full screen for that window alone (AX `AXFullScreen`). The green
  button's hover menu isn't touched.
- **Remembered:** `restoreFrame` is saved in groups.json (optional, so older files still load). After a wake,
  unlock or display change, a filled group fills its screen again (the resolution, or the room the menu bar and
  Dock leave, may have changed).
- **Tab bars stay on their own desktop:** a bar whose group is on another desktop is left up there instead of
  being hidden, so it slides in with the desktop when you swipe back. (It used to be hidden and shown again up
  to 0.35 s after the swipe ended.) Click targets and window drops only count bars showing on this desktop
  (`TabBarPanel.isShowingHere`).
- **A tab that goes full screen** (⌥-click, ⌃⌘F, View menu) steps aside like a minimized tab (`Member.fullScreen`):
  the next tab takes over without being focused (that would pull you out of the full-screen Space), and the other
  windows keep their size. Before, they followed it to full-screen size. About 0.8 s after it leaves full screen,
  it comes back as the active tab. A remembered window that is in full screen may rejoin after a restart; it
  waits outside the bar the same way.
- **Snap shortcuts** (⌃⌥ arrows, ↩, C, U/I/J/K, and ⌃⌥S side by side) beep on a full-screen window instead of
  trying to move it.
- Settings that make it feel right (README): turn off "Automatically rearrange Spaces based on most recent use"
  and "When switching to an application, switch to a Space with open windows for the application"; hide the
  menu bar ("Always") and the Dock automatically.
- **Groups across desktops** (bug fix, 2026-11-12). A friend of Henry's, using 4 desktops, dragged a grouped
  window to another desktop in Mission Control and the group broke. Cause: Paneful couldn't tell "on another
  desktop" from "its app hid it" (feature 6's hide-on-close check). The moved window was marked hidden, then
  rejoined and was focused whenever its desktop was showing, so macOS jumped between desktops and the group
  flipped back and forth. Now `Spaces` (read-only private `CGSCopySpacesForWindows` /
  `CGSCopyManagedDisplaySpaces`, as used by AltTab and Hammerspoon) reports each window's desktop.
  `checkDesktops()` runs each tick once the mouse has been up for 0.5 s and no member is being placed. It puts
  the group on the desktop holding most of its windows (`Spaces.home`: on a tie, the visible tab's desktop).
  Members on other desktops get `Member.elsewhere`: nothing is focused, and (since §10) their tab stays in the
  bar as a dimmed "away" tab. They come back (unfocused) when they're on the group's desktop again. So moving a group's windows over one by one moves
  the group. The hide-on-close check ignores windows on other desktops. A tab bar dragged to another desktop in
  Mission Control is taken down and shown again next to its window. A pop-up says "Tab group split across
  desktops" / "Tabs back together" (not in the first 5 s after launch). The Remembered Groups menu shows "on
  another desktop" and "full screen".

## 10. Drag the tab bar to another desktop to move the group ✅ (built 2026-11-12, awaiting manual test)
From Henry's recording (2026-11-12, 10 pm, Feature 9 dev build): in Mission Control he dragged a group's tab bar
onto Desktop 2. Only the bar moved, then it vanished, and Desktop 2 was empty. He chose option A: the group
follows its bar.
- **What macOS allows (checked on macOS 27.2 with a probe):** `CGSMoveWindowsToManagedSpace` and
  `CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces` move Paneful's OWN windows only. For another app's
  window they silently do nothing. yabai's compat-ID trick (`SLSSetWindowListWorkspace`) returns
  kCGErrorNotImplemented. So other apps' windows were first moved (replaced 2026-11-13 by drags in Mission
  Control, see the end of this section) like Amethyst/Hammerspoon do: hold the window by its
  title bar (synthetic mouse-down just right of the green button), press a desktop shortcut, wait for the
  switch, let go (`Tabs/DesktopMover.swift`). Shortcuts are read with `CGSGetSymbolicHotKeyValue` /
  `CGSIsSymbolicHotKeyEnabled` (`Accessibility/DesktopShortcuts.swift`): "Switch to Desktop N" (IDs 118…133)
  when on, else "Move left/right a space" (79/81, ⌃←/⌃→, on by default) once per space in between.
- **Noticing:** every tick and on `NSWorkspace.activeSpaceDidChangeNotification`, `checkBarDesktops()` compares
  the bar's desktop (`Spaces.space(of: bar.windowNumber)`) with the group's (`homeDesktop`). The bar moved (not
  the windows) when its desktop differs from the last desktop it was seen on with its windows
  (`DesktopMovePlan.barCheck`). `placeBars` leaves such a bar alone, so it isn't hidden or pulled back.
- **Moving:** waits until Mission Control is closed (`Spaces.missionControlIsShowing`: a Dock window at the Dock
  level covering a whole display) and the mouse and keyboard have been still for 0.5 s. `DesktopMovePlan.decide`
  checks the target is a desktop on the same display and that shortcuts reach it both ways. Then every open
  member (away ones too) is carried, the visible tab last, and the user is brought back to the desktop they
  were on. Tab order and the active tab are kept. A toast says what's happening. Paneful's own events carry
  `DesktopMover.eventTag`; the close-button tap and drag tracking let them through, and a real click stops the
  move after the current window. The tick, AX handler and auto-tiler pause while it runs. The pointer goes back
  where it was.
- **Failures:** a window that can't be carried (full screen, its app refuses, another window covers its title
  bar, other display) stays in the group as an **away tab** (dimmed, italic, badge; `TabAway`), is logged, and
  is named in the toast. Clicking an away tab carries its window over (`bringBack`); clicking a full-screen one
  goes to it. A group keeps its bar while one window is here and it has 2+ tabs counting away ones
  (`TabGroup.keepsBar`). If nothing can move (no shortcut on, other display, nothing arrived, setting off, or
  no quiet moment within 20 s), the bar is moved back to its windows with `Spaces.moveOwnWindow`, so it's never
  alone on a desktop, and a toast says why ("Turn on Move left/right a space or Switch to Desktop N…").
- **Remembered:** `StoredGroup.desktop` = `StoredDesktop(uuid, number)` (numeric Space IDs change when displays
  come and go: 1/1086 earlier that evening, 4/8/9 later). A group re-formed from remembered windows (launch
  restore or a claim) on another desktop is carried back there. The group's desktop is pinned after a move
  (`pinnedHome`) so the windows left behind don't outvote it. Menu: Remembered Groups shows "On Desktop N".
- Setting `dragBarMovesGroup` (menu "Move Whole Group Between Desktops", default on). (Until 2026-11-13 a menu
  warning asked to turn on desktop shortcuts; the Mission Control mover below doesn't need them.)
- **First hand test (2026-11-12, 23:46–23:49, dev build pid 62590): unreliable.** Bringing a single away tab
  back worked twice (Finder 4→8, Brave 8→9). Group moves: Code carried once; Brave and Finder "held" but stayed
  behind; several "another window covers the title bar"; once ⌃→ didn't switch while holding; one move stopped
  on a click (unclear whether Henry's). Causes found: (1) only a mouse-down was posted, and AppKit (Finder) and
  Chromium (Brave) only start a window drag once the mouse moves; (2) clicks and window-list checks happened
  during the desktop slide or Mission Control's closing animation. Fixes: `grab` drags 2–8 pt and checks the
  window's CG bounds follow (else retries 0.7 s later just left of the red button); waits for the window to be
  on screen after each switch (+250 ms) and 350 ms after each slide; lets go only once `Spaces.space(of:)` says
  it's on the target (≤1.2 s), after dragging back to the grab point; presses the shortcut again if the desktop
  didn't switch; starts only when Mission Control has been closed ≥1 s and no desktop switch in the last second;
  `bringToFront` tries raise → focus → raise and logs the window in front. Clicks posted by Paneful are also
  recognised by `eventSourceUnixProcessID`; a stopping click logs its point and source pid.
- **Second hand test (23:58, pid 80204): split group.** VS Code and Brave on Desktop 3, bar dragged to Desktop 2.
  The movement check said neither window was picked up, but VS Code started its drag late and was carried when
  Paneful switched back, while Brave stayed: Brave's tab showed (as designed) as an away tab on Desktop 2.
  Likely cause: the apps weren't active, so the first press only activated them. Fixes: `bringToFront`
  activates the app through Accessibility (`AXWindow.activateApp`: kAXFrontmostAttribute + kAXMainAttribute +
  raise) and waits until it's the active app and on top at the grab point (Paneful's own bar counts as in the
  way); `pressAndHold` keeps the mouse down whatever the movement check says (logged only); success = the
  window's desktop is the target, checked again 300 ms after release, with a second release for late drags;
  one retry per window at the other grab point; `finishCarry` judges by where windows are now, not by the report.
- **Henry, 00:35 (2026-11-13): "why does it take time, I expect it instant" + "when one window of a group is
  moved to a new desktop, the group should form over there".** His 00:33 run took ~9 s (3 s gate after Mission
  Control, ~3 s per window). Probed more calls on a throwaway window: `SLSSpaceAddWindowsAndRemoveFromSpaces`
  and `SLSMoveWindowsToManagedSpace` return 3 and do nothing; `SLSProcessAssignToSpace` returns 0 and does
  nothing. So instant isn't possible on macOS 27.2 (only with SIP off, like yabai). Made it faster: start gate
  0.4 s after Mission Control / a desktop switch and 0.3 s mouse/keys idle; tighter waits in DesktopMover
  (≈1–1.5 s per window). New: **a window moved to another desktop takes its group along** (`checkDesktops` →
  `DesktopMovePlan.movedAway`: a live window that was on the group's last desktop (`lastHome`, `lastSpaceOf`)
  and is now on another desktop → pending `.windowMoved` move, showing that window). `rememberSpaces` after
  every move so carried windows aren't mistaken for moved ones. Windows on several desktops (All Desktops)
  count as on none. Menu toggle renamed "Move Whole Group Between Desktops".
- **Henry, 2026-11-13 12:22: "it couldn't move Claude into this group (Gang, paneful, claude)… make it consistent
  and instant without the window snapping thing".** Messages and Code arrived (~4.5 s each), Claude didn't:
  pressed twice (green+6, red−6), never followed. The Claude app draws its own title bar, so the grab points
  were on its own controls or a non-draggable area (and drag-back + mouse-up there can even click a button).
  Tried instead, all on macOS 27.2:
  - **Minimize, switch, un-minimize:** ❌. A minimized window still reports its desktop, and un-minimizing it
    while another desktop shows puts it back on its own (test app `minitest`). Henry's Dock also minimizes into
    the app icon and auto-hides, so the old "⌘-click the minimized window in the Dock" trick is out too.
  - **Mission Control via Accessibility:** ✅. It belongs to **WindowManager** now, not the Dock (Hammerspoon's
    Dock "mc" path finds nothing). Tree: `mc.display` (per display) → an AXButton per window picture (id
    `<bundle id>.space.<space id>`, title = window title) and `mc.spaces` → `mc.spaces.list` → AXButton
    "Desktop N" (actions AXPress = "Exit to Desktop N", AXRemoveDesktop) + `mc.spaces.add`. While Mission
    Control is open, CGWindowList reports each window at its picture's rect. There's no "move to desktop"
    action.
  - **Synthetic drag in Mission Control:** ✅ with the right drop point. Test 1 let go at the middle of Desktop
    2's AX frame (983,165): Mission Control made a NEW full-screen space for the window (what it does for a drop
    on empty top-row space), although AX hit-testing said "Desktop 2" there. Once the row opens, the reported
    frames seem shifted down (y 101.5 instead of ~5). Test 2 recorded Henry's own drag (he let go at the frame's
    top edge, 20% across) and repeated it: moved, 2.2 s including generous waits.
  **Now:** `DesktopMover` drags each window's picture onto the target desktop in Mission Control
  (`Accessibility/MissionControl.swift`: open = `open "/System/Applications/Mission Control.app"`, leave = AXPress
  on a desktop's button, which also switches to it; `MissionControlGeometry` is the tested math). Per window:
  settled picture (two equal CG reads) → grab point the AX hit-test confirms → mouse down, lift 8 pt → glide
  below the target → up into the row (it opens) → wait 0.25 s → aim just inside the top of the target's frame,
  30% across (retry: middle, +12 pt), re-aiming until the row stops moving → hover 0.15 s → let go → wait for
  `Spaces.space(of:)` to say target (≤1.2 s). A drop that made a full-screen space is undone
  (`AXFullScreen` = false) and retried once. Windows on other desktops (away tabs): Paneful leaves Mission
  Control onto their desktop and opens it again there. Afterwards: Mission Control stays open if the user had it
  open (and Paneful stayed on their desktop), else it's left onto the desktop they were on. No keyboard
  shortcuts are needed any more (`DesktopShortcuts.swift`, the `noShortcut` problem and the menu warning are
  gone). The move starts as soon as nothing is held and there was no click or key press for 0.3 s, Mission
  Control open or not. A listen-only tap stops it on a real click or key press (the picture in hand is put back).
- **Hand test (2026-11-13 20:18–20:22, dev build): works.** Group Messages + Code + Claude + Brave moved 7 → 41
  and back 41 → 7, every window on the first try, 1.62–1.65 s per drag, ~2 s per window, ~8 s for 4. Two earlier
  runs stopped at once on "the mouse moving" (pid 0): one at exactly the point Paneful had just moved to, one at
  the spot where the bar had been dropped 21 ms before, so most likely Mission Control's own hover refreshes,
  not Henry. Henry: "mouse movements shouldn't stop the process". Now only clicks and key presses stop it, and
  mouse movement no longer delays the start. Sped up: when the top row is already open (`rowIsOpen`), the first
  try uses shorter glides, settle 120 ms, hover 90 ms, arrival polled every 20 ms; the retry keeps the slower
  pace that went 8/8. Each carry logs its total time.
- Known gaps: untested by hand in Paneful itself (only in the test apps). Multiple displays: the top row is
  picked by display bounds, else by its number of spaces, else by the "Desktop N" title. Expected ~1–1.3 s per
  window, still not instant (that's macOS's limit without SIP off).

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
