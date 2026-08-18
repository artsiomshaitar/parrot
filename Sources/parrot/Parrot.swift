import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AppIdentity.executableName,
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Vocab.self, MicProbe.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Log microphone acquire/release with timestamps (debug).")
    var debugMic: Bool = false

    @Option(
        name: .long,
        help: "Keep the mic open this many seconds after a dictation, so a follow-up doesn't re-switch a Bluetooth headset. 0 releases immediately."
    )
    var micHold: Double = 3


    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "Push-to-talk key: \(Hotkey.allValueStrings.joined(separator: " | ")). Overrides the saved preference."
    )
    var hotkey: Hotkey?

    @Option(
        name: .long,
        help: "Vocabulary file. Defaults to ~/.config/parrot/vocab.txt if present."
    )
    var vocab: String?

    @Option(
        name: .long,
        help: "Pin transcription to a language code (e.g. en, ru). Omit to auto-detect."
    )
    var language: String?

    @Flag(
        name: .long,
        help: "Feed vocabulary terms to the model as a prompt. Experimental — can suppress the words it's given and slows transcription."
    )
    var promptTerms: Bool = false

    func run() throws {
        if debugMic { LogOptions.timestamps = true }
        let config = Config.load()
        let chosenHotkey = hotkey ?? config.resolvedHotkey ?? .fn

        if !skipDoctor {
            let checks = DoctorReport.run(hotkey: chosenHotkey)
            if !DoctorReport.allOK(checks) {
                logLine("startup checks failed:")
                DoctorReport.print(checks)
                logLine("\nfix the above or pass --skip-doctor")
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model ?? config.model {
            guard let m = ModelRegistry.find(id) else {
                logLine("unknown model: \(id)")
                logLine("run `parrot models list` to see options.")
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                logLine("no models registered")
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let vocabulary: Vocabulary?
        do {
            vocabulary = try Vocabulary.load(
                path: vocab ?? Vocabulary.defaultPath,
                required: vocab != nil
            )
        } catch {
            logLine("\(error)")
            throw ExitCode(1)
        }
        if let vocabulary {
            logLine("vocabulary: \(vocabulary.terms.count) term(s), \(vocabulary.replacements.count) replacement(s)")
        }

        let transcriber = WhisperKitTranscriber(
            model: chosenModel,
            vocabulary: vocabulary,
            language: language,
            usePromptTerms: promptTerms
        )
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            logLine("warmup failed: \(warmupError)")
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let daemon = MainActor.assumeIsolated {
            Daemon(
                model: chosenModel,
                transcriber: transcriber,
                hotkey: chosenHotkey,
                vocabulary: vocabulary,
                vocabPath: vocab ?? Vocabulary.defaultPath,
                language: language,
                usePromptTerms: promptTerms,
                overlay: noOverlay ? nil : RecordingOverlay(),
                dumpWav: dumpWav,
                debugHotkey: debugHotkey,
                debugMic: debugMic,
                micHold: micHold
            )
        }

        do {
            try MainActor.assumeIsolated { try daemon.start() }
        } catch {
            logLine("failed to register hotkey tap: \(error)")
            logLine("run `parrot setup` to configure permissions.")
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            logLine("\nshutting down")
            MainActor.assumeIsolated { daemon.stop() }
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    @Option(
        name: .long,
        help: "Hotkey to validate against: \(Hotkey.allValueStrings.joined(separator: " | "))."
    )
    var hotkey: Hotkey?

    func run() throws {
        let resolved = hotkey ?? Config.load().resolvedHotkey ?? .fn
        let checks = DoctorReport.run(hotkey: resolved)
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                let state = (ModelStore.isDownloaded(m) ? "downloaded" : "not downloaded")
                    .padding(toLength: 14, withPad: " ", startingAt: 0)
                print("\(star) \(id) \(size)  \(langs)  \(state)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}
