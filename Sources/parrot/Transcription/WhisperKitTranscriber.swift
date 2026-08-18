import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var vocabulary: Vocabulary?
    /// BCP-47-ish language code ("en", "ru", …). nil lets Whisper auto-detect,
    private let language: String?
    private var pipeline: WhisperKit?
    /// Encoded once at warmup — tokenizing on every keypress would be waste.
    private var promptTokens: [Int]?

    /// Whether to feed vocabulary terms to the decoder as a conditioning prompt.
    private let usePromptTerms: Bool

    /// Prompt token budget, kept well under WhisperKit's 224-token context.
    private static let promptTokenBudget = 80

    init(
        model: TranscriptionModel,
        vocabulary: Vocabulary? = nil,
        language: String? = nil,
        usePromptTerms: Bool = false
    ) {
        self.modelID = model.id
        self.model = model
        self.vocabulary = vocabulary
        self.language = language
        self.usePromptTerms = usePromptTerms
    }

    /// Loads the model into memory; downloads first if not already on disk.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        logLine("loading \(model.id)...")
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        pipeline = try await WhisperKit(config)

        if usePromptTerms, let vocabulary, !vocabulary.terms.isEmpty,
           let tokenizer = pipeline?.tokenizer {
            var kept: [String] = []
            var tokens: [Int] = []
            for term in vocabulary.terms {
                let candidate = tokenizer.encode(text: " " + (kept + [term]).joined(separator: ", "))
                if candidate.count > Self.promptTokenBudget { break }
                kept.append(term)
                tokens = candidate
            }
            if !tokens.isEmpty {
                promptTokens = tokens
                logLine("prompt: \(kept.count)/\(vocabulary.terms.count) term(s), \(tokens.count) token(s)")
            }
        }

        logLine("✓ \(model.id) ready")
    }

    /// Swaps in a re-read vocabulary file. Only the transcript rewriting picks
    func updateVocabulary(_ vocabulary: Vocabulary?) {
        self.vocabulary = vocabulary
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        var options: DecodingOptions?
        if promptTokens != nil || language != nil {
            var o = DecodingOptions()
            o.promptTokens = promptTokens
            if let language {
                o.language = language
                o.detectLanguage = false
            }
            options = o
        }

        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        let cleaned = Self.sanitize(raw)
        return vocabulary?.apply(to: cleaned) ?? cleaned
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
