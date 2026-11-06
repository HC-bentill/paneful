import os

/// Unified-log channels. Read them with (use the full path: zsh has its own `log` builtin):
///   /usr/bin/log stream --level debug --predicate 'subsystem == "io.github.hc-bentill.paneful"'
/// Interpolated values must be marked `privacy: .public`, or macOS shows them as <private>.
enum Log {
    private static let subsystem = "io.github.hc-bentill.paneful"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let drag = Logger(subsystem: subsystem, category: "drag")
    static let frames = Logger(subsystem: subsystem, category: "frames")
    static let tabs = Logger(subsystem: subsystem, category: "tabs")
}
