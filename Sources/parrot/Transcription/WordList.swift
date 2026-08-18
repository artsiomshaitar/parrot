import Foundation

/// Answers "is this an ordinary English word?".
protocol WordList {
    func contains(_ word: String) -> Bool
}

/// The word list macOS ships at /usr/share/dict/words (a symlink to `web2`).
struct SystemWordList: WordList {
    static let path = "/usr/share/dict/words"
    static let shared = SystemWordList()

    /// `web2` lists base forms only — no "called", no "cores". Without stemming
    private static let suffixes: [(suffix: String, replacement: String)] = [
        ("ing", ""), ("ing", "e"), ("ed", ""), ("ed", "e"), ("ies", "y"),
        ("es", ""), ("ers", ""), ("er", ""), ("er", "e"), ("s", ""), ("ly", ""),
    ]

    private static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    func contains(_ word: String) -> Bool {
        let word = word.lowercased()
        if Self.words.contains(word) { return true }
        return Self.suffixes.contains { suffix, replacement in
            guard word.hasSuffix(suffix) else { return false }
            let base = word.dropLast(suffix.count) + replacement
            return base.count >= 3 && Self.words.contains(String(base))
        }
    }
}

/// Fixed list, for tests and for the case where the system file is missing.
struct FixedWordList: WordList {
    private let words: Set<String>

    init(_ words: [String]) {
        self.words = Set(words.map { $0.lowercased() })
    }

    func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }
}
