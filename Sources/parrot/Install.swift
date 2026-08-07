import ArgumentParser
import Foundation

/// CLI front-end for `LaunchAgent`. The same toggle is available from the menu
/// bar while parrot is running.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            if try LaunchAgent.disable() {
                print("✓ launch-at-login removed")
            } else {
                print("nothing to remove (no agent at \(LaunchAgent.plistURL.path))")
            }
        } else {
            // This command runs as its own short-lived process, so bootstrapping
            // is safe and starts the daemon right away.
            try LaunchAgent.enable(bootstrap: true)
            print("✓ launch-at-login installed")
            print("  plist:  \(LaunchAgent.plistURL.path)")
            print("  binary: \(try LaunchAgent.resolveBinaryPath())")
            print("  logs:   /tmp/parrot.out.log, /tmp/parrot.err.log")
        }
    }
}
