import AppKit
import Foundation

/// Owns the running daemon's mutable state so the menu bar can change the
/// model and hotkey without a restart.
///
/// Everything here is main-actor-bound: the hotkey callback already hops to
/// main, and the menu bar can only be touched there, so a single actor removes
/// the need for locking around the swappable transcriber.
@MainActor
final class Daemon {
    private let capture = AudioCapture()
    private let overlay: RecordingOverlay?
    private let vocabulary: Vocabulary?
    private let language: String?
    private let usePromptTerms: Bool
    private let dumpWav: Bool
    private let debugHotkey: Bool

    private var transcriber: WhisperKitTranscriber
    private var model: TranscriptionModel
    private var hotkey: Hotkey
    private var monitor: HotkeyMonitor?
    private var menuBar: MenuBarController!
    /// Guards against a second model load starting while one is in flight.
    private var isSwitchingModel = false

    init(
        model: TranscriptionModel,
        transcriber: WhisperKitTranscriber,
        hotkey: Hotkey,
        vocabulary: Vocabulary?,
        language: String?,
        usePromptTerms: Bool,
        overlay: RecordingOverlay?,
        dumpWav: Bool,
        debugHotkey: Bool
    ) {
        self.model = model
        self.transcriber = transcriber
        self.hotkey = hotkey
        self.vocabulary = vocabulary
        self.language = language
        self.usePromptTerms = usePromptTerms
        self.overlay = overlay
        self.dumpWav = dumpWav
        self.debugHotkey = debugHotkey

        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }

        menuBar = MenuBarController(
            modelID: model.id,
            hotkey: hotkey,
            launchAtLogin: LaunchAgent.isEnabled,
            onSelectModel: { [weak self] id in self?.selectModel(id) },
            onSelectHotkey: { [weak self] key in self?.selectHotkey(key) },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() }
        )
    }

    private func toggleLaunchAtLogin() {
        do {
            if LaunchAgent.isEnabled {
                try LaunchAgent.disable()
                logLine("start at login → off")
            } else {
                // Never bootstrap from here: the plist sets RunAtLoad, so
                // loading it now would spawn a second daemon alongside this one.
                try LaunchAgent.enable(bootstrap: false)
                logLine("start at login → on (takes effect at next login)")
            }
        } catch {
            logLine("couldn't change start-at-login: \(error)")
        }
        menuBar.setLaunchAtLogin(LaunchAgent.isEnabled)
    }

    // MARK: - Lifecycle

    func start() throws {
        try startMonitor()
        logLine("listening on \(hotkey.label) hold · model: \(model.id) · ^C to quit")
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }

    private func startMonitor() throws {
        let monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        try monitor.start { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        self.monitor = monitor
    }

    // MARK: - Preferences

    private func selectHotkey(_ key: Hotkey) {
        monitor?.stop()
        monitor = nil
        hotkey = key
        do {
            try startMonitor()
        } catch {
            logLine("failed to rebind hotkey: \(error)")
            return
        }
        menuBar.setHotkey(key)
        persist { $0.hotkey = key.label }
        logLine("hotkey → \(key.label)")
    }

    private func selectModel(_ id: String) {
        guard !isSwitchingModel, let next = ModelRegistry.find(id) else { return }
        isSwitchingModel = true
        menuBar.setLoadingModel(id)
        logLine("switching model → \(id)")

        let candidate = WhisperKitTranscriber(
            model: next,
            vocabulary: vocabulary,
            language: language,
            usePromptTerms: usePromptTerms
        )

        Task { [weak self] in
            do {
                // Warm up before swapping, so a failed download or load leaves
                // the working model in place.
                try await candidate.warmUp()
                await MainActor.run {
                    guard let self else { return }
                    self.transcriber = candidate
                    self.model = next
                    self.menuBar.setModel(id)
                    self.isSwitchingModel = false
                    self.persist { $0.model = id }
                    logLine("model → \(id)")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.menuBar.setModel(self.model.id)
                    self.isSwitchingModel = false
                    logLine("model switch failed, staying on \(self.model.id): \(error)")
                }
            }
        }
    }

    private func persist(_ mutate: (inout Config) -> Void) {
        var config = Config.load()
        mutate(&config)
        do {
            try config.save()
        } catch {
            logLine("warning: couldn't save \(Config.path): \(error)")
        }
    }

    // MARK: - Hotkey handling

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            do {
                try capture.start()
                logLine("● recording")
                overlay?.show(.recording)
                menuBar.setRecording(true)
            } catch {
                logLine("capture failed: \(error)")
            }

        case .released:
            let samples = capture.stop()
            overlay?.show(.transcribing)
            menuBar.setTranscribing()

            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            logLine(String(format: "○ captured %.2fs · rms %.3f", seconds, computeRMS(samples)))

            if dumpWav, !samples.isEmpty {
                let path = "/tmp/parrot-last.wav"
                do {
                    try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                    logLine("  wrote \(path)")
                } catch {
                    logLine("  wav write failed: \(error)")
                }
            }

            guard !samples.isEmpty else {
                overlay?.hide()
                menuBar.setRecording(false)
                return
            }

            let transcriber = self.transcriber
            Task { [weak self] in
                let started = Date()
                do {
                    let text = try await transcriber.transcribe(samples)
                    logLine(String(format: "→ %.2fs · %@", Date().timeIntervalSince(started), text))
                    await MainActor.run {
                        TextInjector.inject(text)
                        self?.finishTurn()
                    }
                } catch {
                    logLine("transcription failed: \(error)")
                    await MainActor.run { self?.finishTurn() }
                }
            }
        }
    }

    private func finishTurn() {
        overlay?.hide()
        // A model switch may have finished mid-transcription; don't clobber
        // its label with a stale idle title.
        if !isSwitchingModel { menuBar.setRecording(false) }
    }
}

func logLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
