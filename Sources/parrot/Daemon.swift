import AppKit
import Foundation

/// Owns the daemon's mutable state so the menu bar can change it live.
@MainActor
final class Daemon {
    private let capture = AudioCapture()
    private let overlay: RecordingOverlay?
    private let vocabularyStore: VocabularyStore
    private let language: String?
    private let usePromptTerms: Bool
    private let dumpWav: Bool
    private let debugHotkey: Bool
    private let debugMic: Bool
    private var deviceMonitor: InputDeviceMonitor?
    /// True between key down and key up.
    private var isHolding = false
    private var micWasRunning = false
    private var lastOutputRate: Double = 0

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
        vocabPath: String,
        language: String?,
        usePromptTerms: Bool,
        overlay: RecordingOverlay?,
        dumpWav: Bool,
        debugHotkey: Bool,
        debugMic: Bool = false,
        micHold: Double = 3
    ) {
        self.model = model
        self.transcriber = transcriber
        self.hotkey = hotkey
        self.vocabularyStore = VocabularyStore(path: vocabPath, vocabulary: vocabulary)
        self.language = language
        self.usePromptTerms = usePromptTerms
        self.overlay = overlay
        self.dumpWav = dumpWav
        self.debugHotkey = debugHotkey
        self.debugMic = debugMic
        capture.debug = debugMic
        capture.holdSeconds = micHold

        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        capture.onFirstBuffer = { [weak self] waited in
            Task { @MainActor in
                guard let self, self.isHolding else { return }
                self.overlay?.show(.recording)
                self.menuBar.setRecording(true)
                if self.debugMic {
                    logLine(String(format: "overlay: live after %.0fms", waited * 1000))
                }
            }
        }

        menuBar = MenuBarController(
            modelID: model.id,
            hotkey: hotkey,
            launchAtLogin: LaunchAgent.isEnabled,
            vocabularySummary: vocabularyStore.summary,
            onSelectModel: { [weak self] id in self?.selectModel(id) },
            onSelectHotkey: { [weak self] key in self?.selectHotkey(key) },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onEditVocabulary: { [weak self] in self?.vocabularyStore.openInEditor() }
        )

        vocabularyStore.onChange = { [weak self] reloaded in
            self?.vocabularyChanged(to: reloaded)
        }
        vocabularyStore.startWatching()
        if debugMic { startWatchingMicrophone() }
    }

    private func vocabularyChanged(to vocabulary: Vocabulary?) {
        menuBar.setVocabularySummary(vocabularyStore.summary)
        let transcriber = self.transcriber
        Task { await transcriber.updateVocabulary(vocabulary) }
    }

    private func startWatchingMicrophone() {
        let monitor = InputDeviceMonitor()
        logLine("mic: watching \(InputDeviceStatus.name) — currently \(monitor.last.isRunning ? "IN USE" : "free")")
        logLine(String(format: "mic: output running at %.0f Hz", monitor.last.outputSampleRate))
        monitor.start { previous, current in
            if current.isRunning != previous.isRunning {
                logLine(current.isRunning ? "mic: device ACQUIRED" : "mic: device released")
            }
            if current.outputSampleRate != previous.outputSampleRate {
                logLine(String(
                    format: "mic: output → %.0f Hz — %@",
                    current.outputSampleRate,
                    current.isCallMode ? "CALL MODE (bad audio)" : "music codec"
                ))
            }
        }
        deviceMonitor = monitor
    }

    private func toggleLaunchAtLogin() {
        do {
            if LaunchAgent.isEnabled {
                try LaunchAgent.disable()
                logLine("start at login → off")
            } else {
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

        let needsDownload = !ModelStore.isDownloaded(next)
        if needsDownload {
            menuBar.setDownloadProgress(id, 0)
            logLine("downloading \(id) (\(next.sizeMB) MB)…")
        } else {
            menuBar.setLoadingModel(id)
        }
        logLine("switching model → \(id)")

        let candidate = WhisperKitTranscriber(
            model: next,
            vocabulary: vocabularyStore.vocabulary,
            language: language,
            usePromptTerms: usePromptTerms
        )

        let menuBar = self.menuBar!
        let onProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in menuBar.setDownloadProgress(id, fraction) }
        }

        Task { [weak self] in
            do {
                if needsDownload {
                    try await ModelStore.download(next, progress: onProgress)
                    logLine("downloaded \(id)")
                }
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
                isHolding = true
                try capture.start()
                logLine("● recording")
                overlay?.show(.warmingUp)
            } catch {
                isHolding = false
                logLine("capture failed: \(error)")
            }

        case .released:
            isHolding = false
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
        if !isSwitchingModel { menuBar.setRecording(false) }
    }
}
