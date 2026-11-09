import AppKit
import ApplicationServices
import Security

/// Accessibility permission helpers. Paneful needs this to move, resize and raise other apps' windows.
///
/// macOS ties the grant to the app's code signature. Builds that aren't signed with a stable certificate get a
/// new signature every release, so after an update macOS keeps showing the old "Paneful" entry, switched on,
/// but it no longer applies, and it won't ask again while that entry exists. Paneful spots that case and removes
/// the stale entry itself, so the user only has to switch Paneful on again (no removing, no relaunching).
@MainActor
enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Set when this launch removed an old version's entry, so the menu can explain why it asks again.
    private(set) static var clearedStaleGrant = false

    /// Shows the system "allow Accessibility" prompt. macOS shows it only while Paneful has no entry yet.
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Stale grants after an update

    private static let trustedSignatureKey = "trustedSignature"
    private static let trustedPathKey = "trustedPath"

    /// Remembers which build at which location was allowed, to recognise an update next time.
    static func recordTrusted() {
        let defaults = UserDefaults.standard
        defaults.set(currentSignature, forKey: trustedSignatureKey)
        defaults.set(Bundle.main.bundlePath, forKey: trustedPathKey)
    }

    /// Called at launch while Paneful isn't allowed. Removes the previous version's entry when this looks like
    /// an update in place: the same app location as the last allowed build but a different signature. On the
    /// first launch of a version that keeps this record there's nothing to compare with yet, so that launch
    /// clears the entry too (for a new user there's nothing to clear). It's never done for a different copy
    /// of Paneful, such as a development build, so two copies don't keep undoing each other's grant.
    static func clearStaleGrantIfUpdated() {
        let defaults = UserDefaults.standard
        let lastSignature = defaults.string(forKey: trustedSignatureKey)
        let lastPath = defaults.string(forKey: trustedPathKey)
        let updatedInPlace = lastPath == Bundle.main.bundlePath && lastSignature != currentSignature
        guard lastSignature == nil || updatedInPlace else { return }
        if resetGrant() {
            clearedStaleGrant = lastSignature != nil
            Log.app.notice("Removed the Accessibility entry left by \(lastSignature == nil ? "an earlier version" : "the previous build", privacy: .public)")
        }
    }

    /// "Grant Accessibility Access…" in the menu: clear whatever entry exists, ask again and open the
    /// Accessibility settings, where the user only has to switch Paneful on.
    static func repair() {
        _ = resetGrant()
        prompt()
        openSystemSettings()
    }

    /// Removes Paneful's Accessibility entry (no admin password needed for an app's own entry).
    @discardableResult
    private static func resetGrant() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.app.error("tccutil failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// This build's code-directory hash (changes with every differently signed build), with the version as a
    /// fallback for unsigned `swift run` builds.
    private static var currentSignature: String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
           let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            return unique.map { String(format: "%02x", $0) }.joined()
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
