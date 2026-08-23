import Testing
@testable import DiscotypeCore

@Suite("DoubleTapDetector")
struct DoubleTapDetectorTests {
    @Test("clean double tap fires")
    func cleanDoubleTap() {
        var d = DoubleTapDetector()
        let r1 = d.process(.modifierDown, at: 0.00)
        let r2 = d.process(.modifierUp, at: 0.10)
        let r3 = d.process(.modifierDown, at: 0.25)
        let r4 = d.process(.modifierUp, at: 0.35)
        #expect(!r1 && !r2 && !r3)
        #expect(r4)
    }

    @Test("slow second tap does not fire")
    func slowSecondTap() {
        var d = DoubleTapDetector()
        _ = d.process(.modifierDown, at: 0.0)
        _ = d.process(.modifierUp, at: 0.1)
        _ = d.process(.modifierDown, at: 1.0)
        let fired = d.process(.modifierUp, at: 1.1)
        #expect(!fired)
    }

    @Test("holding the modifier never fires")
    func holdDoesNotFire() {
        var d = DoubleTapDetector()
        let down = d.process(.modifierDown, at: 0.0)
        let up = d.process(.modifierUp, at: 2.0) // held two seconds
        #expect(!down && !up)
    }

    @Test("ctrl+key shortcut does not count as a tap")
    func shortcutIsContaminated() {
        var d = DoubleTapDetector()
        _ = d.process(.modifierDown, at: 0.0)
        _ = d.process(.contamination, at: 0.05) // the C of ⌃C
        _ = d.process(.modifierUp, at: 0.10)
        _ = d.process(.modifierDown, at: 0.20)
        let fired = d.process(.modifierUp, at: 0.30)
        #expect(!fired, "tap after a contaminated hold must not fire")
    }

    @Test("two ctrl+key shortcuts in a row do not fire")
    func twoShortcuts() {
        var d = DoubleTapDetector()
        var fired = false
        for t in [0.0, 0.3] {
            _ = d.process(.modifierDown, at: t)
            _ = d.process(.contamination, at: t + 0.02)
            fired = fired || d.process(.modifierUp, at: t + 0.05)
        }
        #expect(!fired)
    }

    @Test("typing between taps cancels the pending tap")
    func typingBetweenTaps() {
        var d = DoubleTapDetector()
        _ = d.process(.modifierDown, at: 0.0)
        _ = d.process(.modifierUp, at: 0.1)
        _ = d.process(.contamination, at: 0.15) // typed a key
        _ = d.process(.modifierDown, at: 0.2)
        let fired = d.process(.modifierUp, at: 0.3)
        #expect(!fired)
    }

    @Test("third clean tap after a too-slow pair still works")
    func recovery() {
        var d = DoubleTapDetector()
        _ = d.process(.modifierDown, at: 0.0)
        _ = d.process(.modifierUp, at: 0.1)      // tap 1
        _ = d.process(.modifierDown, at: 2.0)
        _ = d.process(.modifierUp, at: 2.1)      // tap 2 — too late, becomes new tap 1
        _ = d.process(.modifierDown, at: 2.3)
        let fired = d.process(.modifierUp, at: 2.4) // pairs with tap 2
        #expect(fired)
    }

    @Test("triple tap fires exactly once")
    func tripleTap() {
        var d = DoubleTapDetector()
        var fired = 0
        for t in [0.0, 0.2, 0.4] {
            _ = d.process(.modifierDown, at: t)
            if d.process(.modifierUp, at: t + 0.05) { fired += 1 }
        }
        #expect(fired == 1)
    }
}
