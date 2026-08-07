import Foundation

/// Persisted preferences, written by the menu bar and read at startup.
///
/// Lives next to `vocab.txt` in `~/.config/parrot/`. Precedence is
/// CLI flag → config file → built-in default, so an explicit flag always wins
/// and the config is what you get when you launch with no arguments — which is
/// how the LaunchAgent runs parrot.
struct Config: Codable, Equatable {
    var model: String?
    var hotkey: String?

    static var path: String {
        NSString(string: "~/.config/parrot/config.json").expandingTildeInPath
    }

    /// A missing or malformed config is not fatal — preferences are a
    /// convenience, and refusing to start over them would be hostile.
    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path) else {
            return Config()
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: ignoring malformed \(path): \(error.localizedDescription)\n".utf8
            ))
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
