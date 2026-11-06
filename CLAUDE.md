# Paneful Desktop Manager: notes for Claude

Open-source macOS menu-bar window manager (MIT), owned by Henry Bentil. Swift Package, macOS 27.2+.
Repo: https://github.com/HC-bentill/paneful (public). Bundle ID: io.github.hc-bentill.paneful.
CI: .github/workflows/build.yml runs `swift test` and builds the app bundle on every push and PR.
agentmemory project id: `macos-window-tabs-tiler`. Recall it for the full history (video analyses, decisions).

## Status (2026-11-06)
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

## Architecture (Sources/Paneful)
- `App/AppDelegate.swift`: status-bar menu (rebuilt in menuNeedsUpdate), permission polling, 0.35s tick
  timer → FocusTracker.update() + TabGroupManager.refresh().
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
- `Hotkeys/HotKeyManager.swift`: Carbon RegisterEventHotKey, all ⌃⌥ (arrows, ↩, C, U/I/J/K, S, T, W, M, [ ]).
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
3. Auto-tiling (from video 2): planned, NEXT. Optional mode, OFF by default. Refinements are in FEATURES.md.
4. Remembered tab groups + floating new windows: built. Detection polls on the 0.35s tick, not
   kAXWindowCreatedNotification. That's simpler and handles windows that appear before an observer could be
   attached.
Henry is recording more videos and will add features. Append each one to FEATURES.md and agentmemory.

## Conventions
- Save each meaningful step to agentmemory (project `macos-window-tabs-tiler`).
- Commit trailer used so far: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
