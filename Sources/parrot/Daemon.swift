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
    private let vocabPath: String
    private var vocabulary: Vocabulary?
    /// mtime of the vocabulary file as of the last load, so we only re-parse
    /// when it actually changed.
    private var vocabModified: Date?
    private var vocabWatch: Timer?
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
        vocabPath: String,
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
        self.vocabPath = vocabPath
        self.vocabModified = Self.modifiedAt(vocabPath)
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
            vocabularySummary: Self.summary(vocabulary),
            onSelectModel: { [weak self] id in self?.selectModel(id) },
            onSelectHotkey: { [weak self] key in self?.selectHotkey(key) },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onEditVocabulary: { [weak self] in self?.editVocabulary() }
        )
        startWatchingVocabulary()
    }

    // MARK: - Vocabulary

    private static func summary(_ vocabulary: Vocabulary?) -> String {
        guard let vocabulary, !vocabulary.isEmpty else { return "empty" }
        var parts = ["\(vocabulary.terms.count) term\(vocabulary.terms.count == 1 ? "" : "s")"]
        if !vocabulary.replacements.isEmpty {
            parts.append("\(vocabulary.replacements.count) rule\(vocabulary.replacements.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    private static func modifiedAt(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// Opens the vocabulary in whatever handles .txt, creating it first if it
    /// doesn't exist yet.
    private func editVocabulary() {
        do {
            try Vocabulary.ensureExists(at: vocabPath)
        } catch {
            logLine("couldn't create \(vocabPath): \(error)")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: vocabPath))
    }

    /// Polls the modification date rather than watching the file descriptor.
    /// Editors save atomically — write a temp file, rename it over the original
    /// — which replaces the inode and leaves an fd-based watch pointing at a
    /// file nobody will ever write to again. One stat every two seconds is
    /// cheaper than getting that right.
    private func startWatchingVocabulary() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadVocabularyIfChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        vocabWatch = timer
    }

    private func reloadVocabularyIfChanged() {
        let modified = Self.modifiedAt(vocabPath)
        guard modified != vocabModified else { return }
        vocabModified = modified

        let reloaded: Vocabulary?
        do {
            reloaded = try Vocabulary.load(path: vocabPath, required: false)
        } catch {
            logLine("vocabulary reload failed, keeping previous: \(error)")
            return
        }
        vocabulary = reloaded
        menuBar.setVocabularySummary(Self.summary(reloaded))
        let transcriber = self.transcriber
        Task { await transcriber.updateVocabulary(reloaded) }
        logLine("vocabulary reloaded: \(Self.summary(reloaded))")
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

        // Download explicitly when the model isn't on disk. WhisperKit's
        // initializer would fetch it anyway, but silently — picking a 1.6 GB
        // model would look identical to picking one already downloaded.
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
            vocabulary: vocabulary,
            language: language,
            usePromptTerms: usePromptTerms
        )

        // Capture the menu bar directly rather than reaching through a weak
        // `self` from inside two nested tasks — WhisperKit calls this back off
        // its own download machinery, and the doubly-captured form is an error
        // under the Swift 6 language mode.
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
