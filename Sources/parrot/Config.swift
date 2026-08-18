import Foundation

/// Persisted preferences, written by the menu bar and read at startup.
struct Config: Codable, Equatable {
    var model: String?
    var hotkey: String?

    static var path: String {
        AppIdentity.configDirectory + "/config.json"
    }

    /// A missing or malformed config is not fatal.
    static func load() -> Config {
        let source = FileManager.default.fileExists(atPath: path)
            ? path
            : AppIdentity.sharedConfigDirectory + "/config.json"
        guard let data = FileManager.default.contents(atPath: source) else {
            return Config()
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            logLine("warning: ignoring malformed \(source): \(error.localizedDescription)")
            return Config()
        }
    }

    func save() throws {
        let url = URL(fileURLWithPath: Self.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Resolved hotkey, ignoring an unparseable stored value.
    var resolvedHotkey: Hotkey? { hotkey.flatMap(Hotkey.init(name:)) }
}
