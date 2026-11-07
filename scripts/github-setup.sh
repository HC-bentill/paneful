#!/usr/bin/env bash
# One-off: makes the GitHub repo contributor-ready (description, topics, Discussions, labels, starter issues).
# Needs the GitHub CLI, logged in as a maintainer: `brew install gh && gh auth login`.
# Safe to re-run: labels are upserted, and an issue is skipped if one with the same title exists.
set -euo pipefail
REPO="HC-bentill/paneful"

gh repo edit "$REPO" \
  --description "Free, open-source macOS window manager: snap windows side by side and group any apps into tabs." \
  --homepage "https://paneful.vercel.app" \
  --enable-discussions --enable-issues \
  --add-topic macos,window-manager,swift,appkit,swiftui,tiling-window-manager,productivity,menubar-app,accessibility,tabs,open-source

label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null; echo "label: $1"; }
label "good first issue" 7057ff "Small, well-defined. Great for a first PR"
label "help wanted"      008672 "Maintainer would love a PR for this"
label "bug"              d73a4a "Something isn't working"
label "enhancement"      a2eeef "New feature or improvement"
label "needs-triage"     fbca04 "Not looked at yet"
label "documentation"    0075ca "README, docs site, comments"
label "snapping"         ff8a4c "Window snapping"
label "tabs"             ff4d6d "Tab groups"
label "auto-tiling"      5b3dff "Auto-tiling mode (feature 3)"
label "release"          bfd4f2 "Packaging, signing, distribution"

issue() { # title, labels, body
  if gh issue list --repo "$REPO" --state all --search "in:title \"$1\"" --json title -q '.[].title' | grep -Fxq "$1"; then
    echo "skip (exists): $1"; return
  fi
  gh issue create --repo "$REPO" --title "$1" --label "$2" --body "$3" >/dev/null
  echo "issue: $1"
}

issue "Add thirds layouts (left/centre/right third, two-thirds)" "good first issue,enhancement,snapping" \
"Add \`SnapZone\` cases for thirds and two-thirds, with ⌃⌥ shortcuts and menu items.

- Rects: \`Sources/Paneful/Snapping/SnapZone.swift\`
- Shortcuts: \`Sources/Paneful/Hotkeys/HotKeyManager.swift\`
- Menu: \`Sources/Paneful/App/AppDelegate.swift\`
- Add tests next to the existing halves/quarters tests in \`Tests/PanefulTests\`
- Document them in the README shortcut table"

issue "Optional gap between snapped windows" "good first issue,enhancement,snapping" \
"Add a setting (0, 4, 8, 12 pt) that leaves a gap between snapped windows and the screen edges.
Apply it in \`SnapZone.rect(in:)\`, add a submenu in the menu bar, persist it in \`Settings.swift\`, and add unit tests."

issue "Restore a window's previous frame (⌃⌥⌫)" "good first issue,enhancement,snapping" \
"Remember each window's frame before Paneful snaps it, and add ⌃⌥⌫ to put it back where it was."

issue "Unit tests for remembered-group matching" "good first issue,tabs" \
"\`GroupStore\` matches reopened windows by bundle ID, plus the title when an app has several windows. Add
\`swift test\` coverage for:
- a single window per app
- several windows with different titles
- browser-style changing titles
- forgetting a group"

issue "Auto-tiling: pure layout model + tests" "help wanted,auto-tiling,enhancement" \
"First building block for feature 3 (see FEATURES.md): a pure Swift model, with no Accessibility calls, that holds
a per-display layout tree.

- **insert:** the first split is left/right, then the newest column stacks top/bottom.
- **remove:** the neighbours reclaim the space.
- **resize:** a border drag resizes both tiles beside it.
- **output:** frames for each window.

Fully unit-testable. Wiring it to real windows comes in a later issue."

issue "Auto-tiling: 'Always Float <frontmost app>' rule" "good first issue,auto-tiling" \
"Store a set of bundle IDs that auto-tiling must leave floating, toggled from the menu bar for the frontmost app.
Persist it in Application Support next to groups.json."

issue "Customisable keyboard shortcuts" "help wanted,enhancement" \
"Let users record their own shortcuts instead of the fixed ⌃⌥ set, so they don't clash with other apps.
A small SwiftUI settings window with a shortcut recorder, persisted in UserDefaults, and re-registered in
\`HotKeyManager\`."

issue "Settings window" "help wanted,enhancement" \
"Move the toggles out of the menu-bar menu into a proper SwiftUI Settings window, with General, Snapping,
Tabs and Shortcuts tabs. Keep the menu for quick actions."

issue "Homebrew tap: brew install --cask paneful" "help wanted,release" \
"Create a \`HC-bentill/homebrew-paneful\` tap with a cask that points at the release DMG. Bonus: a release-workflow
step that bumps the cask version automatically."

issue "Developer ID signing + notarisation in the release workflow" "help wanted,release" \
"Sign with Developer ID and notarise with \`notarytool\` in \`.github/workflows/release.yml\`, so users no longer need
'Open Anyway'. The maintainer will add the certificate and API key as repo secrets. A PR can prepare the workflow
steps behind an \`if: secrets...\` guard."

issue "Localise Paneful (String Catalog)" "help wanted,enhancement" \
"Move user-facing strings into a String Catalog, so the community can add translations."

issue "Multi-display testing and fixes" "help wanted,bug" \
"Test snapping and tab groups with two or more displays, including ones with different scaling, arranged
above or beside each other, and with the Dock on another side. Report or fix any coordinate bugs. Remember
that AX coordinates have a top-left origin."

echo "Done. Next: Settings → General → enable 'Private vulnerability reporting' (Security tab), and pin a welcome Discussion."
