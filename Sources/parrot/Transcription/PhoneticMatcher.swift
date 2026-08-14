import Foundation

/// The system word list, used to decide whether a heard word is ordinary
/// English and therefore off limits.
///
/// macOS ships this (a symlink to `web2`), so it costs nothing to depend on.
enum EnglishWords {
    static let path = "/usr/share/dict/words"

    private static let set: Set<String> = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// `web2` lists base forms only — no "called", no "cores". Without stemming,
    /// those read as non-words and get rewritten ("called" → "Claude").
    private static let suffixes: [(String, String)] = [
        ("ing", ""), ("ing", "e"), ("ed", ""), ("ed", "e"), ("ies", "y"),
        ("es", ""), ("ers", ""), ("er", ""), ("er", "e"), ("s", ""), ("ly", ""),
    ]

    static func contains(_ word: String) -> Bool {
        let w = word.lowercased()
        if set.contains(w) { return true }
        for (suffix, replacement) in suffixes where w.hasSuffix(suffix) {
            let base = String(w.dropLast(suffix.count)) + replacement
            if base.count >= 3, set.contains(base) { return true }
        }
        return false
    }
}

/// Rewrites phrases that *sound like* a vocabulary term into that term.
///
/// This is what lets one line (`PostHog`) cover "post hog", "post hawk",
/// "post hogg" and the variants nobody has hit yet, instead of one `=>` rule
/// per mishearing.
///
/// A replacement needs two independent signals to agree — the phonetic key and
/// an orthographic similarity floor. Phonetic keys alone are far too lossy:
/// "dealer", "dollar" and "Deelr" all encode to TLR.
struct PhoneticMatcher {
    /// Jaro-Winkler floor. Measured: below 0.82 false positives appear in
    /// ordinary prose, above 0.88 real mishearings start being missed.
    static let similarityFloor = 0.85
    /// Terms shorter than this are exact-match only — short keys collide freely.
    static let minTermLength = 4
    /// Longest phrase considered. "phoenix live view" is three.
    static let maxWindow = 3

    struct Match {
        let range: Range<String.Index>
        let heard: String
        let term: String
        let similarity: Double
    }

    /// key → canonical terms, built once when the vocabulary loads.
    let index: [String: [String]]

    init(terms: [String]) {
        var index: [String: [String]] = [:]
        for term in terms {
            for key in Self.keys(for: term) {
                index[key, default: []].append(term)
            }
        }
        self.index = index
    }

    /// Two keys per term, because a term can be spoken two ways.
    ///
    /// "PostHog" as one word encodes to PS0K — the S and H fuse into a *th*
    /// sound, as if it were "possthog". Nobody says that. Split on the internal
    /// capital and you get PST+HK, which is exactly what saying "post hog"
    /// produces. Without the split key almost nothing multi-word matches.
    static func keys(for term: String) -> Set<String> {
        var keys: Set<String> = []
        let flat = term.filter { $0.isASCII && $0.isLetter }
        if !flat.isEmpty { keys.insert(Metaphone.encode(flat)) }

        let parts = splitWords(term)
        if !parts.isEmpty {
            keys.insert(parts.map { Metaphone.encode($0) }.joined())
        }
        // Word-initial X encodes as S, so "Xcode" (SKT) can never meet "ex code"
        // (EKSKT). Spell the X out for terms that start with one.
        if let first = flat.first, first == "X" || first == "x" {
            keys.insert(Metaphone.encode("EX" + String(flat.dropFirst())))
        }
        return keys.filter { !$0.isEmpty }
    }

    /// "PostHog" → [Post, Hog]; "React Native" → [React, Native]; "Node.js" → [Node, js].
    static func splitWords(_ term: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in term {
            if ch.isWhitespace || ch == "." || ch == "_" || ch == "-" {
                if !current.isEmpty { parts.append(current); current = "" }
            } else if ch.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.filter { !$0.isEmpty }
    }

    func matches(in text: String) -> [Match] {
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return [] }

        var used = [Bool](repeating: false, count: tokens.count)
        var found: [Match] = []

        // Longest window first, so "swift UI" wins over "swift" alone.
        for n in stride(from: Self.maxWindow, through: 1, by: -1) {
            guard tokens.count >= n else { continue }
            for i in 0...(tokens.count - n) {
                if used[i..<(i + n)].contains(true) { continue }
                let span = tokens[i..<(i + n)]
                guard let first = span.first, let last = span.last else { continue }
                let range = first.range.lowerBound..<last.range.upperBound

                // A phrase doesn't straddle a sentence boundary.
                if text[range].contains(where: { ".!?;:,".contains($0) }) { continue }
                // Don't match a fragment of a longer alphanumeric run — "ch" out
                // of "ch8256" is not a word anyone said.
                if Self.isPartOfLargerToken(text, range) { continue }

                let words = span.map { $0.text }
                let heard = String(text[range])
                let flat = words.joined().lowercased()
                let key = words.map { Metaphone.encode($0) }.joined()
                guard !key.isEmpty, let candidates = index[key] else { continue }

                for term in candidates {
                    let canonical = term.filter { $0.isASCII && $0.isLetter }
                    if canonical.count < Self.minTermLength { continue }
                    if heard == term { continue }  // already correct
                    // A single ordinary English word is never rewritten. It is
                    // the difference between "the cores are hot" surviving and
                    // becoming "the CORS are hot".
                    if n == 1, EnglishWords.contains(words[0]) { continue }

                    let similarity = Similarity.jaroWinkler(flat, canonical.lowercased())
                    if similarity < Self.similarityFloor { continue }

                    found.append(Match(range: range, heard: heard, term: term, similarity: similarity))
                    for j in i..<(i + n) { used[j] = true }
                    break
                }
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func apply(to text: String) -> String {
        var out = text
        // Back to front, so earlier ranges stay valid as we splice.
        for match in matches(in: text).reversed() {
            out.replaceSubrange(match.range, with: match.term)
        }
        return out
    }

    // MARK: - Tokenizing

    struct Token {
        let text: String
        let range: Range<String.Index>
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            // Letters only. Including apostrophes made "post hog's" fail to
            // match (the key picked up a trailing S) and let a closing quote in
            // 'python' be swallowed by the replacement.
            let isWordChar = ch.isASCII && ch.isLetter
            if isWordChar {
                if start == nil { start = i }
            } else if let s = start {
                tokens.append(Token(text: String(text[s..<i]), range: s..<i))
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start {
            tokens.append(Token(text: String(text[s..<text.endIndex]), range: s..<text.endIndex))
        }
        return tokens
    }

    private static func isPartOfLargerToken(_ text: String, _ range: Range<String.Index>) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isNumber || before == "_" { return true }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isNumber || after == "_" { return true }
        }
        return false
    }
}
