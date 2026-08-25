import Testing
@testable import WaveformCore

@Suite("SingleTapDetector")
struct SingleTapDetectorTests {
    typealias Event = SingleTapDetector.Event

    private func run(_ inputs: [(SingleTapDetector.Input, Double)]) -> [Event] {
        var detector = SingleTapDetector()
        return inputs.map { detector.process($0.0, at: $0.1) }
    }

    @Test("a press reports its beginning and its held duration")
    func cleanPress() {
        let events = run([(.modifierDown, 10.0), (.modifierUp, 10.25)])
        #expect(events == [.pressBegan, .pressEnded(heldFor: 0.25)])
    }

    @Test("a long hold reports the full duration — push-to-talk's raw material")
    func longHold() {
        let events = run([(.modifierDown, 4.0), (.modifierUp, 7.5)])
        #expect(events == [.pressBegan, .pressEnded(heldFor: 3.5)])
    }

    @Test("repeated presses each report cleanly")
    func repeatedPresses() {
        let events = run([
            (.modifierDown, 1.0), (.modifierUp, 1.5),
            (.modifierDown, 2.0), (.modifierUp, 2.5),
        ])
        #expect(events == [
            .pressBegan, .pressEnded(heldFor: 0.5),
            .pressBegan, .pressEnded(heldFor: 0.5),
        ])
    }

    @Test("using fn as a modifier cancels the press, once, at the chord")
    func contaminatedHold() {
        // fn+arrow: the press began, then a key landed mid-hold.
        let events = run([
            (.modifierDown, 1.0),
            (.contamination, 1.2),
            (.contamination, 1.3),   // key repeat must not re-cancel
            (.modifierUp, 1.5),
        ])
        #expect(events == [.pressBegan, .pressCancelled, .none, .none])
    }

    @Test("a contaminated press doesn't poison the next one")
    func recoversAfterContamination() {
        let events = run([
            (.modifierDown, 1.0), (.contamination, 1.1), (.modifierUp, 1.2),
            (.modifierDown, 2.0), (.modifierUp, 2.5),
        ])
        #expect(events == [
            .pressBegan, .pressCancelled, .none,
            .pressBegan, .pressEnded(heldFor: 0.5),
        ])
    }

    @Test("an up without a down is ignored")
    func strayUp() {
        #expect(run([(.modifierUp, 1.0)]) == [.none])
    }

    @Test("contamination while idle is ignored")
    func idleContamination() {
        let events = run([(.contamination, 0.5), (.modifierDown, 1.0), (.modifierUp, 1.25)])
        #expect(events == [.none, .pressBegan, .pressEnded(heldFor: 0.25)])
    }
}
