import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let vocabulary: Vocabulary?
    /// BCP-47-ish language code ("en", "ru", …). nil lets Whisper auto-detect,
    /// which is unreliable on the short clips push-to-talk produces.
    private let language: String?
    private var pipeline: WhisperKit?
    /// Encoded once at warmup — tokenizing on every keypress would be waste.
    private var promptTokens: [Int]?

    /// Whether to feed vocabulary terms to the decoder as a conditioning prompt.
    ///
    /// Off by default, and deliberately so. Whisper receives the prompt as
    /// "text that preceded this audio", so a clip containing a prompt word can
    /// make the model treat it as already-transcribed and emit nothing at all —
    /// suppressing exactly the words you wanted to reinforce. It also disables
    /// WhisperKit's prefill cache, roughly tripling latency.
    private let usePromptTerms: Bool

    /// Token budget for the prompt. WhisperKit trims to
    /// `(maxTokenContext / 2) - 1` = 111 and shares the 224-token context with
    /// the output, so we stay well under and drop whole terms rather than
    /// letting it truncate mid-list.
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
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        pipeline = try await WhisperKit(config)

        // Leading space matters: Whisper's tokenizer is byte-level BPE, so a
        // word at the start of a string tokenizes differently than mid-sentence.
        if usePromptTerms, let vocabulary, !vocabulary.terms.isEmpty,
           let tokenizer = pipeline?.tokenizer {
            // Add terms until the budget is spent, so truncation drops whole
            // terms instead of cutting one in half.
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
                FileHandle.standardError.write(Data(
                    "prompt: \(kept.count)/\(vocabulary.terms.count) term(s), \(tokens.count) token(s)\n".utf8
                ))
            }
        }

        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        // Stay on nil options when nothing is configured, so the bare path keeps
        // WhisperKit's own defaults rather than ours.
        var options: DecodingOptions?
        if promptTokens != nil || language != nil {
            var o = DecodingOptions()
            o.promptTokens = promptTokens
            if let language {
                o.language = language
                // Pinning is pointless unless detection is off.
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
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
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
