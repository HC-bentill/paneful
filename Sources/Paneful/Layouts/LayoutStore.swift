import Foundation

/// Saves layouts as JSON in ~/Library/Application Support/Paneful/layouts.json.
@MainActor
final class LayoutStore {
    private struct FileContents: Codable {
        var version: Int
        var layouts: [SavedLayout]
    }

    let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("Paneful", isDirectory: true).appendingPathComponent("layouts.json")
    }

    func load() -> [SavedLayout] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try Self.decoder.decode(FileContents.self, from: data).layouts
        } catch {
            Log.layouts.error("Could not read \(self.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func save(_ layouts: [SavedLayout]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(FileContents(version: 1, layouts: layouts)).write(to: url, options: .atomic)
        } catch {
            Log.layouts.error("Could not save \(self.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
