import Testing
@testable import WaveformCore

@Suite("WordDiff")
struct WordDiffTests {
    @Test("a single corrected word is found")
    func singleSubstitution() {
        let old = WordDiff.tokens("Make this prom better for Claude")
        let new = WordDiff.tokens("Make this prompt better for Claude")
        #expect(WordDiff.substitutions(from: old, to: new) == [.init(from: "prom", to: "prompt")])
    }

    @Test("case-only fixes are reported")
    func caseFix() {
        let old = WordDiff.tokens("we should migrate to nestjs next")
        let new = WordDiff.tokens("we should migrate to NestJS next")
        #expect(WordDiff.substitutions(from: old, to: new) == [.init(from: "nestjs", to: "NestJS")])
    }

    @Test("identical text yields nothing")
    func noChange() {
        let tokens = WordDiff.tokens("nothing changed here at all")
        #expect(WordDiff.substitutions(from: tokens, to: tokens).isEmpty)
    }

    @Test("rewriting a clause is not treated as a word correction")
    func clauseRewriteIgnored() {
        let old = WordDiff.tokens("ship the build on Friday")
        let new = WordDiff.tokens("ship the build after the client call next week")
        #expect(WordDiff.substitutions(from: old, to: new).isEmpty)
    }

    @Test("pure insertions and deletions are not substitutions")
    func insertDelete() {
        let base = WordDiff.tokens("send the report")
        #expect(WordDiff.substitutions(from: base, to: WordDiff.tokens("send the final report")).isEmpty)
        #expect(WordDiff.substitutions(from: base, to: WordDiff.tokens("send report")).isEmpty)
    }

    @Test("edit distance")
    func distance() {
        #expect(WordDiff.editDistance("prom", "prompt") == 2)
        #expect(WordDiff.editDistance("nestjs", "NestJS") == 0)
        #expect(WordDiff.editDistance("cat", "elephant") == 6)
    }
}

@Suite("CorrectionLearner rules")
struct CorrectionLearnerRuleTests {
    @Test("a near-miss mishearing is learned")
    func mishearing() {
        #expect(CorrectionLearner.isWorthLearning(from: "prom", to: "prompt"))
        #expect(CorrectionLearner.isWorthLearning(from: "arc angel", to: "Archangel"))
        #expect(CorrectionLearner.isWorthLearning(from: "nestjs", to: "NestJS"))
    }

    @Test("an unrelated word is not vocabulary")
    func unrelatedWord() {
        #expect(!CorrectionLearner.isWorthLearning(from: "Friday", to: "Monday"))
        #expect(!CorrectionLearner.isWorthLearning(from: "cat", to: "elephant"))
    }

    @Test("junk is rejected")
    func junk() {
        #expect(!CorrectionLearner.isWorthLearning(from: "a", to: "b"))
        #expect(!CorrectionLearner.isWorthLearning(from: "2024", to: "2025"))
        #expect(!CorrectionLearner.isWorthLearning(from: "word", to: "!!!"))
    }
}

@Suite("Prompt templates")
struct PromptTemplateTests {
    let triggers = PromptLibrary.defaults.map(\.trigger)

    @Test("spoken template trigger is recognized with its payload")
    func spokenTrigger() {
        let hit = CommandDetector.templateCommand(
            in: "Okay, double slash plan, we need to migrate billing off the legacy service.",
            triggers: triggers
        )
        #expect(hit?.trigger.lowercased() == "plan")
        #expect(hit?.payload == "we need to migrate billing off the legacy service.")
    }

    @Test("symbol form works")
    func symbolTrigger() {
        #expect(CommandDetector.templateCommand(in: "//bug the export button does nothing on Safari", triggers: triggers)?.trigger == "bug")
    }

    @Test("the trigger word alone in a sentence does not fire")
    func noFalsePositive() {
        #expect(CommandDetector.templateCommand(in: "The plan is ready for review.", triggers: triggers) == nil)
        #expect(CommandDetector.templateCommand(in: "I found a bug in the exporter.", triggers: triggers) == nil)
    }

    @Test("unknown trigger is ignored")
    func unknownTrigger() {
        #expect(CommandDetector.templateCommand(in: "double slash sandwich, ham and cheese", triggers: triggers) == nil)
    }

    @Test("defaults are distinct and non-empty")
    func defaultsSane() {
        let triggers = PromptLibrary.defaults.map { $0.trigger.lowercased() }
        #expect(Set(triggers).count == triggers.count)
        #expect(PromptLibrary.defaults.allSatisfy { !$0.instruction.isEmpty && !$0.title.isEmpty })
    }
}
