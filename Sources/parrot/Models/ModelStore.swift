import Foundation
import WhisperKit

/// On-disk state for WhisperKit model folders.
enum ModelStore {
    static let repo = "argmaxinc/whisperkit-coreml"

    /// Mirrors HubApi's default download location.
    static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }

    static func folder(for model: TranscriptionModel) -> URL? {
        guard let id = model.whisperKitID else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    /// Requires the models WhisperKit won't load without; a partial download reads as missing.
    static func isDownloaded(_ model: TranscriptionModel) -> Bool {
        guard let folder = folder(for: model) else { return false }
        let fm = FileManager.default
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                fm.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path)
            }
        }
    }

    /// Downloads with progress; WhisperKit's implicit fetch reports nothing.
    static func download(
        _ model: TranscriptionModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let id = model.whisperKitID else { throw TranscriberError.missingEngineID }
        _ = try await WhisperKit.download(variant: id, from: repo) { p in
            progress(p.fractionCompleted)
        }
    }
}
