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
    /// Per-app output style. `.chat` skips the trailing period (message-thread
    /// convention); `.code` skips sentence capitalization AND terminal
    /// punctuation (identifiers and commands must arrive untouched).
    enum CleanStyle {
        case standard
        case chat
        case code
    }

    var removeFillers: Bool = true
    var style: CleanStyle = .standard

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
        if style != .code {
            text = Self.capitalizeSentences(in: text)
        }
        if style == .standard {
            text = Self.ensureTerminalPunctuation(in: text)
        }
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
        // Horizontal whitespace only — collapsing \\s+ would eat the line
        // breaks that voice commands just inserted.
        var result = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
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
            } else if char == "." || char == "!" || char == "?" || char == "\n" {
                capitalizeNext = true
            }
        }
        return String(characters)
    }

    /// Fit freshly dictated text onto an existing caret position: when the
    /// caret sits mid-sentence, the recognizer's automatic leading capital is
    /// wrong ("send it to Him Today" pasted after "I will ") — lowercase it,
    /// and add the joining space the user can't speak. Words that are capital
    /// in any position ("I", "I'm", proper nouns the recognizer chose to
    /// capitalize mid-utterance) survive: only a capital that exists purely
    /// because it started the utterance is folded.
    static func fitContinuation(_ text: String, after before: String, following: String = "") -> String {
        guard let lastVisible = before.reversed().first(where: { !$0.isWhitespace }) else {
            return text   // empty field: nothing to continue
        }
        var result = text
        // A line break between the caret and the last visible character means
        // a fresh line — "Hi Sarah,\n|" starts a new paragraph even though the
        // previous line ended with a comma. Capitals survive there.
        let onFreshLine = before.reversed()
            .prefix(while: { $0.isWhitespace })
            .contains(where: \.isNewline)
        let midSentence = !onFreshLine && !".!?…".contains(lastVisible)
        if midSentence, let first = result.first, first.isUppercase {
            let firstWord = result.prefix(while: { !$0.isWhitespace && !$0.isPunctuation })
            let keepCapital = firstWord == "I"
                || firstWord.dropFirst().contains(where: \.isUppercase)
                || (result.count > firstWord.count
                    && result[result.index(result.startIndex, offsetBy: firstWord.count)] == "'"
                    && firstWord == "I")
            if !keepCapital {
                result = first.lowercased() + result.dropFirst()
            }
        }
        // Join with a space unless the caret already follows whitespace or an
        // opener, or the dictation begins with closing punctuation.
        let needsSpace = !(before.last?.isWhitespace ?? true)
            && !"([{\u{201C}\u{2018}\"'/-".contains(before.last!)
            && !(result.first.map { ",.;:!?)".contains($0) } ?? false)
        if needsSpace {
            result = " " + result
        }

        // Text continuing on the SAME line after the caret: the auto-appended
        // period would land mid-sentence ("…ship the build. tomorrow"). Strip
        // it, and make sure a separating space exists.
        if let firstAfter = following.first, !firstAfter.isNewline {
            let afterContinues = following.drop(while: { $0 == " " }).first?.isLowercase ?? false
            if afterContinues, result.hasSuffix(".") {
                result = String(result.dropLast())
            }
            if !firstAfter.isWhitespace, let lastResult = result.last, !lastResult.isWhitespace {
                result += " "
            }
        }
        return result
    }

    static func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last else { return text }
        // Don't punctuate a deliberate line break or an empty bullet.
        if last == "\n" || last == "•" || last == " " { return text }
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
