# Paneful Desktop Manager: notes for Claude

Open-source macOS menu-bar window manager (MIT), owned by Henry Bentil. Swift Package, macOS 27.2+.
Repo: https://github.com/HC-bentill/paneful (public). Bundle ID: io.github.hc-bentill.paneful.
CI: .github/workflows/build.yml runs `swift test` and builds the app bundle on every push and PR.
agentmemory project id: `macos-window-tabs-tiler`. Recall it for the full history (video analyses, decisions).

## Status (2026-11-13, release 0.4.0)
- 0.4.0 = features 9 (full-screen tab groups) and 10 (move a group between desktops, via drags in Mission Control),
  plus the "group breaks on another desktop" fix. Info.plist 0.4.0. Henry asked Claude to make this release
  (commit, tag v0.4.0, push) and to update the landing docs (sections #full-screen and #desktops with demos;
  Stage got `mc`, `spaces` and `tabs.away`). Feature 10 hand-tested OK on 2026-11-13; feature 9 not yet.

## Status (2026-11-09, release 0.3.0 PUBLISHED)
- Resources/Info.plist is 0.3.0. Local `make-dmg.sh` build verified (ad-hoc, arm64, build 15). Everything is
  UNCOMMITTED in both repos: Henry commits, tags v0.3.0 and pushes himself. He chose self-signed release signing:
  build/signing/Paneful-Self-Signed.p12 + .password were created 2026-11-09 (SHA-1 3B:EF:31:E2:…:80:BD, git-ignored).
  Henry must back them up and add the secrets SELF_SIGNED_P12 / SELF_SIGNED_P12_PASSWORD BEFORE pushing the tag.
- Henry's round-3 list (2026-11-09), all built, compile with 0 warnings, 20 tests pass, NOT hand-tested yet:
  stale Accessibility grant after updating (Permissions.clearStaleGrantIfUpdated + optional self-signed release
  cert), tab reorder couldn't reach first/last slot (TabReorder.targetSlot now edge-based), groups shrinking by
  32pt after every sleep (SystemState pause + AXWindow.isGone + form() no double bar), red close button on a
  tabbed window minimizes instead (CloseButtonInterceptor), drag files onto tabs (spring-loaded TabStripHostingView),
  auto-tiling (Tiling/, feature 3, default OFF). Landing docs updated (not pushed). Henry pushes himself.
- 0.3.0 released 2026-11-09 19:55Z: tag v0.3.0 → 1e5d991, release run 42686833405. releases/latest/download/
  Paneful.dmg serves 0.3.0, signed `certificate leaf = H"3bef31e2…"` (self-signed; the grant now survives updates
  from 0.3.0 on). Landing docs pushed (f2a9db9) and live on Vercel. The items below are released but still NOT
  hand-tested.
- Saved layouts (feature 8) added 2026-11-09 for 0.3.0: builds with 0 new warnings, 29 tests pass, NOT hand-tested.
- Full-screen tab groups (feature 9) built 2026-11-12, UNCOMMITTED: debug + release build with 0 warnings, 31 tests
  pass, dev bundle built. NOT hand-tested (Henry runs 0.3.0 from /Applications). See FEATURES.md §9.
  Same day: fixed "group breaks when a window is moved to another desktop" (a friend with 4 desktops): Spaces.swift
  + checkDesktops + Member.elsewhere. 35 tests pass. NOT hand-tested.
