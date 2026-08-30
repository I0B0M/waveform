import Testing
@testable import WaveformCore

@Suite("DictationPlanner")
struct DictationPlannerTests {
    private let snippets = [Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/book")]
    private let templates = PromptLibrary.defaults

    private func context(
        _ text: String,
        forced: DictationCommand.Kind? = nil,
        selection: String? = nil,
        aiEnabled: Bool = true,
        modelAvailable: Bool = true
    ) -> DictationContext {
        DictationContext(
            text: text,
            forced: forced,
            selection: selection,
            snippets: snippets,
            templates: templates,
            aiEnabled: aiEnabled,
            modelAvailable: modelAvailable
        )
    }

    // MARK: - The ✨ button

    @Test("the sparkles button outranks everything the words look like")
    func forcedWins() {
        // This text would otherwise match a snippet.
        let plan = DictationPlanner.plan(for: context("my calendar link", forced: .improve))
        #expect(plan == .rewrite(kind: .improve, subject: "my calendar link", fallback: "my calendar link"))
    }

    @Test("sparkles with a selection rewrites the selection")
    func forcedUsesSelection() {
        let plan = DictationPlanner.plan(for: context("tidy this", forced: .improve, selection: "the messy text"))
        #expect(plan == .rewrite(kind: .improve, subject: "the messy text", fallback: "tidy this"))
    }

    @Test("sparkles with the model off inserts the words and explains")
    func forcedWithoutModel() {
        let plan = DictationPlanner.plan(for: context("some words", forced: .createPrompt, modelAvailable: false))
        #expect(plan == .insertWithNotice("some words", notice: "Apple Intelligence is off — inserted as spoken"))
    }

    @Test("an unforced dictation is never rewritten — the armed flag cannot linger")
    func notForcedIsPlainInsert() {
        // The regression: forcedCommand used to survive an empty transcript or
        // a thrown error and rewrite the NEXT dictation. It is now an input to
        // this decision, so absent means absent.
        #expect(DictationPlanner.plan(for: context("just a normal sentence for the record"))
            == .insert("just a normal sentence for the record"))
    }

    // MARK: - Ordering

    @Test("a snippet beats command interpretation")
    func snippetWins() {
        #expect(DictationPlanner.plan(for: context("My calendar link."))
            == .snippet("https://cal.example.com/book"))
    }

    @Test("a user template beats the built-in commands")
    func templateWins() {
        let plan = DictationPlanner.plan(for: context("double slash plan, migrate billing off the legacy service"))
        guard case .template(let id, let input, _) = plan else {
            Issue.record("expected a template plan, got \(plan)")
            return
        }
        #expect(templates.first(where: { $0.id == id })?.trigger == "plan")
        #expect(input == "migrate billing off the legacy service")
    }

    @Test("a template with nothing to act on aborts instead of inserting the command")
    func templateNeedsInput() {
        #expect(DictationPlanner.plan(for: context("double slash plan"))
            == .abort(notice: "Nothing to work on — say the details after the command"))
    }

    @Test("built-in explicit command")
    func builtInCommand() {
        let plan = DictationPlanner.plan(for: context("double slash prompt, an agent that reviews pull requests"))
        #expect(plan == .rewrite(
            kind: .createPrompt,
            subject: "an agent that reviews pull requests",
            fallback: "an agent that reviews pull requests"
        ))
    }

    @Test("command plus selection plus instruction transforms the selection")
    func commandOnSelection() {
        let plan = DictationPlanner.plan(for: context(
            "double slash better, make this shorter",
            selection: "a long rambling paragraph"
        ))
        #expect(plan == .transformSelection(selection: "a long rambling paragraph", instruction: "make this shorter"))
    }

    @Test("a spoken instruction with a selection but no slash still transforms it")
    func bareSelectionInstruction() {
        let plan = DictationPlanner.plan(for: context("make this more organized", selection: "messy notes"))
        #expect(plan == .transformSelection(selection: "messy notes", instruction: "make this more organized"))
    }

    @Test("the same instruction with nothing selected is just text")
    func instructionWithoutSelection() {
        #expect(DictationPlanner.plan(for: context("make this more organized"))
            == .insert("make this more organized"))
    }

    @Test("self-corrections are resolved when nothing more explicit matched")
    func selfCorrections() {
        let text = "Meet at 5, no wait, 6pm."
        #expect(DictationPlanner.plan(for: context(text)) == .resolveCorrections(text))
    }

    // MARK: - Switches off

    @Test("with AI commands off, only snippets still apply")
    func aiDisabled() {
        #expect(DictationPlanner.plan(for: context("double slash prompt, do a thing", aiEnabled: false))
            == .insert("double slash prompt, do a thing"))
        #expect(DictationPlanner.plan(for: context("My calendar link.", aiEnabled: false))
            == .snippet("https://cal.example.com/book"))
    }

    @Test("with no model, ordinary speech inserts silently rather than nagging")
    func noModelPlainSpeech() {
        #expect(DictationPlanner.plan(for: context("Meet at 5, no wait, 6pm.", modelAvailable: false))
            == .insert("Meet at 5, no wait, 6pm."))
    }
}

@Suite("Compose routing")
struct ComposeRoutingTests {
    @Test("reply-type instructions with a selection compose new text")
    func replyComposes() {
        let plan = DictationPlanner.plan(for: DictationContext(
            text: "Respond to it like this, I'll review it tomorrow morning",
            forced: nil,
            selection: "Can you look at the PR today?"
        ))
        guard case .compose(let instruction, let material, _) = plan else {
            Issue.record("expected .compose, got \(plan)")
            return
        }
        #expect(instruction.hasPrefix("Respond to it"))
        #expect(material == "Can you look at the PR today?")
    }

    @Test("edit-type instructions still transform the selection in place")
    func editTransforms() {
        let plan = DictationPlanner.plan(for: DictationContext(
            text: "Make this shorter and friendlier",
            forced: nil,
            selection: "A very long paragraph of text goes here."
        ))
        guard case .transformSelection = plan else {
            Issue.record("expected .transformSelection, got \(plan)")
            return
        }
    }

    @Test("reply verbs without a selection are ordinary speech")
    func replyWithoutSelection() {
        let plan = DictationPlanner.plan(for: DictationContext(
            text: "Reply to Sarah when you get a chance",
            forced: nil,
            selection: nil
        ))
        #expect(plan == .insert("Reply to Sarah when you get a chance"))
    }
}
