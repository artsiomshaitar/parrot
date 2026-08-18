import ArgumentParser
import Foundation

/// `parrot vocab` — inspect and test the vocabulary without a microphone.
struct Vocab: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and test the vocabulary.",
        subcommands: [Test.self, Show.self]
    )

    struct Test: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run text through the vocabulary and print the result.",
            discussion: """
            Give text as an argument, or pipe lines on stdin:

                parrot vocab test "let's check the post hawk dashboard"
                pbpaste | parrot vocab test --explain
            """
        )

        @Argument(help: "Text to correct. Reads stdin when omitted.")
        var text: [String] = []

        @Option(name: .long, help: "Vocabulary file. Defaults to ~/.config/parrot/vocab.txt")
        var vocab: String?

        @Flag(name: .long, help: "Show each match and why it fired.")
        var explain: Bool = false

        @Flag(name: .long, help: "Only print lines the vocabulary changed.")
        var changedOnly: Bool = false

        func run() throws {
            let path = vocab ?? Vocabulary.defaultPath
            guard let vocabulary = try Vocabulary.load(path: path, required: vocab != nil) else {
                print("no vocabulary at \(path)")
                throw ExitCode(1)
            }

            let lines: [String]
            if text.isEmpty {
                var stdin: [String] = []
                while let line = readLine(strippingNewline: true) { stdin.append(line) }
                lines = stdin
            } else {
                lines = [text.joined(separator: " ")]
            }

            var changed = 0
            for line in lines where !line.isEmpty {
                let exact = vocabulary.applyReplacements(to: line)
                let final = vocabulary.matcher.apply(to: exact)
                if final != line { changed += 1 }
                if changedOnly, final == line { continue }

                print(final)
                if explain {
                    if exact != line { print("    rule  \(line)  →  \(exact)") }
                    for m in vocabulary.matcher.matches(in: exact) {
                        let key = PhoneticKey.of(phrase: m.heard)
                        let via = m.rule.map { " via rule \"\($0)\"" } ?? ""
                        print(String(
                            format: "    sound %@  →  %@   key %@  similarity %.2f%@",
                            "\"\(m.heard)\"", m.term, key, m.similarity, via
                        ))
                    }
                }
            }

            if lines.count > 1 {
                logLine("\n\(changed)/\(lines.count) line(s) changed")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List loaded terms, rules, and their phonetic keys."
        )

        @Option(name: .long, help: "Vocabulary file. Defaults to ~/.config/parrot/vocab.txt")
        var vocab: String?

        func run() throws {
            let path = vocab ?? Vocabulary.defaultPath
            guard let vocabulary = try Vocabulary.load(path: path, required: vocab != nil) else {
                print("no vocabulary at \(path)")
                throw ExitCode(1)
            }

            print("\(path)\n")
            print("terms (\(vocabulary.terms.count)) — matched by sound")
            for term in vocabulary.terms {
                let keys = PhoneticKey.variants(of: term).sorted().joined(separator: " ")
                let short = PhoneticKey.letters(of: term).count < PhoneticMatcher.minTermLength
                let note = short ? "   (too short for sound matching — use a rule)" : ""
                print("  \(term.padding(toLength: 20, withPad: " ", startingAt: 0)) \(keys)\(note)")
            }

            if !vocabulary.replacements.isEmpty {
                print("\nrules (\(vocabulary.replacements.count)) — matched by sound too, applied first")
                for r in vocabulary.replacements {
                    let arrow = r.fuzzy ? "~>" : "=>"
                    let key = PhoneticKey.of(phrase: r.from)
                    let slack = r.fuzzy ? "  (one sound of slack)" : ""
                    print("  \(r.from.padding(toLength: 16, withPad: " ", startingAt: 0)) \(arrow)  \(r.to.padding(toLength: 14, withPad: " ", startingAt: 0)) \(key)\(slack)")
                }
            }
        }
    }
}
