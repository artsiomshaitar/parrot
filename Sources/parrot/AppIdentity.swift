import Foundation

enum AppIdentity {
    static let executableName: String = {
        guard let first = CommandLine.arguments.first else { return "parrot" }
        return URL(fileURLWithPath: first).lastPathComponent
    }()

    static var isDev: Bool { executableName != "parrot" }

    /// Names the config directory and LaunchAgent label.
    static var profile: String { isDev ? executableName : "parrot" }

    static var configDirectory: String {
        NSString(string: "~/.config/\(profile)").expandingTildeInPath
    }

    /// Shared across profiles: the vocabulary is usually what's under test.
    static var sharedConfigDirectory: String {
        NSString(string: "~/.config/parrot").expandingTildeInPath
    }

    static var launchAgentLabel: String { "com.artsiomshaitar.\(profile)" }
}
