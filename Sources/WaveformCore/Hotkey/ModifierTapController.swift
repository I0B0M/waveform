import AppKit
import Foundation

/// Owns the CGEventTap for bare-modifier hotkeys on a DEDICATED thread.
///
/// The tap must never share the main run loop: when the main thread is busy
/// (finalizing speech, SwiftUI work), a main-loop tap misses its servicing
/// deadline, macOS disables it, and every tap pressed in that window is lost —
/// which presents as "the hotkey works only sometimes". On its own thread the
/// callback is always serviced in microseconds.
///
/// All detection state is confined to the tap thread; only the trigger
/// callback hops to the main queue.
final class ModifierTapController: @unchecked Sendable {
    /// How the watched modifier fires: press gestures (fn — down/up pairs the
    /// coordinator turns into tap-toggle or hold-to-talk) or two clean taps
    /// inside a window (double-tap Control).
    enum Trigger {
        case press
        case doubleTap
    }

    /// What the tap thread observed, delivered on the main queue.
    enum Gesture {
        case toggle                       // double-tap completed
        case pressBegan                   // fn went down alone
        case pressEnded(heldFor: TimeInterval)
        case pressCancelled               // the press became a keyboard chord
    }

    private let onGesture: @Sendable (Gesture) -> Void
    private let watched: CGEventFlags
    private let trigger: Trigger

    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var tap: CFMachPort?

    // Tap-thread-only state.
    private var doubleTapDetector = DoubleTapDetector(window: 0.6)
    private var singleTapDetector = SingleTapDetector()
    private var watchedWasDown = false

    init(
        watching watched: CGEventFlags = .maskControl,
        trigger: Trigger = .doubleTap,
        onGesture: @escaping @Sendable (Gesture) -> Void
    ) {
        self.watched = watched
        self.trigger = trigger
        self.onGesture = onGesture
    }

    /// Creates the tap on the dedicated thread. Throws (synchronously) when
    /// the tap can't be created — i.e. the Accessibility grant is missing.
    func start() throws {
        stop()

        let ready = DispatchSemaphore(value: 0)
        var created = false

        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            self.threadRunLoop = CFRunLoopGetCurrent()
            created = self.createTapOnCurrentThread()
            ready.signal()
            if created {
                CFRunLoopRun()
            }
        }
        thread.name = "waveform.modifier-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        ready.wait()
        guard created else {
            self.thread = nil
            self.threadRunLoop = nil
            throw HotkeyManager.HotkeyError.accessibilityRequired
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = threadRunLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        threadRunLoop = nil
        thread = nil
        doubleTapDetector = DoubleTapDetector(window: 0.6)
        singleTapDetector = SingleTapDetector()
        watchedWasDown = false
    }

    /// One entry point for both detectors, so `handle` stays agnostic of
    /// which trigger style is active. Returns the gesture to deliver, if any.
    private func process(_ input: DoubleTapDetector.Input, at time: TimeInterval) -> Gesture? {
        switch trigger {
        case .doubleTap:
            return doubleTapDetector.process(input, at: time) ? .toggle : nil
        case .press:
            let mapped: SingleTapDetector.Input
            switch input {
            case .modifierDown: mapped = .modifierDown
            case .modifierUp: mapped = .modifierUp
            case .contamination: mapped = .contamination
            }
            switch singleTapDetector.process(mapped, at: time) {
            case .none: return nil
            case .pressBegan: return .pressBegan
            case .pressEnded(let held): return .pressEnded(heldFor: held)
            case .pressCancelled: return .pressCancelled
            }
        }
    }

    // MARK: - Tap thread

    private func createTapOnCurrentThread() -> Bool {
        let interesting: [CGEventType] = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        var mask: CGEventMask = 0
        for type in interesting {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ModifierTapController>.fromOpaque(userInfo).takeUnretainedValue()
                controller.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Secure-input fields or a hiccup paused us; resume immediately.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("Waveform: modifier tap was disabled (%d) — re-enabled", type.rawValue)

        case .flagsChanged:
            let timestamp = Double(event.timestamp) / 1_000_000_000
            let relevant: CGEventFlags = [
                .maskControl, .maskShift, .maskCommand, .maskAlternate, .maskSecondaryFn,
            ]
            let active = event.flags.intersection(relevant)
            let watchedIsDown = active.contains(watched)
            let watchedIsAlone = active == watched

            var gesture: Gesture?
            if watchedIsDown && !watchedWasDown {
                watchedWasDown = true
                gesture = process(watchedIsAlone ? .modifierDown : .contamination, at: timestamp)
            } else if watchedIsDown && watchedWasDown && !watchedIsAlone {
                gesture = process(.contamination, at: timestamp)
            } else if !watchedIsDown && watchedWasDown {
                watchedWasDown = false
                gesture = process(.modifierUp, at: timestamp)
            } else if !watchedIsDown && !active.isEmpty {
                gesture = process(.contamination, at: timestamp)
            }

            if let gesture {
                let onGesture = onGesture
                DispatchQueue.main.async { onGesture(gesture) }
            }

        default:
            let timestamp = Double(event.timestamp) / 1_000_000_000
            if let gesture = process(.contamination, at: timestamp) {
                let onGesture = onGesture
                DispatchQueue.main.async { onGesture(gesture) }
            }
        }
    }
}
