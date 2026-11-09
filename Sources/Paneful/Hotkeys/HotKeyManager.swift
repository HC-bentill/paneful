import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts via Carbon's RegisterEventHotKey (no extra permissions needed).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    struct Shortcut {
        let keyCode: Int
        let modifiers: Int   // Carbon modifier flags, e.g. controlKey | optionKey
        let action: @MainActor () -> Void
    }

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    func register(_ shortcut: Shortcut) {
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x504E_464C) /* 'PNFL' */, id: nextID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[nextID] = shortcut.action
        } else {
            Log.app.error("Could not register hotkey \(shortcut.keyCode, privacy: .public) (status \(status, privacy: .public)): probably used by another app")
        }
        nextID += 1
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

/// Carbon C callback (must be a plain global function). Runs on the main thread.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated { HotKeyManager.shared.fire(id) }
    return noErr
}

/// Paneful's default shortcuts. ⌃⌥ = Control + Option.
@MainActor
enum DefaultShortcuts {
    static let mods = controlKey | optionKey

    static func registerAll() {
        let hk = HotKeyManager.shared
        let list: [(Int, @MainActor () -> Void)] = [
            (kVK_LeftArrow,  { WindowActions.snap(.leftHalf) }),
            (kVK_RightArrow, { WindowActions.snap(.rightHalf) }),
            (kVK_UpArrow,    { WindowActions.snap(.topHalf) }),
            (kVK_DownArrow,  { WindowActions.snap(.bottomHalf) }),
            (kVK_Return,     { WindowActions.snap(.maximize) }),
            (kVK_ANSI_C,     { WindowActions.snap(.center) }),
            (kVK_ANSI_U,     { WindowActions.snap(.topLeft) }),
            (kVK_ANSI_I,     { WindowActions.snap(.topRight) }),
            (kVK_ANSI_J,     { WindowActions.snap(.bottomLeft) }),
            (kVK_ANSI_K,     { WindowActions.snap(.bottomRight) }),
            (kVK_ANSI_S,     { WindowActions.sideBySide() }),
            (kVK_ANSI_T,     { WindowActions.tabWithPrevious() }),
            (kVK_ANSI_W,     { WindowActions.removeFromGroup() }),
            (kVK_ANSI_M,     { WindowActions.minimizeGroup() }),
            (kVK_ANSI_F,     { WindowActions.toggleTiling() }),
            (kVK_ANSI_RightBracket, { WindowActions.nextTab() }),
            (kVK_ANSI_LeftBracket,  { WindowActions.previousTab() }),
        ]
        for (key, action) in list {
            hk.register(.init(keyCode: key, modifiers: mods, action: action))
        }
    }
}
