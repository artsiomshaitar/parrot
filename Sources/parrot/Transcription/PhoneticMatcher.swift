import Foundation

/// Rewrites phrases that sound like a vocabulary term into that term.
struct PhoneticMatcher {
    /// Measured: below 0.82 prose breaks, above 0.88 real mishearings are missed.
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
        /// The rule that fired, or nil when a term matched directly.
        let rule: String?
    }

    private struct CompiledRule {
        let from: String
        let to: String
        let key: String
        let flat: String
        let tolerance: Int
    }

    /// key → canonical terms.
    let index: [String: [String]]
    private let rules: [CompiledRule]
    private let wordList: WordList

    init(
        terms: [String],
        rules: [Vocabulary.Replacement] = [],
        wordList: WordList = SystemWordList.shared
    ) {
        var index: [String: [String]] = [:]
        for term in terms where PhoneticKey.letters(of: term).count >= Self.minTermLength {
            for key in PhoneticKey.variants(of: term) {
                index[key, default: []].append(term)
            }
        }
        self.index = index
        self.wordList = wordList
        self.rules = rules
            .map { rule in
                CompiledRule(
                    from: rule.from,
                    to: rule.to,
                    key: PhoneticKey.of(phrase: rule.from),
                    flat: PhoneticKey.comparable(rule.from),
                    tolerance: rule.fuzzy ? 1 : 0
                )
            }
            .sorted { $0.flat.count > $1.flat.count }
    }

    func matches(in text: String) -> [Match] {
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return [] }

        var used = [Bool](repeating: false, count: tokens.count)
        var found: [Match] = []

        for n in stride(from: Self.maxWindow, through: 1, by: -1) {
            guard tokens.count >= n else { continue }
            for i in 0...(tokens.count - n) {
                if used[i..<(i + n)].contains(true) { continue }
                let span = tokens[i..<(i + n)]
                guard let first = span.first, let last = span.last else { continue }
                let range = first.range.lowerBound..<last.range.upperBound

                if text[range].contains(where: { ".!?;:,".contains($0) }) { continue }
                if Self.isPartOfLargerToken(text, range) { continue }

                let words = span.map { $0.text }
                let heard = String(text[range])
                let flat = words.joined().lowercased()
                let key = PhoneticKey.of(words: words)
                guard !key.isEmpty else { continue }

                let isOrdinaryWord = n == 1 && wordList.contains(words[0])
                if let hit = matchRule(
                    key: key, flat: flat, heard: heard,
                    singleOrdinaryWord: isOrdinaryWord
                ) {
                    found.append(hit.match(range: range, heard: heard))
                    for j in i..<(i + n) { used[j] = true }
                    continue
                }

                guard let candidates = index[key] else { continue }
                if isOrdinaryWord { continue }

                for term in candidates where heard != term {
                    let similarity = Similarity.jaroWinkler(flat, PhoneticKey.comparable(term))
                    if similarity < Self.similarityFloor { continue }

                    found.append(Match(
                        range: range, heard: heard, term: term,
                        similarity: similarity, rule: nil
                    ))
                    for j in i..<(i + n) { used[j] = true }
                    break
                }
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private struct RuleHit {
        let to: String
        let from: String
        let similarity: Double
        func match(range: Range<String.Index>, heard: String) -> Match {
            Match(range: range, heard: heard, term: to, similarity: similarity, rule: from)
        }
    }

    private func matchRule(
        key: String, flat: String, heard: String, singleOrdinaryWord: Bool
    ) -> RuleHit? {
        for rule in rules {
            if heard == rule.to { return nil }
            guard Self.editDistance(key, rule.key) <= rule.tolerance else { continue }
            if singleOrdinaryWord, flat != rule.flat { continue }
            let similarity = Similarity.jaroWinkler(flat, rule.flat)
            guard similarity >= Self.similarityFloor else { continue }
            return RuleHit(to: rule.to, from: rule.from, similarity: similarity)
        }
        return nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    func apply(to text: String) -> String {
        var out = text
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