- Feature 10 (2026-11-12, UNCOMMITTED): drag the tab bar to another desktop → the whole group follows (Henry's
  "option A" after his 10 pm recording, which ran the Feature 9 DEV build, pid 47294, not 0.3.0). Debug + release
  0 warnings, 51 tests pass, dev bundle rebuilt. NOT hand-tested. See FEATURES.md §10.
  2026-11-13: the mover now drags windows in Mission Control (the Claude app couldn't be grabbed by its title
  bar). Hand-tested 20:18–20:22: works (4 windows, Claude included, first try each, ~2 s per window).
  Then: mouse moves no longer stop a move, brisker first try. Debug + release 0 warnings, 55 tests pass. Dev
  bundle NOT rebuilt (Henry's Paneful runs from it): he quits Paneful, then ./scripts/bundle.sh debug && open
  build/Paneful.app.

## Earlier status (2026-11-06)
- Features 1, 2 and 4 are built, including refinements adopted from the Trellis WM docs (see FEATURES.md).
  They compile with no errors or warnings (debug + release), and `swift test` passes (7 pure-logic tests).
- NOTHING HAS BEEN TESTED BY HAND YET. Next: open build/Paneful.app, grant Accessibility, run the manual checklist,
  fix what breaks, then build feature 3 (auto-tiling, default OFF).
- Strict-concurrency build (`-strict-concurrency=complete`) gives only 2 benign "sending" warnings, in the
  permission timer and the AX observer callback. Fix them when moving to Swift 6 language mode.
- Manual test round 1 (2026-11-06): keyboard snapping, branding and most tab/remember features passed. Drag-snap,
  drag-to-tab, tab-bar lag, the bar overlapping windows, and groups "floating" until dragged were fixed in round 2
  (FrameKeeper, CG-based drag tracking, keepInPlace self-check, bars ordered above their window). Waiting on
  Henry's re-test.
- Logging: use `Log.<category>` (os.Logger, Support/Log.swift) with `privacy: .public`. NSLog shows up as <private>.

## Build / run
```bash
swift build                     # compile check
swift test                      # unit tests (pure logic only)
./scripts/bundle.sh debug       # builds build/Paneful.app (ad-hoc signed)
open build/Paneful.app
# Logs: use the FULL PATH. zsh has a builtin `log` that silently shadows /usr/bin/log.
/usr/bin/log stream --level debug --predicate 'subsystem == "io.github.hc-bentill.paneful"'
/usr/bin/log show --last 30m --info --debug --predicate 'subsystem == "io.github.hc-bentill.paneful"'
```
bundle.sh signs with the first "Apple Development" identity (or `$PANEFUL_SIGN_IDENTITY`), so the Accessibility grant
survives rebuilds. With no identity it signs ad-hoc, and then you must remove and re-add Paneful in System Settings →
Privacy & Security → Accessibility after every rebuild.

## Releasing (DMG for the landing page)
- `./scripts/make-dmg.sh [version]` → build/Paneful-<v>.dmg + build/Paneful.dmg. It builds into build/release, so it
  never replaces the dev build. It uses a Developer ID identity if the keychain has one, else ad-hoc, and NEVER
  the Apple Development cert (Gatekeeper rejects it on other Macs, and it embeds Henry's iCloud email). It notarizes
  when NOTARY_PROFILE is set.
- Publish: `git tag vX.Y.Z && git push origin vX.Y.Z` → .github/workflows/release.yml runs tests, builds the DMG and
  creates the GitHub Release with both DMG names. Signing and notarization switch on automatically once the repo
  secrets DEVELOPER_ID_P12, DEVELOPER_ID_P12_PASSWORD, APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD exist.
- The landing page (../paneful-landing, React + Vite; repo HC-bentill/paneful-desktop-manager-landing-page) is
  live on Vercel at https://paneful.vercel.app, with docs and animated demos at /docs/ (section anchors such as
  #tab-groups, #remembered, #shortcuts). It links to
  https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg (constants in src/components/shared.jsx).
  When a feature ships, add its demo there too (see that repo's README), and link it from README.md here.
- macOS 27 is Apple-silicon only, so arm64-only builds are fine.
- Free alternative to Developer ID for keeping the Accessibility grant across updates: `scripts/make-signing-cert.sh`
  makes a self-signed "Paneful Self-Signed" code-signing cert (build/signing/, git-ignored; back it up, never
  regenerate). make-dmg.sh prefers Developer ID, then that identity (looked up WITHOUT -v: untrusted certs aren't
  "valid" but codesign signs with them), then ad-hoc. release.yml imports it from secrets SELF_SIGNED_P12 /
  SELF_SIGNED_P12_PASSWORD. Designated requirement becomes `identifier … and certificate leaf = H"…"` (stable).
  Verified locally with a throwaway keychain (PANEFUL_KEYCHAIN). Real cert: build/signing (SHA-1 3BEF31E2…80BD).
  CI gotcha (v0.3.0 run 42644109309 on macos-26-arm64): "Paneful Self-Signed: no identity found" although the import
  said "1 identity imported" (worked locally on 27.2). release.yml now adds the keychain to the user search list,
  best-effort trusts the cert (sudo add-trusted-cert, codeSign), signs by SHA-1 hash, and a "Check the signature"
  step fails the run if a cert is configured but the app came out ad-hoc (cdhash). workflow_dispatch = dry run
  (builds + checks, uploads the DMG as an artifact, publishes nothing); only tags publish.

## Architecture (Sources/Paneful)
- `App/AppDelegate.swift`: status-bar menu (rebuilt in menuNeedsUpdate), permission polling, 0.35s tick
  timer → FocusTracker.update() + TabGroupManager.refresh() + AutoTiler.shared.update().
- `Accessibility/Permissions.swift`: records the trusted build (cdhash + bundle path in UserDefaults). Untrusted at
  launch with the same path but a new signature (or no record yet) → `tccutil reset Accessibility <bundle id>`
  (works without root) then prompt, so after an update the user only flips the switch. Menu "Grant Accessibility
  Access…" = Permissions.repair(). Never auto-resets for a different copy (dev build vs /Applications), since
  both share the bundle ID and would undo each other.
- `Support/SystemState.swift`: isFrozen while asleep / displays off / locked / fast-user-switched (touch nothing);
  isSettling for 2s after wake, 1s after unlock, 1.5s after display changes (refresh() only runs
  placeBars(hideMissing: false); AX moves are followed only while the mouse is down). onWake (0.25s after
  unfreezing) and onResume (settled) both → TabGroupManager.restoreGroupFrames(). While locked, AX reads fail: never treat `frame == nil` as closed; use `AXWindow.isGone`
  (kAXErrorInvalidUIElement only).
- `Accessibility/AXWindow.swift`: struct wrapping AXUIElement (frame get/set in AX coords, focus()). setFrame turns
  AXEnhancedUserInterface off while it sets the frame (Chromium/Electron otherwise animate or drop changes).
  `windowID` = CGWindowID via the private `_AXUIElementGetWindow`.
  `FrameKeeper.swift`: ALWAYS move windows with FrameKeeper.shared.place(). It re-checks at 0.12/0.4s, re-applies,
  and logs at 0.75s. isPlacing(w) lets observers ignore in-between frames.
  `WindowQuery.swift`: CGWindowList helpers (ScreenWindow, topWindow(atAX:), bounds(of:), axWindow(for:)).
- `Snapping/`: SnapZone (rects in Cocoa coords), PreviewWindow (blurred NSPanel with styles snap / tabHold /
  tabReady and a label), DragController (global mouse monitors). Drags are tracked with CGWindowList: the window
  under the cursor at mouse-down; it's a "move" once its CG origin changes at the same size. AX is resolved only
  then. Screen edge (the Dock area counts as the edge, the menu bar as the top) → snap. The top 80pt of another
  window, or a tab bar, held for 0.3s → tab. While a grouped window is dragged, follow() moves the bar with the
  mouse delta, and dragEnded() syncs the hidden tabs at once. WindowActions (+ WindowMover, FocusTracker).
- `Tabs/TabGroupManager.swift`: all windows in a group share `contentFrame`, and the active one is raised.
  AXObserver watches moved/resized/destroyed/minimized/deminiaturized events, and hidden tabs are synced after
  0.2s debounce. The tab bar shows only while the group is focused.
  Groups are REMEMBERED. Each member is a WindowSignature (bundleID + optional titleHint) plus an optional live
  AXWindow. A group is "formed" (has a bar) only while 2+ members are live and un-minimized; otherwise it is
  dormant. Each tick, scanForRememberedWindows() checks apps that have offline members, and claim()s windows that
  are NEW (not seen at the previous scan, at most 5s old). The first scan after launch also claims windows that
  are already open (restore). Remove, tear-off and ungroup forget a member. Close, app quit and Paneful quit
  (suspendAll) keep it.
  `GroupStore.swift`: WindowSignature/StoredGroup, JSON at ~/Library/Application Support/Paneful/groups.json
  (debounced 1s save; saveNow on quit).
  Every tick: keepInPlace() (the self-check: the group follows its visible window, fitted() keeps room for the bar
  under the menu bar, and hidden tabs are re-stacked about every 1s) and placeBars(). Every formed group whose
  visible window is on this Space shows its bar, ordered directly above that window (order(.above, relativeTo:)).
  `TabBarPanel.swift`: SwiftUI tab strip in a non-activating NSPanel (height 32, level .normal, no canJoinAllSpaces).
  Active tab: accent fill + 1.5pt accent outline. Unfocused groups' bars are drawn at 82% opacity.
  Tab drags (TabBarView): sideways = reorder (others slide by one pitch, tab frames measured via a
  PreferenceKey; on release it glides into the slot, then actions.move → TabGroupManager.moveTab, which
  reorders `members` with Array.movingLive so closed members keep their place). |dy| > 44pt = pull out
  (tearOff). `TabDragHint.swift` shows the pill under the bar. Pure math is in `TabReorder.swift` (tested).
  If Paneful starts while the screen is locked, the restore scan waits for SystemState's resume (AX can't read
  or move windows while locked). form() keeps contentFrame when the anchor is already at it, so re-forming never
  shrinks a window by the bar height again (that was the "shrinks after sleep" bug).
  Tab strip host = `TabStripHostingView` (first mouse + NSDraggingDestination): a file/text/image drag held
  0.5s over a tab selects it (spring-loading); model.tabFrames (unpublished) maps x → tab; pills .dropHold /
  .dropOpened in TabDragHint. It never accepts the drop (performDragOperation returns false).
  `CloseButtonInterceptor.swift`: CGEventTap (session, head, default) on left down/up. Targets are computed on the
  tick (TabGroupManager.refresh → updateTargets): each visible group's active window's kAXCloseButtonAttribute
  frame, cached as an offset from the window origin (refreshed every 3s) + group.contentFrame.origin. The click
  check is pure geometry. DON'T use AXUIElementCopyElementAtPosition here: Electron apps (VS Code, Postman)
  return web content under the traffic lights, so the click went through. Hit → swallow down+up,
  setMinimized(true). ⌥-click passes through. Setting closeButtonMinimizesTabs (default on).
  It also handles the GREEN button (kAXFullScreenButtonAttribute, else kAXZoomButtonAttribute; setting
  greenButtonFillsGroups, default on): click → TabGroupManager.toggleFill (the group fills the screen's visibleFrame;
  TabGroup.restoreFrame = the frame to go back to, persisted in StoredGroup, nil = not filled; checkStillFilled in
  keepInPlace drops it when the group is moved; setOuterFrame/arrange clear it; restoreGroupFrames re-fills).
  ⌥-click → AXWindow.setFullScreen(true) (native full screen). Targets only for bars with isShowingHere.
  Member.fullScreen: a member in native full screen steps aside like a minimized tab (windowEnteredFullScreen,
  detected in the AX moved/resized handler and on the tick for the active window; reconcile(focusNext: false)
  so the user isn't pulled out of the full-screen Space). checkFullScreenEnded rejoins it 0.8s after it leaves.
  Tab bars on other desktops: placeBars leaves a bar up when it isn't on the active Space (it slides in with the
  desktop). Use TabBarPanel.isShowingHere (isVisible && isOnActiveSpace), not isVisible, for hit-testing.
  Desktops: `Accessibility/Spaces.swift` = read-only private CGSCopySpacesForWindows (mask 7) +
  CGSCopyManagedDisplaySpaces ("Current Space" per display). Verified on macOS 27.2: windows on a desktop
  report its ID; minimized/hidden windows report nothing or the desktop they were last on. A group lives on
  `Spaces.home` (most windows; tie → visible tab's desktop). checkDesktops() (tick, mouse up ≥0.5s via
  CGEventSource.secondsSinceLastEventType, skipped while any member isPlacing) sets Member.elsewhere for members on
  other desktops: out of the bar, reconcile(focusNext: false), never focused; back via layoutAfterJoin(focus:
  false). checkHiddenWindows ignores windows on desktops that aren't showing. NEVER focus a window on another
  desktop: macOS jumps there (that was the "group breaks on another desktop" bug).
  Elsewhere and full-screen members keep an "away" tab (TabAway, Member.away / isShownInBar, TabGroup.barMembers;
  bar indices map through barMembers). A formed group keeps its bar while `keepsBar` (1+ window here, 2+ tabs).
  Feature 10: checkBarDesktops (tick, before placeBars) → DesktopMovePlan.barCheck (bar's desktop vs lastBarSpace
  vs homeDesktop) → pendingDesktopMoves → servePendingDesktopMove (nothing held, clicks/keys idle 0.3s, no desktop
  slide; Mission Control may be open; 20s timeout) → DesktopMovePlan.decide → carry → DesktopMover
  (Tabs/DesktopMover.swift: drags each window's PICTURE onto the target desktop in Mission Control, opening it if
  needed; Accessibility/MissionControl.swift reads WindowManager's AX tree: mc.display, mc.spaces.list buttons
  "Desktop N"; a window's picture = its CGWindowList bounds while MC is open; let go just inside the TOP of the
  target button's frame (its middle makes a full-screen space); events tagged eventTag; a listen-only tap stops
  on a real click or key press, NOT on mouse moves: Henry's choice, and MC sends pid-0 moves of its own) → finishCarry (settle → away tabs, pinnedHome, bar via Spaces.moveOwnWindow, toast).
  Title-bar grab-and-switch was dropped 2026-11-13 (failed on apps with custom title bars, like Claude).
  Minimize → un-minimize elsewhere does NOT move a window on 27.2 (it returns to its desktop).
  returnBar = CGSMoveWindowsToManagedSpace on the bar (works for OWN windows only; for other apps' windows it's a
  silent no-op on 27.2, as are Add/RemoveWindowsToSpaces; SLSSetWindowListWorkspace = kCGErrorNotImplemented).
  While DesktopMover.isBusy: refresh, placeBars, AX handler, DragController and AutoTiler.update do nothing.
  StoredGroup.desktop (uuid + number); re-forming at restore/claim → scheduleDesktopRestore.
  A live window moved off the group's desktop (DesktopMovePlan.movedAway on lastSpaceOf/lastHome in
  checkDesktops) → pending .windowMoved → the rest follows. Not instant by design: no private call moves another
  app's window on 27.2 (SLSSpaceAddWindowsAndRemoveFromSpaces / SLSMoveWindowsToManagedSpace / SLSProcessAssignToSpace
  all tested: no effect).
  Member.hidden: apps that hide-on-close (Postman, Teams, Slack) leave the window alive but off screen.
  checkHiddenWindows() marks a member hidden when its window is off screen ≥0.6s while a groupmate is showing
  (not ⌘H-hidden, not minimized, not during a Space switch) → like a minimized tab; unhidden when it shows again.
  Auto-tab new windows (Settings.autoTabNewWindows, default off) lives in AutoTiler's new-window pipeline:
  tabIntoRecent() → addToGroup(target: most recent visible window, window: new). Runs before tiling.
  AppDelegate.resolveOtherCopies(): only one Paneful copy (same bundle ID) runs; offers to quit the other.
  GroupStore.load() copies a non-empty groups.json to groups.backup.json.
- `Tiling/`: `AutoTiler.swift` (Settings.autoTiling, default OFF). Per-display `ScreenLayout` (keyed by
  CGDirectDisplayID) of `Tile`s: .window(AXWindow) / .group(UUID) / .pending(pid). Main + stack layout, math in
  `TileLayout.swift` (tested). New windows = CGWindowList on-screen IDs not in `seen` (baseline with .optionAll on
  enable, Space switch and resume). First new window in an empty layout seeds it with FocusTracker.recent(). Tiles
  are `parked` (no space, keep slot) when their window isn't on screen (minimized/hidden/other Space). App launch →
  `.pending` tile + `TilePlaceholders` panel until the window arrives (6s timeout). DragController.mouseUp calls
  AutoTiler.release (snap), windowDropped (swap / other display / slide back) and noteMouseUp (user resize
  detection = a settled tile changed size within 1.5s of a mouse-up; compares with the last *placed* frame).
  Placement backs off 8s per (tile, frame) for apps that refuse a size. Layout isn't persisted.
- `Layouts/`: saved layouts (feature 8). `SavedLayouts.swift` = capture (CGWindowList front to back → AX window
  by windowID; a formed group is one item: live tabs, contentFrame, active tab) and restore (pair open windows of
  the layout's apps with `LayoutMatcher`, unhide apps, detach singles from formed groups (or any group when
  minimized, else un-minimizing would rejoin it), `TabGroupManager.arrange` for groups, un-minimize, FrameKeeper
  for singles, then after 0.6s if anything animated in: AXRaise back to front + focus/activate the front one).
  AutoTiler.floatAll() first when tiling is on. `LayoutMath.swift` = SavedLayout model + LayoutMatcher +
  LayoutGeometry (pure, tested). `LayoutStore.swift` = layouts.json (ISO-8601 dates). `Support/Toast.swift` = the
  confirmation pop-up (HUD panel, lower part of the mouse's screen, 1.8s).
  `TabGroupManager.arrange(windows, contentFrame:, active:, claimedElsewhere:)` reuses the group most of the
  windows belong to; joins first, then detaches members claimed by other layout items (so the group never drops
  below 2 members mid-way; later items can't pick a group an earlier item already shaped).
- `Hotkeys/HotKeyManager.swift`: Carbon RegisterEventHotKey, all ⌃⌥ (arrows, ↩, C, U/I/J/K, S, T, W, M, F, [ ]),
  plus ⌃⌥1…9 (restore layout) and ⌃⌥⇧1…9 (save layout).
  ⌃⌥F = float/tile the focused window (auto-tiling).
  ⌃⌥M = Minimize Group: TabGroupManager.minimize() sets group.collapsed and marks members minimized before
  the AX calls; restoring any member → restoreGroup() un-minimizes the rest.
- `Support/Geometry.swift`: AX (top-left origin) ↔ Cocoa (bottom-left origin). `Settings.swift`: UserDefaults
  and SMAppService launch-at-login. `SystemConflicts.swift`: reads com.apple.WindowManager (edge tiling, Stage
  Manager) for the menu warning.
- Concurrency: everything is @MainActor; C callbacks (Carbon, AXObserver) are global funcs using
  MainActor.assumeIsolated.

## Brand ("Snap Grid" logo)
- Mark: 2x2 grid. A tall white pane is snapped into the left half, two translucent white panes (35%) sit on the
  right, and a small ↗ arrow is in the bottom-right pane. Background is a vertical gradient from #FF8A4C (orange,
  top) to #FF4D6D (pink, bottom).
- Source files are in Resources/Logo: AppIcon.svg (1024 master on the macOS 824px grid), AppIcon-1024.png,
  MenuBarIcon.svg, and SocialPreview.png (GitHub card, 1280x640; regenerate it with
  `swift scripts/render-social-preview.swift`).
- Shipped assets: Resources/AppIcon.icns (Info.plist CFBundleIconFile=AppIcon), plus Resources/MenuBarIcon.png and
  @2x (black template glyph). bundle.sh copies all of them into the app.
- Code: Support/Brand.swift menuBarIcon() loads the bundled glyph. Under `swift run` (no bundle), it draws the same
  shapes in code. Don't reintroduce SF Symbol stand-ins.
- If Finder or System Settings still shows the generic grey app icon after a rebuild, run
  `touch build/Paneful.app`, then `lsregister -f build/Paneful.app`, then quit and reopen System Settings.
- The GitHub social preview can't be set through the API. Upload SocialPreview.png by hand in repo Settings →
  General → Social preview.

## Features (see FEATURES.md for full spec)
1. Side-by-side snapping: built
2. Cross-app tab groups: built
3. Auto-tiling (from video 2): built 2026-11-09, OFF by default, awaiting manual test.
4. Remembered tab groups + floating new windows: built. Detection polls on the 0.35s tick, not
   kAXWindowCreatedNotification. That's simpler and handles windows that appear before an observer could be
   attached.
5. Drop files onto tabs (spring-loaded tabs): built 2026-11-09.
6. Close button minimizes tabs: built 2026-11-09.
7. Auto-tab new windows: built 2026-11-09 (default off).
8. Saved layouts (⌃⌥⇧1…9 save, ⌃⌥1…9 restore): built 2026-11-09.
9. Full-screen tab groups (green button fills the screen; one group per desktop + three-finger swipe; a tab in
   native full screen steps aside; snap shortcuts beep on full-screen windows): built 2026-11-12.
10. Drag the tab bar to another desktop moves the group (drags in Mission Control, away tabs, desktop remembered): built
   2026-11-12.
Henry is recording more videos and will add features. Append each one to FEATURES.md and agentmemory.

## Conventions
- Save each meaningful step to agentmemory (project `macos-window-tabs-tiler`).
- Commit trailer used so far: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
