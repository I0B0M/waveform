import Testing
@testable import WaveformCore

@Suite("CommandDetector")
struct CommandDetectorTests {
    @Test("make this message better")
    func improveCommand() {
        let text = "Make this message better and more structured, so basically we need to move the deadline and I think the client should know first."
        let command = CommandDetector.detect(in: text)
        #expect(command?.kind == .improve)
        #expect(command?.payload.hasPrefix("so basically we need to move") == true)
    }

    @Test("make it professional")
    func professionalCommand() {
        let text = "make it professional. hey can you send me the files by tomorrow thanks"
        let command = CommandDetector.detect(in: text)
        #expect(command?.kind == .improve)
    }

    @Test("create a quick prompt")
    func promptCommand() {
        let text = "Create a quick prompt for me, I want an agent that reviews my pull requests and checks naming conventions."
        let command = CommandDetector.detect(in: text)
        #expect(command?.kind == .createPrompt)
        #expect(command?.payload.hasPrefix("I want an agent") == true)
    }

    @Test("normal dictation passes through")
    func normalText() {
        #expect(CommandDetector.detect(in: "Okay, so basically I wanted to explain that we should move this to next week.") == nil)
        #expect(CommandDetector.detect(in: "The prompt engineering guide is ready for review.") == nil)
        #expect(CommandDetector.detect(in: "I will make this project better over time.") == nil)
    }

    @Test("spoken slash-prompt prefix builds a prompt")
    func spokenPromptPrefix() {
        let command = CommandDetector.detect(in: "Double slash prompt, I want an agent that reviews my pull requests.")
        #expect(command?.kind == .createPrompt)
        #expect(command?.wasExplicit == true)
        #expect(command?.payload == "I want an agent that reviews my pull requests.")
    }

    @Test("single slash and symbol forms also work")
    func prefixVariants() {
        #expect(CommandDetector.detect(in: "Slash prompt, build me a summarizer.")?.kind == .createPrompt)
        #expect(CommandDetector.detect(in: "//prompt build me a summarizer")?.kind == .createPrompt)
        #expect(CommandDetector.detect(in: "Slash slash better, we should ship on Friday.")?.kind == .improve)
        #expect(CommandDetector.detect(in: "Slash organize, notes from the call today.")?.kind == .improve)
    }

    @Test("explicit prefix with no payload targets the selection")
    func prefixNoPayload() {
        let command = CommandDetector.detect(in: "Double slash prompt.")
        #expect(command?.kind == .createPrompt)
        #expect(command?.payload.isEmpty == true)
        #expect(command?.wasExplicit == true)
    }

    @Test("natural language is still detected but not marked explicit")
    func naturalLanguageNotExplicit() {
        let command = CommandDetector.detect(in: "Make this message better, we should move the deadline to next week.")
        #expect(command?.kind == .improve)
        #expect(command?.wasExplicit == false)
    }

    @Test("the word slash mid-sentence is not a command")
    func slashMidSentence() {
        #expect(CommandDetector.detect(in: "The read slash write split is done.") == nil)
        #expect(CommandDetector.detect(in: "Use a forward slash between them.") == nil)
    }

    @Test("selection instructions are recognized")
    func selectionInstructions() {
        #expect(CommandDetector.selectionInstruction(in: "Make this more organized.") != nil)
        #expect(CommandDetector.selectionInstruction(in: "please make this professional") != nil)
        #expect(CommandDetector.selectionInstruction(in: "Turn this into bullet points") != nil)
        #expect(CommandDetector.selectionInstruction(in: "Summarize this in one sentence") != nil)
    }

    @Test("normal speech is not a selection instruction")
    func selectionNonInstructions() {
        #expect(CommandDetector.selectionInstruction(in: "Okay so basically we need to ship this by Friday and tell the client.") == nil)
        #expect(CommandDetector.selectionInstruction(in: "The meeting is at five.") == nil)
        #expect(CommandDetector.selectionInstruction(in: "Made a mistake in the report") == nil)
    }

    @Test("command with no payload is not a command")
    func bareCommand() {
        #expect(CommandDetector.detect(in: "Make this better.") == nil)
        #expect(CommandDetector.detect(in: "Create a prompt.") == nil)
    }
}
