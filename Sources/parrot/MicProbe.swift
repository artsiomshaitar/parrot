import ArgumentParser
import Foundation

struct MicProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mic-probe",
        abstract: "Record briefly and report when the microphone is released."
    )

    @Option(name: .long, help: "Seconds to record per cycle.")
    var seconds: Double = 2

    @Option(name: .long, help: "How many record/stop cycles to run.")
    var cycles: Int = 1

    @Option(name: .long, help: "Seconds to keep the mic open between cycles.")
    var hold: Double = 0

    @Option(name: .long, help: "Seconds to keep watching after recording stops.")
    var watch: Double = 12

    @Flag(name: .long, help: "Don't record — just watch the device and report every change.")
    var watchOnly: Bool = false

    func run() throws {
        print("input device: \(InputDeviceStatus.name)")
        let log = ProbeLog()

        if watchOnly {
            try runWatchOnly(log: log)
            return
        }

        print("cycles: \(cycles), hold: \(hold)s\n")
        let capture = AudioCapture()
        capture.holdSeconds = hold

        for cycle in 1...max(cycles, 1) {
            log.line("cycle \(cycle): before start")
            try capture.start()
            log.line("cycle \(cycle): recording")
            wait(seconds)

            let audio = capture.stop()
            let duration = Double(audio.count) / AudioCapture.targetSampleRate
            log.line(String(
                format: "cycle %d: stopped — %.2fs audio, rms %.3f",
                cycle, duration, computeRMS(audio)
            ))
            if cycle < cycles { wait(1.5) }
        }

        let monitor = InputDeviceMonitor()
        monitor.start { _, current in
            log.line(current.isRunning ? "re-acquired" : "released")
        }
        wait(watch)
        log.line("end of watch")

        if InputDeviceStatus.isRunning {
            print("\n✗ still holding the microphone \(Int(watch))s after stopping")
            throw ExitCode(1)
        }
        print("\n✓ microphone released")
    }

    /// Watches another process hold and release the device.
    private func runWatchOnly(log: ProbeLog) throws {
        print("watching — dictate now, ^C to stop")
        print("(each line reports how long the previous state lasted)\n")

        let monitor = InputDeviceMonitor()
        log.line(monitor.last.isRunning ? "in use at start" : "free at start")

        var since = Date()
        monitor.start { previous, current in
            let held = Date().timeIntervalSince(since)
            since = Date()
            if current.isRunning != previous.isRunning {
                log.line(String(
                    format: "%@ after %.2fs",
                    current.isRunning ? "ACQUIRED" : "released", held
                ))
            }
            if current.outputSampleRate != previous.outputSampleRate {
                log.line(String(
                    format: "output → %.0f Hz — %@",
                    current.outputSampleRate,
                    current.isCallMode ? "CALL MODE (bad audio)" : "music codec"
                ))
            }
        }
        while true { wait(1) }
    }

    private func wait(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }
}

private final class ProbeLog {
    private let started = Date()

    func line(_ note: String) {
        let snapshot = InputDeviceMonitor.Snapshot.current
        print(String(
            format: "  %6.2fs  %@ %5.0fHz  %@",
            Date().timeIntervalSince(started),
            snapshot.isRunning ? "IN USE " : "free   ",
            snapshot.outputSampleRate,
            note
        ))
    }
}
