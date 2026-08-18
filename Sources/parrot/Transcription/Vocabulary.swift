import Foundation

/// User-supplied vocabulary, loaded from a plain-text file.
struct Vocabulary {
    /// A user-declared correction, matched by sound like everything else.
    struct Replacement {
        let from: String
        let to: String
        /// `~>` instead of `=>`: allow one phoneme of slack. Aggressive enough
        let fuzzy: Bool
    }

    let terms: [String]
    let replacements: [Replacement]
    /// Built once at load — matching is then a dictionary lookup per phrase.
    let matcher: PhoneticMatcher

    var isEmpty: Bool { terms.isEmpty && replacements.isEmpty }

    static var defaultPath: String {
        AppIdentity.sharedConfigDirectory + "/vocab.txt"
    }

    /// Written when the menu opens a vocabulary that doesn't exist yet.
    static let template = """
    # parrot vocabulary
    #
    # Terms are matched by SOUND. One line covers every way the model mangles
    # it: "PostHog" catches "post hog", "post hawk", "post hogg" and variants
    # you haven't hit yet.
    #
    #   PostHog
    #   Kubernetes
    #   TypeScript
    #
    # When the mishearing isn't close enough to the term, declare it yourself.
    # Rules are matched by sound too, and always win over terms:
    #
    #   my sequel => MySQL
    #
    # Use ~> instead of => to allow one sound of slack. Stronger, and strong
    # enough to rewrite ordinary words, so use it only where you mean it:
    #
    #   deal er ~> Deelr        # also catches "dealer"
    #
    # Saving this file reloads it — no restart needed.
    # Test without talking:  parrot vocab test "the post hawk dashboard"


    """

    /// Creates the file with the template if it's missing. Returns the path.
    @discardableResult
    static func ensureExists(at path: String) throws -> String {
        guard !FileManager.default.fileExists(atPath: path) else { return path }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try template.write(to: url, atomically: true, encoding: .utf8)
        return path
    }

    /// Loads vocabulary from `path`.
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
        var replacements: [Replacement] = []

        func addTerm(_ t: String) {
            let key = t.lowercased()
            guard !t.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            terms.append(t)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let arrow = line.range(of: "=>") ?? line.range(of: "~>")
            if let arrow {
                let fuzzy = line[arrow].hasPrefix("~")
                let from = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
                let to = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty else { continue }
                replacements.append(Replacement(from: from, to: to, fuzzy: fuzzy))
                addTerm(to)
            } else {
                addTerm(line)
            }
        }
        return Vocabulary(
            terms: terms,
            replacements: replacements,
            matcher: PhoneticMatcher(terms: terms, rules: replacements)
        )
    }

    /// Comma-joined enumeration. Whisper conditions on natural text, so a list
    var promptText: String { terms.joined(separator: ", ") }

    /// Exact replacements first, then the phonetic pass over what's left.
    func apply(to text: String) -> String {
        matcher.apply(to: applyReplacements(to: text))
    }

    /// Applies replacements case-insensitively on word boundaries. Longest
    func applyReplacements(to text: String) -> String {
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
