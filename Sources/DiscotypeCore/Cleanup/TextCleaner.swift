import Foundation

/// Conservative cleanup of a raw transcript. The model (SpeechTranscriber)
/// already produces punctuation and capitalization; this pass only:
///   1. removes standalone filler words (um, uh, …) and the punctuation gap
///      they leave behind,
///   2. collapses immediately repeated words ("the the" → "the"),
///   3. normalizes whitespace and space-before-punctuation,
///   4. re-capitalizes sentence starts (needed after a leading filler is cut),
///   5. ensures the text ends with terminal punctuation.
///
/// It deliberately never reorders, rephrases, or drops content words.
struct TextCleaner {
    var removeFillers: Bool = true

    /// Standalone-token fillers only. Words like "like" or "so" are meaningful
    /// too often to strip safely.
    static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "mhm", "mm",
    ]

    func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if removeFillers {
            text = Self.stripFillers(from: text)
        }
        text = Self.collapseRepeatedWords(in: text)
        text = Self.normalizeWhitespace(in: text)
        text = Self.capitalizeSentences(in: text)
        text = Self.ensureTerminalPunctuation(in: text)
        return text
    }

    // MARK: - Passes

    static func stripFillers(from text: String) -> String {
        // Match a filler as a whole word, optionally followed by a comma —
        // "Um, okay" → "okay". (?<![\w']) avoids matching inside words like
        // "umbrella" or "duh".
        let alternatives = fillerWords.joined(separator: "|")
        let pattern = "(?i)(?<![\\w'])(?:\(alternatives))\\b[,.]?\\s*"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    static func collapseRepeatedWords(in text: String) -> String {
        // "the the" / "The the" → first occurrence kept. Only exact
        // (case-insensitive) immediate repeats; "had had" is sacrificed for
        // simplicity, real dictation repeats are far more common.
        let pattern = "(?i)\\b([\\w']+)(\\s+\\1)+\\b"
        return text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
    }

    static func normalizeWhitespace(in text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // No space before closing punctuation.
        result = result.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        // Collapse doubled punctuation a filler cut can leave ("okay,, so").
        result = result.replacingOccurrences(of: "([,.;:!?])(?:\\s*\\1)+", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func capitalizeSentences(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var characters = Array(text)
        var capitalizeNext = true
        for index in characters.indices {
            let char = characters[index]
            if capitalizeNext, char.isLetter {
                characters[index] = Character(char.uppercased())
                capitalizeNext = false
            } else if char == "." || char == "!" || char == "?" {
                capitalizeNext = true
            }
        }
        return String(characters)
    }

    static func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last else { return text }
        if last.isLetter || last.isNumber {
            return text + "."
        }
        // A dangling comma from a trailing filler ("next week, um") becomes a period.
        if last == "," || last == ";" || last == ":" {
            return String(text.dropLast()) + "."
        }
        return text
    }
}
