import Foundation

/// Pure state machine for "double-tap a bare modifier" detection, extracted
/// so it can be unit-tested with injected timestamps.
///
/// A *clean tap* is: modifier down → modifier up, with nothing else happening
/// in between (no key, no click, no scroll, no second modifier). Two clean
/// taps whose key-UP events land within `window` seconds fire the hotkey.
///
/// Consequences of the rules:
///   - Holding Control does nothing (no up-up pair inside the window).
///   - ⌃C / ⌃-click / ⌃-scroll never fire (the hold is contaminated).
///   - Typing between two taps cancels the pending first tap.
struct DoubleTapDetector {
    enum Input {
        case modifierDown        // the watched modifier went down, alone
        case modifierUp          // the watched modifier was released
        case contamination       // any other key/click/scroll/modifier
    }

    var window: TimeInterval

    init(window: TimeInterval = 0.45) {
        self.window = window
    }

    private var isDown = false
    private var holdContaminated = false
    private var lastCleanTapAt: TimeInterval = -.greatestFiniteMagnitude

    /// Feed one event; returns true when a double tap completed.
    mutating func process(_ input: Input, at time: TimeInterval) -> Bool {
        switch input {
        case .modifierDown:
            isDown = true
            holdContaminated = false
            return false

        case .contamination:
            if isDown {
                holdContaminated = true
            } else {
                // Activity between taps: the pending first tap is stale.
                lastCleanTapAt = -.greatestFiniteMagnitude
            }
            return false

        case .modifierUp:
            guard isDown else { return false }
            isDown = false
            guard !holdContaminated else {
                lastCleanTapAt = -.greatestFiniteMagnitude
                return false
            }
            if time - lastCleanTapAt <= window {
                lastCleanTapAt = -.greatestFiniteMagnitude
                return true
            }
            lastCleanTapAt = time
            return false
        }
    }
}
