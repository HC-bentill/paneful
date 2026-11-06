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

## Build / run
```bash
swift build                     # compile check
swift test                      # unit tests (pure logic only)
./scripts/bundle.sh debug       # builds build/Paneful.app (ad-hoc signed)
open build/Paneful.app
log stream --predicate 'process == "Paneful"'   # NSLog output
```
bundle.sh signs with the first "Apple Development" identity (or `$PANEFUL_SIGN_IDENTITY`), so the Accessibility grant
survives rebuilds. With no identity it signs ad-hoc, and then you must remove and re-add Paneful in System Settings →
Privacy & Security → Accessibility after every rebuild.

## Architecture (Sources/Paneful)
- `App/AppDelegate.swift`: status-bar menu (rebuilt in menuNeedsUpdate), permission polling, 0.35s tick
  timer → FocusTracker.update() + TabGroupManager.refresh().
- `Accessibility/AXWindow.swift`: struct wrapping AXUIElement (frame get/set in AX coords, focus()).
  `WindowQuery.swift`: focused window, window at a point, and the window below a point via CGWindowList.
- `Snapping/`: SnapZone (rects in Cocoa coords), PreviewWindow (blurred NSPanel), DragController (global
  mouse monitors: screen edge → snap, title-bar strip → tab), WindowActions (+ WindowMover, FocusTracker).
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
  `TabBarPanel.swift`: SwiftUI tab strip in a non-activating NSPanel (height 32) above the group.
- `Hotkeys/HotKeyManager.swift`: Carbon RegisterEventHotKey, all ⌃⌥ (arrows, ↩, C, U/I/J/K, S, T, W, [ ]).
- `Support/Geometry.swift`: AX (top-left origin) ↔ Cocoa (bottom-left origin). `Settings.swift`: UserDefaults
  and SMAppService launch-at-login. `SystemConflicts.swift`: reads com.apple.WindowManager (edge tiling, Stage
  Manager) for the menu warning.
- Concurrency: everything is @MainActor; C callbacks (Carbon, AXObserver) are global funcs using
  MainActor.assumeIsolated.

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
