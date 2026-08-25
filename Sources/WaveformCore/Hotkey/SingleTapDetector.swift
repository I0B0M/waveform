import Foundation

/// Pure state machine for the fn/Globe hotkey gesture, extracted like
/// `DoubleTapDetector` so it can be unit-tested with injected timestamps.
///
/// It recognizes *presses*, not intents — how a press maps onto dictation
/// (start / stop / cancel) is the coordinator's decision, because only the
/// coordinator knows whether a session is actually running:
///
///   - `.pressBegan` — fn went down alone. (Recording starts here, so
///     push-to-talk captures speech from the first instant of the hold.)
///   - `.pressEnded(heldFor:)` — fn came back up and nothing else happened
///     in between. The duration lets the coordinator tell a tap (toggle)
///     from a hold (push-to-talk).
///   - `.pressCancelled` — something else happened while fn was down
///     (fn+arrow, fn+delete, fn+click): the press was a keyboard chord,
///     not a dictation gesture. Emitted once, at the moment of contamination.
struct SingleTapDetector {
    enum Input {
        case modifierDown        // the watched modifier went down, alone
        case modifierUp          // the watched modifier was released
        case contamination       // any other key/click/scroll/modifier
    }

    enum Event: Equatable {
        case none
        case pressBegan
        case pressEnded(heldFor: TimeInterval)
        case pressCancelled
    }

    private var isDown = false
    private var holdContaminated = false
    private var downAt: TimeInterval = 0

    /// Feed one event with its timestamp; returns what the press did.
    mutating func process(_ input: Input, at time: TimeInterval) -> Event {
        switch input {
        case .modifierDown:
            isDown = true
            holdContaminated = false
            downAt = time
            return .pressBegan

        case .contamination:
            guard isDown, !holdContaminated else { return .none }
            holdContaminated = true
            return .pressCancelled

        case .modifierUp:
            guard isDown else { return .none }
            isDown = false
            guard !holdContaminated else { return .none }
            return .pressEnded(heldFor: time - downAt)
        }
    }
}
