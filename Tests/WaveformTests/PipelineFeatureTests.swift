import Testing
@testable import WaveformCore

@Suite("SelfCorrection")
struct SelfCorrectionTests {
    @Test("clear correction markers are detected")
    func markers() {
        #expect(SelfCorrection.hasMarkers("Meet at 5, no wait, 6pm."))
        #expect(SelfCorrection.hasMarkers("Send it to Sam, scratch that, to Alex."))
        #expect(SelfCorrection.hasMarkers("Tuesday. Sorry, I meant Wednesday."))
        #expect(SelfCorrection.hasMarkers("Ship it Friday, actually no, Monday."))
    }

    @Test("normal speech does not trigger")
    func nonMarkers() {
        #expect(!SelfCorrection.hasMarkers("Actually this went really well."))
        #expect(!SelfCorrection.hasMarkers("I mean it when I say thanks."))
        #expect(!SelfCorrection.hasMarkers("Wait for the deploy to finish, then merge."))
        #expect(!SelfCorrection.hasMarkers("There is no waiting list."))
    }
}

@Suite("SnippetMatcher")
struct SnippetMatcherTests {
    let snippets = [
        Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/book"),
        Snippet(trigger: "office address", expansion: "12 Harbor Street, Suite 400"),
    ]

    @Test("exact trigger matches, punctuation ignored")
    func exact() {
        #expect(SnippetMatcher.expansion(for: "My calendar link.", in: snippets) == "https://cal.example.com/book")
    }

    @Test("insert prefix matches")
    func insertPrefix() {
        #expect(SnippetMatcher.expansion(for: "Insert office address", in: snippets) == "12 Harbor Street, Suite 400")
    }

    @Test("embedded mention does not match")
    func embedded() {
        #expect(SnippetMatcher.expansion(for: "Send them my calendar link tomorrow", in: snippets) == nil)
    }
}

@Suite("TextCleaner styles")
struct CleanStyleTests {
    @Test("chat style skips the trailing period")
    func chat() {
        let cleaner = TextCleaner(removeFillers: true, style: .chat)
        #expect(cleaner.clean("um sounds good see you then") == "Sounds good see you then")
    }

    @Test("code style leaves casing and punctuation alone")
    func code() {
        let cleaner = TextCleaner(removeFillers: true, style: .code)
        #expect(cleaner.clean("git rebase dash i head tilde three") == "git rebase dash i head tilde three")
    }

    @Test("standard style unchanged")
    func standard() {
        let cleaner = TextCleaner(removeFillers: true, style: .standard)
        #expect(cleaner.clean("ship it") == "Ship it.")
    }
}

@Suite("RecognitionHints")
struct RecognitionHintsTests {
    @MainActor
    @Test("template triggers become spoken-marker hints")
    func triggerHints() {
        let hints = AppSettings.composeRecognitionHints(
            commandHints: ["slash better"],
            templateTriggers: ["jira", " ", "standup"],
            learned: [],
            dictionary: []
        )
        #expect(hints.contains("slash jira"))
        #expect(hints.contains("double slash jira"))
        #expect(hints.contains("slash standup"))
        #expect(!hints.contains("slash  "))
    }

    @MainActor
    @Test("a huge dictionary can never evict command or trigger hints")
    func evictionOrder() {
        let bigDictionary = (0..<300).map { "term\($0)" }
        let hints = AppSettings.composeRecognitionHints(
            commandHints: ["double slash prompt"],
            templateTriggers: ["plan"],
            learned: ["NestJS"],
            dictionary: bigDictionary
        )
        #expect(hints.count == 140)
        #expect(hints.contains("double slash prompt"))
        #expect(hints.contains("slash plan"))
        #expect(hints.contains("NestJS"))
        #expect(hints.first == "double slash prompt")
    }
}
