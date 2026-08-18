import Foundation

/// Reports when the microphone or output codec changes, system-wide.
final class InputDeviceMonitor {
    struct Snapshot: Equatable {
        let isRunning: Bool
        let outputSampleRate: Double

        static var current: Snapshot {
            Snapshot(
                isRunning: InputDeviceStatus.isRunning,
                outputSampleRate: InputDeviceStatus.outputSampleRate
            )
        }

        /// Call mode runs the output at 16 kHz or below.
        var isCallMode: Bool { outputSampleRate > 0 && outputSampleRate <= 24_000 }
    }

    private(set) var last: Snapshot
    private var timer: Timer?

    init() {
        last = .current
    }

    deinit { timer?.invalidate() }

    func start(interval: TimeInterval = 0.05, onChange: @escaping (Snapshot, Snapshot) -> Void) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Snapshot.current
            let previous = self.last
            guard now != previous else { return }
            self.last = now
            onChange(previous, now)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
