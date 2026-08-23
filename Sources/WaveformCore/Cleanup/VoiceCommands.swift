import Foundation

/// Spoken formatting commands: "new paragraph", "bullet point", "comma",
/// "delete that".
///
/// Runs BEFORE `TextCleaner`, because the structure it inserts (newlines,
/// bullets) is what the cleaner then has to preserve and capitalize around.
///
/// The trade-off is inherent to dictation and the same one Apple's own
/// dictation makes: saying "the comma is missing" gets you "the, is missing".
/// Words that are too often literal — "dash", "hyphen", "quote" — are
/// deliberately NOT commands, and the whole feature has a settings toggle.
enum VoiceCommands {
    /// Each pattern eats the surrounding spaces it replaces, so a command
    /// never leaves a gap behind ("thought. <break> Second" would otherwise
    /// keep a stray space at the end of the first line).
    ///
    /// `(?<![\w'])` prevents matching inside a longer word ("Periodic",
    /// "Recolonize"), and `[.,!?]?` swallows the punctuation the recognizer
    /// adds after the command itself ("New paragraph." → one break, not a
    /// break plus a dot).
    private static let breakRules: [(pattern: String, replacement: String)] = [
        (#"new\s+paragraph"#, "\n\n"),
        (#"(?:new|next)\s+line"#, "\n"),
        (#"(?:new\s+bullet|bullet\s+point)"#, "\n• "),
    ]

    private static let punctuationRules: [(pattern: String, replacement: String)] = [
        (#"(?:period|full\s+stop)"#, "."),
        (#"comma"#, ","),
        (#"question\s+mark"#, "?"),
        (#"exclamation\s+(?:mark|point)"#, "!"),
        (#"semicolon"#, ";"),
        (#"colon"#, ":"),
        (#"open\s+paren(?:thesis)?"#, " ("),
        (#"close\s+paren(?:thesis)?"#, ")"),
    ]

    private static let deleteThat = #"(?i)[ \t]*(?<![\w'])delete\s+that\b[.,!?]?"#

    static func apply(to text: String) -> String {
        var result = text
        for rule in breakRules {
            // Spaces on BOTH sides: a break supplies its own separation.
            result = replace(
                #"(?i)[ \t]*(?<![\w'])"# + rule.pattern + #"\b[.,!?]?[ \t]*"#,
                with: rule.replacement,
                in: result
            )
        }
        for rule in punctuationRules {
            // Leading space only: punctuation hugs the word before it.
            result = replace(
                #"(?i)[ \t]*(?<![\w'])"# + rule.pattern + #"\b[.,!?]?"#,
                with: rule.replacement,
                in: result
            )
        }
        return applyDeletions(to: result)
    }

    private static func replace(_ pattern: String, with replacement: String, in text: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    /// "delete that" drops the sentence in front of it — the unit people
    /// actually mean when they catch themselves mid-thought.
    private static func applyDeletions(to text: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var result = text

        while let range = result.range(of: deleteThat, options: .regularExpression) {
            let before = result[result.startIndex..<range.lowerBound]
            let after = result[range.upperBound...]

            // Step off the doomed sentence's own terminator first, otherwise
            // the search below finds it and deletes nothing.
            var cursor = before.endIndex
            while cursor > before.startIndex {
                let previous = before.index(before: cursor)
                let character = before[previous]
                guard character.isWhitespace || terminators.contains(character) else { break }
                cursor = previous
            }

            // Now walk back to the end of the sentence BEFORE it.
            let head = before[before.startIndex..<cursor]
            let boundary = head.lastIndex(where: { terminators.contains($0) })
            let kept = boundary.map { String(head[head.startIndex...$0]) } ?? ""

            result = kept + " " + after
        }
        return result
    }
}
