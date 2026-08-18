import Foundation

enum PhoneticKey {
    static func of(words: [String]) -> String {
        words.map(Metaphone.encode).joined()
    }

    static func of(phrase: String) -> String {
        of(words: words(in: phrase))
    }

    /// "PostHog" → [Post, Hog]; "React Native" → [React, Native]; "Node.js" → [Node, js].
    static func words(in term: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in term {
            if character.isWhitespace || character == "." || character == "_" || character == "-" {
                if !current.isEmpty { parts.append(current); current = "" }
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Every key a term can be reached by, spoken whole or in parts.
    static func variants(of term: String) -> Set<String> {
        var keys: Set<String> = []
        let letters = Self.letters(of: term)
        if !letters.isEmpty { keys.insert(Metaphone.encode(letters)) }
        keys.insert(of(phrase: term))
        if let first = letters.first, first == "X" || first == "x" {
            keys.insert(Metaphone.encode("EX" + letters.dropFirst()))
        }
        return keys.filter { !$0.isEmpty }
    }

    static func letters(of text: String) -> String {
        text.filter { $0.isASCII && $0.isLetter }
    }

    static func comparable(_ text: String) -> String {
        letters(of: text).lowercased()
    }
}
