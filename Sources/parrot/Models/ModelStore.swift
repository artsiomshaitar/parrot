import Foundation
import WhisperKit

/// On-disk state for WhisperKit model folders.
///
/// WhisperKit downloads through swift-transformers' HubApi, which lands
/// snapshots under `~/Documents/huggingface/models/<repo>`. Mirroring that path
/// here lets the menu report whether a model is present *before* you pick it —
/// otherwise selecting Large v3 Turbo starts a 1.6 GB download with no visible
/// difference from a model that was already there.
enum ModelStore {
    static let repo = "argmaxinc/whisperkit-coreml"

    /// Matches `HubApi`'s default `downloadBase` (Documents/huggingface) joined
    /// with the repo layout it writes. If WhisperKit ever changes that default,
    /// models read as missing and get re-downloaded rather than misreported.
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

    /// The folder existing isn't enough — an interrupted download leaves a
    /// partial one behind. These are the three compiled models WhisperKit
    /// itself refuses to load without, so "downloaded" here means the same
    /// thing it means to the engine.
    static func isDownloaded(_ model: TranscriptionModel) -> Bool {
        guard let folder = folder(for: model) else { return false }
        let fm = FileManager.default
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                fm.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path)
            }
        }
    }

    /// Fetches the model with progress. Downloading explicitly rather than
    /// letting `WhisperKit.init` do it implicitly is the whole point: the
    /// implicit path reports nothing until it's finished.
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
