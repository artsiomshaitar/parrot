import Foundation

/// User-supplied vocabulary, loaded from a plain-text file.
///
/// Two mechanisms in one file, because they fix different problems:
///
///   * **Terms** are fed to Whisper as a conditioning prompt, biasing the
///     decoder toward spellings it would otherwise never produce. A bias, not
///     a guarantee.
///   * **Replacements** (`misheard => Correct`) are applied to the finished
///     transcript. Exact and deterministic — the right tool for a word the
///     model gets wrong the same way every time.
///
/// Format: one entry per line, `#` comments and blank lines ignored.
///
///     # terms to bias toward
///     HogQL
///     Postgres
///
///     # deterministic corrections
///     deal er => Deelr
///     post hog => PostHog
struct Vocabulary {
    let terms: [String]
    let replacements: [(from: String, to: String)]

    var isEmpty: Bool { terms.isEmpty && replacements.isEmpty }

    static var defaultPath: String {
        NSString(string: "~/.config/parrot/vocab.txt").expandingTildeInPath
    }

    /// Loads vocabulary from `path`.
    ///
    /// When `required` is false a missing file yields `nil` rather than an
    /// error — an absent default config just means "no vocabulary". An explicit
    /// `--vocab` that doesn't resolve is a real mistake and does throw.
    static func load(path: String, required: Bool) throws -> Vocabulary? {
        guard FileManager.default.fileExists(atPath: path) else {
            if required { throw VocabularyError.notFound(path) }
            return nil
        }
        let vocab = parse(try String(contentsOfFile: path, encoding: .utf8))
        return vocab.isEmpty ? nil : vocab
    }

    static func parse(_ text: String) -> Vocabulary {
        var terms: [String] = []
        var seen = Set<String>()
        var replacements: [(from: String, to: String)] = []

        func addTerm(_ t: String) {
            let key = t.lowercased()
            guard !t.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            terms.append(t)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let arrow = line.range(of: "=>") {
                let from = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
                let to = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty else { continue }
                replacements.append((from: from, to: to))
                // The corrected spelling is worth biasing toward as well, so
                // the model has a chance of getting it right unaided.
                addTerm(to)
            } else {
                addTerm(line)
            }
        }
        return Vocabulary(terms: terms, replacements: replacements)
    }

    /// Comma-joined enumeration. Whisper conditions on natural text, so a list
    /// reads better to the model than one term per line.
    var promptText: String { terms.joined(separator: ", ") }

    /// Applies replacements case-insensitively on word boundaries. Longest
    /// `from` first, so a specific phrase wins over a substring of itself.
    func apply(to text: String) -> String {
        var out = text
        for r in replacements.sorted(by: { $0.from.count > $1.from.count }) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: r.from))\\b"
            out = out.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: r.to),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }
}

enum VocabularyError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case .notFound(let path): return "vocabulary file not found: \(path)"
        }
    }
}
