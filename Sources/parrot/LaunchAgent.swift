import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
///
/// The plist passes no flags beyond `--skip-doctor`, so a login-started parrot
/// takes its model and hotkey from `~/.config/parrot/config.json`.
enum LaunchAgent {
    static let label = "com.artsiomshaitar.parrot"

    enum AgentError: Error, CustomStringConvertible {
        case binaryNotFound

        var description: String {
            switch self {
            case .binaryNotFound:
                return "couldn't locate the parrot binary; install it to /usr/local/bin/parrot first"
            }
        }
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// Enabled means "the plist is on disk" — that's what determines whether
    /// launchd starts parrot at the next login.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// True when this process was started by launchd rather than a shell.
    /// launchd-spawned agents are reparented to pid 1.
    static var isManagedByLaunchd: Bool { getppid() == 1 }

    /// Writes the plist.
    ///
    /// `bootstrap` loads it immediately, which also *starts* a copy because the
    /// plist sets `RunAtLoad`. Callers that are themselves a running parrot
    /// must pass false, or the user ends up with two daemons fighting over the
    /// hotkey and microphone.
    static func enable(bootstrap: Bool) throws {
        let binary = try resolveBinaryPath()

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/parrot.out.log",
            "StandardErrorPath": "/tmp/parrot.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        guard bootstrap else { return }
        _ = runLaunchctl(["bootout", "gui/\(getuid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
        if result.status != 0 {
            logLine("warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)")
        }
    }

    /// Removes the plist.
    ///
    /// Only boots the agent out when we aren't the agent — otherwise launchctl
    /// would terminate the very process asking to be disabled. Removing the
    /// plist is enough to stop it coming back at the next login.
    @discardableResult
    static func disable() throws -> Bool {
        let url = plistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if !isManagedByLaunchd {
            _ = runLaunchctl(["bootout", "gui/\(getuid())", url.path])
        }
        try FileManager.default.removeItem(at: url)
        return true
    }

    static func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            logLine("note: /usr/local/bin/parrot not found; using \(argv0)")
            return argv0
        }
        throw AgentError.binaryNotFound
    }

    @discardableResult
    static func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
