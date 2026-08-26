import Testing
@testable import WaveformCore

@Suite("ContextHints")
struct ContextHintsTests {
    @Test("proper nouns, acronyms, and mixed-case jargon are extracted")
    func extraction() {
        let hints = ContextHints.extract(
            from: "hey Sarah, the NestJS branch failed TCC checks on the playground and Aqeeb wants an update"
        )
        #expect(hints.contains("Sarah"))
        #expect(hints.contains("NestJS"))
        #expect(hints.contains("TCC"))
        #expect(hints.contains("Aqeeb"))
    }

    @Test("ordinary words and sentence-initial capitals are not hints")
    func noise() {
        let hints = ContextHints.extract(from: "The meeting was moved to next week and everyone agreed")
        #expect(hints.isEmpty)
    }

    @Test("duplicates collapse and the list is capped")
    func dedupeAndCap() {
        let text = Array(repeating: "Sarah NestJS", count: 30).joined(separator: " ")
        let hints = ContextHints.extract(from: text, limit: 5)
        #expect(hints.count == 2)
        let many = (0..<40).map { "Word\($0)x" }.joined(separator: " ")
        #expect(ContextHints.extract(from: many, limit: 10).count == 10)
    }
}

@Suite("ContinuationFit")
struct ContinuationFitTests {
    @Test("mid-sentence: leading capital folds and a joining space appears")
    func midSentence() {
        let fitted = TextCleaner.fitContinuation("Send it to him today.", after: "I will")
        #expect(fitted == " send it to him today.")
    }

    @Test("after a finished sentence the capital survives")
    func afterSentence() {
        let fitted = TextCleaner.fitContinuation("Send it today.", after: "That's done.")
        #expect(fitted == " Send it today.")
    }

    @Test("an empty field changes nothing")
    func emptyField() {
        #expect(TextCleaner.fitContinuation("Hello there.", after: "") == "Hello there.")
        #expect(TextCleaner.fitContinuation("Hello there.", after: "   ") == "Hello there.")
    }

    @Test("the pronoun I keeps its capital mid-sentence")
    func pronounI() {
        #expect(TextCleaner.fitContinuation("I will handle it.", after: "and then") == " I will handle it.")
        #expect(TextCleaner.fitContinuation("I'm on it.", after: "and then") == " I'm on it.")
    }

    @Test("proper nouns the recognizer capitalized survive")
    func properNoun() {
        // "NestJS" has an inner capital — never folded.
        #expect(TextCleaner.fitContinuation("NestJS is fine.", after: "I think") == " NestJS is fine.")
    }

    @Test("no double space when the caret already follows one")
    func existingSpace() {
        #expect(TextCleaner.fitContinuation("Send it.", after: "I will ") == "send it.")
    }

    @Test("leading punctuation joins without a space")
    func punctuationJoin() {
        #expect(TextCleaner.fitContinuation(", which is fine.", after: "we shipped it") == ", which is fine.")
    }
}

@Suite("ContinuationFit — review regressions")
struct ContinuationFitRegressionTests {
    @Test("a fresh line after a comma is a paragraph start, not mid-sentence")
    func freshLineAfterComma() {
        // "Hi Sarah,\n|" — the single most common email pattern.
        let fitted = TextCleaner.fitContinuation("Thanks for the update.", after: "Hi Sarah,\n\n")
        #expect(fitted == "Thanks for the update.")
    }

    @Test("same-line text after the caret strips the auto period and spaces out")
    func afterTextOnSameLine() {
        let fitted = TextCleaner.fitContinuation(
            "Ship the build.", after: "I think we should", following: " tomorrow"
        )
        #expect(fitted == " ship the build")
        let jammed = TextCleaner.fitContinuation(
            "Ship the build.", after: "I think we should ", following: "tomorrow"
        )
        #expect(jammed == "ship the build ")
    }

    @Test("after-text on a NEW line changes nothing")
    func afterTextOnNewLine() {
        let fitted = TextCleaner.fitContinuation(
            "Ship the build.", after: "I think we should", following: "\nNotes:"
        )
        #expect(fitted == " ship the build.")
    }

    @Test("capitalized after-text (a new sentence follows) keeps the period")
    func afterTextNewSentence() {
        let fitted = TextCleaner.fitContinuation(
            "Ship the build.", after: "I think we should", following: " Also the docs."
        )
        #expect(fitted == " ship the build.")
    }
}
