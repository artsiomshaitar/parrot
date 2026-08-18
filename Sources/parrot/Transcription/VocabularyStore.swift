import AppKit
import Foundation

/// Owns the vocabulary file: what's loaded, editing it, and reloading on save.
@MainActor
final class VocabularyStore {
    let path: String
    private(set) var vocabulary: Vocabulary?

    /// Called with the reloaded vocabulary whenever the file changes.
    var onChange: ((Vocabulary?) -> Void)?

    private var modified: Date?
    private var watch: Timer?

    init(path: String, vocabulary: Vocabulary?) {
        self.path = path
        self.vocabulary = vocabulary
        self.modified = Self.modificationDate(of: path)
    }

    deinit { watch?.invalidate() }

    var summary: String { Self.summary(of: vocabulary) }

    /// "63 terms, 3 rules" — what the menu shows, reflecting what actually
    nonisolated static func summary(of vocabulary: Vocabulary?) -> String {
        guard let vocabulary, !vocabulary.isEmpty else { return "empty" }
        var parts = [count(vocabulary.terms.count, "term")]
        if !vocabulary.replacements.isEmpty {
            parts.append(count(vocabulary.replacements.count, "rule"))
        }
        return parts.joined(separator: ", ")
    }

    nonisolated private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Opens the file in whatever handles .txt, creating it from a template
    func openInEditor() {
        do {
            try Vocabulary.ensureExists(at: path)
        } catch {
            logLine("couldn't create \(path): \(error)")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Polls the modification date rather than watching the file descriptor.
    func startWatching(interval: TimeInterval = 2) {
        watch?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func reloadIfChanged() {
        let now = Self.modificationDate(of: path)
        guard now != modified else { return }
        modified = now

        do {
            vocabulary = try Vocabulary.load(path: path, required: false)
        } catch {
            logLine("vocabulary reload failed, keeping previous: \(error)")
            return
        }
        logLine("vocabulary reloaded: \(summary)")
        onChange?(vocabulary)
    }

    private static func modificationDate(of path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}
