import Testing
@testable import WaveformCore

@Suite("VoiceCommands")
struct VoiceCommandsTests {
    @Test("new paragraph and new line become breaks")
    func breaks() {
        #expect(VoiceCommands.apply(to: "First thought. New paragraph. Second thought.")
            == "First thought.\n\nSecond thought.")
        #expect(VoiceCommands.apply(to: "Line one new line line two")
            == "Line one\nline two")
    }

    @Test("bullet points")
    func bullets() {
        let result = VoiceCommands.apply(to: "Agenda. Bullet point ship the build. Bullet point tell the client.")
        #expect(result.contains("\n• ship the build"))
        #expect(result.contains("\n• tell the client"))
    }

    @Test("spoken punctuation")
    func punctuation() {
        #expect(VoiceCommands.apply(to: "Hello comma how are you question mark")
            == "Hello, how are you?")
        #expect(VoiceCommands.apply(to: "Wait exclamation point") == "Wait!")
        #expect(VoiceCommands.apply(to: "Note colon read this") == "Note: read this")
    }

    @Test("commands are not matched inside words")
    func wordSafety() {
        #expect(VoiceCommands.apply(to: "The comment period was extended.")
            == "The comment. was extended.", "standalone 'period' is a command by design")
        // These must survive untouched — the command word is inside a longer word.
        #expect(VoiceCommands.apply(to: "Periodic reviews and commas.") == "Periodic reviews and commas.")
        #expect(VoiceCommands.apply(to: "Recolonize the newline handling.") == "Recolonize the newline handling.")
    }

    @Test("literal-prone words are deliberately not commands")
    func notCommands() {
        #expect(VoiceCommands.apply(to: "git rebase dash i") == "git rebase dash i")
        #expect(VoiceCommands.apply(to: "add a hyphen there") == "add a hyphen there")
        #expect(VoiceCommands.apply(to: "he said quote it works") == "he said quote it works")
    }

    @Test("delete that drops the previous sentence")
    func deleteThat() {
        let result = VoiceCommands.apply(to: "Ship it Friday. Actually the client is away. Delete that. Ship it Monday.")
        #expect(!result.contains("client is away"))
        #expect(result.contains("Ship it Friday."))
        #expect(result.contains("Ship it Monday."))
    }

    @Test("delete that at the start clears everything before it")
    func deleteThatFirst() {
        let result = VoiceCommands.apply(to: "wrong opening delete that the real message")
        #expect(result.trimmingCharacters(in: .whitespaces) == "the real message")
    }

    @Test("no commands leaves text untouched")
    func passthrough() {
        let text = "Okay so basically we should move this to next week."
        #expect(VoiceCommands.apply(to: text) == text)
    }
}

@Suite("TextCleaner with structure")
struct CleanerStructureTests {
    @Test("line breaks survive cleaning and start new sentences")
    func newlinesPreserved() {
        let spoken = VoiceCommands.apply(to: "um first point. New paragraph. second point")
        let cleaned = TextCleaner().clean(spoken)
        #expect(cleaned == "First point.\n\nSecond point.")
    }

    @Test("bullet lists come out formatted")
    func bulletList() {
        let spoken = VoiceCommands.apply(to: "Plan colon bullet point ship it bullet point tell the team")
        let cleaned = TextCleaner().clean(spoken)
        #expect(cleaned == "Plan:\n• Ship it\n• Tell the team.")
    }
}
