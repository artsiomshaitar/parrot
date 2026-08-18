import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
enum LaunchAgent {
    static var label: String { AppIdentity.launchAgentLabel }

    enum AgentError: Error, CustomStringConvertible {
        case binaryNotFound

        var description: String {
            switch self {
            case .binaryNotFound:
                return "couldn't locate the \(AppIdentity.executableName) binary; install it to /usr/local/bin first"
            }
        }
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// Enabled means the plist is on disk.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var isManagedByLaunchd: Bool { getppid() == 1 }

    static func enable(bootstrap: Bool) throws {
        let binary = try resolveBinaryPath()

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/\(AppIdentity.profile).out.log",
            "StandardErrorPath": "/tmp/\(AppIdentity.profile).err.log",
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
        let name = AppIdentity.executableName
        let candidates = [
            "/usr/local/bin/\(name)",
            NSString(string: "~/.local/bin/\(name)").expandingTildeInPath,
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
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
