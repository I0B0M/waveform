import Foundation

/// Pure state machine for "tap a bare modifier once" detection (the fn/Globe
/// press-to-talk hotkey), extracted like `DoubleTapDetector` so it can be
/// unit-tested without an event tap.
///
/// A tap fires on modifier UP, but only when the hold was *clean*: nothing
/// else happened between down and up. That is what separates a deliberate tap
/// from fn being used as a modifier:
///   - fn+arrow (page up), fn+backspace (forward delete), fn+click never fire.
///   - Holding fn while pressing any key never fires.
struct SingleTapDetector {
    enum Input {
        case modifierDown        // the watched modifier went down, alone
        case modifierUp          // the watched modifier was released
        case contamination       // any other key/click/scroll/modifier
    }

    private var isDown = false
    private var holdContaminated = false

    /// Feed one event; returns true when a clean tap completed.
    mutating func process(_ input: Input) -> Bool {
        switch input {
        case .modifierDown:
            isDown = true
            holdContaminated = false
            return false

        case .contamination:
            if isDown {
                holdContaminated = true
            }
            return false

        case .modifierUp:
            guard isDown else { return false }
            isDown = false
            return !holdContaminated
        }
    }
}
