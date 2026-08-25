import Testing
@testable import WaveformCore

@Suite("TranscriptComposer")
struct TranscriptComposerTests {
    @Test("volatile words arrive unsettled, finalized words settled")
    func basicSplit() {
        let words = TranscriptComposer.compose(
            finalized: "okay so", volatile: "basically I", previous: []
        )
        #expect(words.map(\.text) == ["okay", "so", "basically", "I"])
        #expect(words.map(\.settled) == [true, true, false, false])
    }

    @Test("word identity is positional, so growth never reindexes old words")
    func stableIdentity() {
        let first = TranscriptComposer.compose(finalized: "okay so", volatile: "basically", previous: [])
        let second = TranscriptComposer.compose(
            finalized: "okay so basically", volatile: "I wanted", previous: first
        )
        #expect(second[0].id == first[0].id)
        #expect(second[2].id == first[2].id)   // "basically" keeps id 2 as it settles
    }

    @Test("words settling together get consecutive batch indices for the stagger")
    func settleBatch() {
        let first = TranscriptComposer.compose(finalized: "okay so", volatile: "basically I wanted", previous: [])
        let second = TranscriptComposer.compose(
            finalized: "okay so basically I wanted", volatile: "", previous: first
        )
        // "okay so" settled long ago → batch 0; the three new ones cascade.
        #expect(second.map(\.settleBatchIndex) == [0, 0, 0, 1, 2])
        let allSettled = second.allSatisfy { $0.settled }
        #expect(allSettled)
    }

    @Test("an empty transcript composes to no words")
    func empty() {
        #expect(TranscriptComposer.compose(finalized: "", volatile: "", previous: []).isEmpty)
    }

    @Test("whitespace runs never produce empty words")
    func whitespace() {
        let words = TranscriptComposer.compose(finalized: "  okay   so  ", volatile: "\n", previous: [])
        #expect(words.map(\.text) == ["okay", "so"])
    }
}
