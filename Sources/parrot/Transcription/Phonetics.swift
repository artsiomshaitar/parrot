import Foundation

/// Metaphone: maps a word to how it sounds, so spellings that sound alike
/// collapse to the same key ("hawk" and "hog" both → HK).
///
/// Plain Metaphone rather than Double Metaphone — validated against the real
/// mishearings this is meant to fix, and the second code earned nothing there
/// for twice the rule set.
enum Metaphone {
    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
    /// Letters that fuse with a following H into one sound, leaving the H silent.
    private static let hFusing: Set<Character> = ["C", "S", "P", "T", "G"]

    static func encode(_ input: String) -> String {
        var s = Array(input.uppercased().filter { $0.isASCII && $0.isLetter })
        guard !s.isEmpty else { return "" }

        // Word-initial clusters where the first letter is silent, plus the two
        // that change outright.
        if s.count >= 2 {
            switch String(s[0...1]) {
            case "AE", "GN", "KN", "PN", "WR":
                s.removeFirst()
            case "WH":
                s.removeFirst()
                s[0] = "W"
            default:
                break
            }
        }
        if s.first == "X" { s[0] = "S" }

        var out = ""
        let n = s.count
        for i in 0..<n {
            let c = s[i]
            // Doubled letters sound once — except CC, which can be two sounds.
            if i > 0, s[i - 1] == c, c != "C" { continue }

            let prev: Character? = i > 0 ? s[i - 1] : nil
            let next: Character? = i + 1 < n ? s[i + 1] : nil
            let after: Character? = i + 2 < n ? s[i + 2] : nil

            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { out.append(c) }

            case "B":
                // Silent in the -MB ending ("thumb"), voiced elsewhere.
                if !(i == n - 1 && prev == "M") { out.append("B") }

            case "C":
                if next == "I", after == "A" {
                    out.append("X")
                } else if next == "H" {
                    out.append(prev == "S" ? "K" : "X")  // school vs church
                } else if let x = next, x == "I" || x == "E" || x == "Y" {
                    if prev != "S" { out.append("S") }   // scene: the C is silent
                } else {
                    out.append("K")
                }

            case "D":
                if next == "G", let x = after, x == "E" || x == "Y" || x == "I" {
                    out.append("J")
                } else {
                    out.append("T")
                }

            case "G":
                if next == "H" {
                    // Silent unless a vowel follows the H ("ghost" vs "night").
                    if let x = after, vowels.contains(x) { out.append("K") }
                } else if next == "N" {
                    break  // gnome, sign
                } else if let x = next, x == "I" || x == "E" || x == "Y", prev != "G" {
                    out.append("J")
                } else {
                    out.append("K")
                }

            case "H":
                if let p = prev, hFusing.contains(p) {
                    break  // already spent on TH/CH/SH/PH/GH
                } else if let p = prev, vowels.contains(p),
                          next == nil || !vowels.contains(next!) {
                    break  // silent after a vowel with no vowel following
                } else {
                    out.append("H")
                }

            case "K":
                if prev != "C" { out.append("K") }

            case "P":
                out.append(next == "H" ? "F" : "P")

            case "Q":
                out.append("K")

            case "S":
                if next == "H" {
                    out.append("X")
                } else if next == "I", let x = after, x == "O" || x == "A" {
                    out.append("X")  // -sion, -sia
                } else {
                    out.append("S")
                }

            case "T":
                if next == "I", let x = after, x == "O" || x == "A" {
                    out.append("X")  // -tion, -tia
                } else if next == "H" {
                    out.append("0")  // theta
                } else if next == "C", after == "H" {
                    break  // -tch-
                } else {
                    out.append("T")
                }

            case "V":
                out.append("F")

            case "W", "Y":
                // Consonantal only before a vowel; otherwise part of the vowel.
                if let x = next, vowels.contains(x) { out.append(c) }

            case "X":
                out.append("KS")

            case "Z":
                out.append("S")

            default:
                out.append(c)
            }
        }
        return out
    }
}

/// Jaro-Winkler similarity, 0…1. Used as the second opinion alongside the
/// phonetic key: sound-alike keys are deliberately lossy, so an orthographic
/// check keeps "dollar" from becoming "Deelr".
enum Similarity {
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s1 = Array(a), s2 = Array(b)
        if s1.isEmpty || s2.isEmpty { return s1.isEmpty && s2.isEmpty ? 1 : 0 }
        if s1 == s2 { return 1 }

        let window = max(max(s1.count, s2.count) / 2 - 1, 0)
        var m1 = [Bool](repeating: false, count: s1.count)
        var m2 = [Bool](repeating: false, count: s2.count)
        var matches = 0

        for i in 0..<s1.count {
            let lo = max(0, i - window)
            let hi = min(i + window + 1, s2.count)
            guard lo < hi else { continue }
            for j in lo..<hi where !m2[j] && s1[i] == s2[j] {
                m1[i] = true
                m2[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var k = 0
        for i in 0..<s1.count where m1[i] {
            while !m2[k] { k += 1 }
            if s1[i] != s2[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        let jaro = (m / Double(s1.count) + m / Double(s2.count)
            + (m - Double(transpositions) / 2) / m) / 3

        // Winkler: reward a shared prefix, up to four characters.
        var prefix = 0
        for i in 0..<min(4, min(s1.count, s2.count)) {
            if s1[i] == s2[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
