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
    private let onTrigger: @Sendable () -> Void

    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var tap: CFMachPort?

    // Tap-thread-only state.
    private var detector = DoubleTapDetector(window: 0.6)
    private var controlWasDown = false

    init(onTrigger: @escaping @Sendable () -> Void) {
        self.onTrigger = onTrigger
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
        thread.name = "discotype.modifier-tap"
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
        detector = DoubleTapDetector(window: 0.6)
        controlWasDown = false
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
            NSLog("Discotype: modifier tap was disabled (%d) — re-enabled", type.rawValue)

        case .flagsChanged:
            let timestamp = Double(event.timestamp) / 1_000_000_000
            let relevant: CGEventFlags = [
                .maskControl, .maskShift, .maskCommand, .maskAlternate, .maskSecondaryFn,
            ]
            let active = event.flags.intersection(relevant)
            let controlIsDown = active.contains(.maskControl)
            let controlIsAlone = active == .maskControl

            var triggered = false
            if controlIsDown && !controlWasDown {
                controlWasDown = true
                triggered = detector.process(controlIsAlone ? .modifierDown : .contamination, at: timestamp)
            } else if controlIsDown && controlWasDown && !controlIsAlone {
                triggered = detector.process(.contamination, at: timestamp)
            } else if !controlIsDown && controlWasDown {
                controlWasDown = false
                triggered = detector.process(.modifierUp, at: timestamp)
            } else if !controlIsDown && !active.isEmpty {
                triggered = detector.process(.contamination, at: timestamp)
            }

            if triggered {
                let onTrigger = onTrigger
                DispatchQueue.main.async { onTrigger() }
            }

        default:
            let timestamp = Double(event.timestamp) / 1_000_000_000
            _ = detector.process(.contamination, at: timestamp)
        }
    }
}
