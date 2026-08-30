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

    @Test("a natural lead-in before the command still fires")
    func leadInBeforeCommand() {
        // Exactly how it came out in live testing.
        let spoken = "Okay, double slash prompt. Let's see how, I need an agent that reviews my PRs."
        let command = CommandDetector.detect(in: spoken)
        #expect(command?.kind == .createPrompt)
        #expect(command?.wasExplicit == true)
        #expect(command?.payload.contains("agent that reviews") == true)
        #expect(command?.payload.hasPrefix("Let's see") == false, "lead-in must not leak into the payload")
    }

    @Test("request phrasing is detected")
    func requestPhrasing() {
        #expect(CommandDetector.detect(in: "I need you to create a prompt to review my pull requests.")?.kind == .createPrompt)
        #expect(CommandDetector.detect(in: "So I want you to make this message better, we should move the deadline.")?.kind == .improve)
        #expect(CommandDetector.detect(in: "Okay so make this professional, hey can you send the files.")?.kind == .improve)
    }

    @Test("a meaningful sentence opener survives in the payload")
    func payloadOpenerPreserved() {
        let command = CommandDetector.detect(in: "Double slash better. Now that we shipped, we should tell the client.")
        #expect(command?.payload == "Now that we shipped, we should tell the client.")
    }

    @Test("misheard 'prompt' spellings still fire")
    func mishearings() {
        // What the recognizer actually produced in live testing.
        #expect(CommandDetector.detect(in: "Double slash prom. Make this message better for Claude.")?.kind == .createPrompt)
        #expect(CommandDetector.detect(in: "double slash promt, I need an agent that reviews PRs")?.kind == .createPrompt)
        #expect(CommandDetector.detect(in: "Double-slash prompt, build me a summarizer.")?.kind == .createPrompt)
    }

    @Test("command restated mid-transcript uses the last occurrence")
    func lastOccurrenceWins() {
        let spoken = "The double slash prompt isn't working. Let's start again. Double slash prompt, I need an agent that reviews my pull requests."
        let command = CommandDetector.detect(in: spoken)
        #expect(command?.kind == .createPrompt)
        #expect(command?.payload == "I need an agent that reviews my pull requests.")
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

@Suite("FinishCommand")
struct FinishCommandTests {
    @Test("send it as its own sentence fires and is stripped")
    func sendOwnSentence() {
        let result = FinishCommand.strip(from: "We should ship this today. Send it.")
        #expect(result.command == .send)
        #expect(result.text == "We should ship this today.")
    }

    @Test("please send it mid-flow is content, not a command")
    func sendMidSentence() {
        let result = FinishCommand.strip(from: "When you get a chance please send it")
        #expect(result.command == nil)
        #expect(result.text == "When you get a chance please send it")
    }

    @Test("a comma is NOT a boundary — 'when you're done, send it' is content")
    func commaIsContent() {
        let result = FinishCommand.strip(from: "When you're done, send it")
        #expect(result.command == nil)
        #expect(result.text == "When you're done, send it")
    }

    @Test("scratch that discards, in all its variants")
    func scratch() {
        for phrase in ["Scratch that.", "never mind", "Actually. Cancel that!"] {
            let result = FinishCommand.strip(from: "Some words here. " + phrase)
            #expect(result.command == .scratch, "failed for \(phrase)")
        }
    }

    @Test("the command alone is a valid utterance")
    func loneCommand() {
        #expect(FinishCommand.strip(from: "Scratch that.").command == .scratch)
        #expect(FinishCommand.strip(from: "send it").command == .send)
    }

    @Test("nothing trailing means nothing stripped")
    func plainText() {
        let result = FinishCommand.strip(from: "Just a normal message about sending things.")
        #expect(result.command == nil)
    }
}
