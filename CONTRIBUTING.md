# Contributing to Paneful

Thanks for helping make Paneful better! Contributions of every size are welcome: bug reports, docs fixes,
tests, and new features.

New here? Start with an issue labelled
[`good first issue`](https://github.com/HC-bentill/paneful/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
or [`help wanted`](https://github.com/HC-bentill/paneful/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22).

## Ground rules
- Be kind. This project follows our [Code of Conduct](CODE_OF_CONDUCT.md).
- For anything bigger than a small fix, **open or comment on an issue first** so we can agree on the
  approach before you spend time on it.
- Keep pull requests focused: one fix or feature per PR.

## Development setup
Requirements: a Mac on **macOS 27.2+** and **Xcode** (or the Command Line Tools) with Swift 5.10+.

```bash
git clone https://github.com/<you>/paneful.git
cd paneful
swift build                   # compile
swift test                    # unit tests
./scripts/bundle.sh debug     # builds build/Paneful.app
open build/Paneful.app
```

On first launch, allow Paneful under **System Settings → Privacy & Security → Accessibility**.
`bundle.sh` signs with your "Apple Development" certificate when you have one (or `$PANEFUL_SIGN_IDENTITY`).
Otherwise it signs ad-hoc, and you'll have to re-grant Accessibility after each rebuild: remove Paneful
from the list and add it again.

Quit any other window manager (Rectangle, Magnet, etc.) while testing, and turn off macOS's own edge tiling
and Stage Manager. They fight Paneful.

Logs (use the full path, because zsh has its own `log` builtin):
```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "io.github.hc-bentill.paneful"'
```
Categories: `app`, `drag`, `frames`, `tabs`. Interpolated values need `privacy: .public` to show up.

## Project layout
```
Sources/Paneful/
├── App/            AppDelegate and the menu-bar menu
├── Accessibility/  AXWindow wrapper, window queries, permissions
├── Snapping/       snap zones, drag controller, preview panel, window actions
├── Tabs/           tab-group manager, floating tab bar, remembered-group store
├── Hotkeys/        global shortcuts (Carbon RegisterEventHotKey)
└── Support/        coordinate conversion, settings, logging, macOS conflict checks
Tests/PanefulTests/ unit tests
```
Some useful background:
- Paneful controls other apps' windows through the macOS **Accessibility API** (`AXUIElement`).
- AX coordinates have their origin at the **top-left** of the primary screen. Cocoa's origin is at the
  **bottom-left**. Always convert through `Geometry`.
- Everything runs on the main actor. C callbacks (Carbon, AXObserver) are global functions that hop in with
  `MainActor.assumeIsolated`.

[FEATURES.md](FEATURES.md) is the spec and roadmap. If your PR changes behaviour, update it, and update
the "How to use" section of the README.

## Making a change
1. Fork the repo and create a branch: `git checkout -b fix/tab-bar-flicker`.
2. Make your change. Add or update tests in `Tests/PanefulTests` where it makes sense. Geometry, snap zones
   and the group store are easy to unit-test.
3. Run `swift test` and try the change by hand with `./scripts/bundle.sh debug`.
4. Commit with a clear message in the imperative mood ("Fix tab bar flicker when switching Spaces").
5. Open a pull request and fill in the template. CI builds the app and runs the tests on every PR.

### Testing window behaviour by hand
Window managers are hard to unit-test, so please say in your PR which apps you tried. A good spread:
- Safari or a Chromium browser
- Finder
- an Electron app (Slack, Teams, VS Code)
- a document app with a minimum window size (Pages, Xcode)
- if you can, a second display

## Reporting bugs
Use the **Bug report** template. Include:
- your macOS version and Paneful version
- the apps involved
- your display setup
- steps to reproduce

A short screen recording is gold.

## Website and docs
The website and the animated docs live in
[paneful-desktop-manager-landing-page](https://github.com/HC-bentill/paneful-desktop-manager-landing-page)
(React + Vite). Docs fixes are very welcome there too.

## License
By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
