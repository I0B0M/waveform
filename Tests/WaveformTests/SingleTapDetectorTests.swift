import Testing
@testable import WaveformCore

@Suite("SingleTapDetector")
struct SingleTapDetectorTests {
    private func run(_ inputs: [SingleTapDetector.Input]) -> [Bool] {
        var detector = SingleTapDetector()
        return inputs.map { detector.process($0) }
    }

    @Test("a clean tap fires on release")
    func cleanTap() {
        #expect(run([.modifierDown, .modifierUp]) == [false, true])
    }

    @Test("every clean tap fires — press to start, press to stop")
    func repeatedTaps() {
        let fired = run([
            .modifierDown, .modifierUp,
            .modifierDown, .modifierUp,
            .modifierDown, .modifierUp,
        ])
        #expect(fired == [false, true, false, true, false, true])
    }

    @Test("using fn as a modifier never fires")
    func contaminatedHold() {
        // fn+arrow, fn+delete, fn+click: contamination lands mid-hold.
        #expect(run([.modifierDown, .contamination, .modifierUp]) == [false, false, false])
    }

    @Test("a contaminated hold doesn't poison the next tap")
    func recoversAfterContamination() {
        let fired = run([
            .modifierDown, .contamination, .modifierUp,
            .modifierDown, .modifierUp,
        ])
        #expect(fired == [false, false, false, false, true])
    }

    @Test("an up without a down is ignored")
    func strayUp() {
        #expect(run([.modifierUp]) == [false])
    }

    @Test("contamination while idle is ignored")
    func idleContamination() {
        #expect(run([.contamination, .modifierDown, .modifierUp]) == [false, false, true])
    }
}
