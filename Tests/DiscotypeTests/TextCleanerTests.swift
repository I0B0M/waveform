import Testing
@testable import DiscotypeCore

@Suite("TextCleaner")
struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test("the canonical example from the spec")
    func canonicalExample() {
        let input = "um okay so basically I wanted to explain that we should probably move this to next week"
        #expect(
            cleaner.clean(input)
                == "Okay so basically I wanted to explain that we should probably move this to next week."
        )
    }

    @Test("fillers with model punctuation")
    func fillersWithPunctuation() {
        let input = "Um, okay. So, uh, we should ship it."
        #expect(cleaner.clean(input) == "Okay. So, we should ship it.")
    }

    @Test("fillers are not cut out of real words")
    func fillerSafety() {
        let input = "The umbrella and the error were ahead."
        #expect(cleaner.clean(input) == "The umbrella and the error were ahead.")
    }

    @Test("repeated words collapse")
    func repeatedWords() {
        let input = "we should should move the the meeting"
        #expect(cleaner.clean(input) == "We should move the meeting.")
    }

    @Test("terminal punctuation is added once")
    func terminalPunctuation() {
        #expect(cleaner.clean("ship it") == "Ship it.")
        #expect(cleaner.clean("ship it!") == "Ship it!")
        #expect(cleaner.clean("really?") == "Really?")
    }

    @Test("trailing filler leaves no dangling comma")
    func trailingFiller() {
        #expect(cleaner.clean("move it to next week, um") == "Move it to next week.")
    }

    @Test("sentence starts are recapitalized after a filler cut")
    func sentenceCapitalization() {
        let input = "yes. um so it works. uh great"
        #expect(cleaner.clean(input) == "Yes. So it works. Great.")
    }

    @Test("filler removal can be disabled")
    func fillersOff() {
        let cleaner = TextCleaner(removeFillers: false)
        #expect(cleaner.clean("um okay") == "Um okay.")
    }

    @Test("empty and whitespace input")
    func emptyInput() {
        #expect(cleaner.clean("") == "")
        #expect(cleaner.clean("   \n") == "")
    }

    @Test("content is never rephrased")
    func noRewriting() {
        let input = "I think this is basically fine and we can ship it tomorrow."
        #expect(cleaner.clean(input) == input)
    }
}
