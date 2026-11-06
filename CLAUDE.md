# Paneful Desktop Manager: notes for Claude

Open-source macOS menu-bar window manager (MIT), owned by Henry Bentil. Swift Package, macOS 27.2+.
agentmemory project id: `macos-window-tabs-tiler`. Recall it for the full history (video analyses, decisions).

## Status (2026-11-06)
- v0.1 (features 1 and 2) compiles with no errors or warnings on macOS 27.2 / Swift 6.4. Four runtime bugs found in
  review are fixed. It has NOT been tested by hand yet: open build/Paneful.app, grant Accessibility, run the checklist.

## Build / run
```bash
swift build                     # compile check
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
  AXObserver watches moved/resized/destroyed/minimized events, and hidden tabs are synced after 0.2s
  debounce. The tab bar shows only while the group is focused.
  `TabBarPanel.swift`: SwiftUI tab strip in a non-activating NSPanel (height 32) above the group.
- `Hotkeys/HotKeyManager.swift`: Carbon RegisterEventHotKey, all ⌃⌥ (arrows, ↩, C, U/I/J/K, S, T, W, [ ]).
- `Support/Geometry.swift`: AX (top-left origin) ↔ Cocoa (bottom-left origin). `Settings.swift`: UserDefaults
  and SMAppService launch-at-login.
- Concurrency: everything is @MainActor; C callbacks (Carbon, AXObserver) are global funcs using
  MainActor.assumeIsolated.

## Features (see FEATURES.md for full spec)
1. Side-by-side snapping: built
2. Cross-app tab groups: built
3. Auto-tiling (from video 2): planned. Optional mode, OFF by default.
4. Remembered tab groups + floating new windows: planned, next after v0.1 works.
   - Persist groups as JSON in Application Support.
   - Remembered windows auto-tab when they open (kAXWindowCreatedNotification + NSWorkspace launch).
   - Unknown/new windows float.
   - Windows are matched by bundle ID, plus a title hint when the app has several windows.
Henry is recording more videos and will add features. Append each one to FEATURES.md and agentmemory.

## Conventions
- Save each meaningful step to agentmemory (project `macos-window-tabs-tiler`).
- Commit trailer used so far: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
