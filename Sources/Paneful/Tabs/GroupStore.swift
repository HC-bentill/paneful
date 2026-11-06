import Foundation

/// How Paneful recognises a window again after it closes and reopens.
struct WindowSignature: Codable, Hashable {
    var bundleID: String
    /// Shown in the "Remembered Groups" menu.
    var appName: String
    /// The window's title, recorded only when its app had several windows. `nil` = match on app alone.
    var titleHint: String?
    /// How often the title changed while grouped. Titles that keep changing (browsers) stop being used.
    var titleChanges: Int = 0

    static let volatileTitleThreshold = 3

    /// Loose title comparison: equal, or one contains the other (ignoring case and edge whitespace).
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        return short.count >= 4 && long.contains(short)
    }
}

/// A tab group as saved on disk.
struct StoredGroup: Codable {
    var id: UUID
    var members: [WindowSignature]
    /// Last frame (AX coordinates) shared by the group's windows.
    var contentFrame: CGRect
}

/// Saves remembered tab groups as JSON in ~/Library/Application Support/Paneful/groups.json.
@MainActor
final class GroupStore {
    static let shared = GroupStore()

    private struct FileContents: Codable {
        var version: Int
        var groups: [StoredGroup]
    }

    let url: URL
    private var pendingSave: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("Paneful", isDirectory: true).appendingPathComponent("groups.json")
    }

    func load() -> [StoredGroup] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode(FileContents.self, from: data).groups
        } catch {
            NSLog("Paneful: could not read \(url.path): \(error)")
            return []
        }
    }

    /// Saves after a short pause, so bursts of changes (dragging a group around) cause one write.
    func save(_ groups: [StoredGroup]) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.write(groups) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveNow(_ groups: [StoredGroup]) {
        pendingSave?.cancel()
        pendingSave = nil
        write(groups)
    }

    private func write(_ groups: [StoredGroup]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FileContents(version: 1, groups: groups))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Paneful: could not save \(url.path): \(error)")
        }
    }
}
