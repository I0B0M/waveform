import AppKit
import Carbon.HIToolbox

/// fn/Globe capture via NSEvent monitors instead of a CGEventTap.
///
/// Why this exists: on this machine (macOS 26, built-in keyboard, Globe key
/// set to Do Nothing) a healthy listen-only session event tap — created
/// successfully, Input Monitoring granted — receives ZERO flagsChanged events
/// for fn. Verified with raw logging at the tap callback: the events never
/// arrive. NSEvent global monitors are the other system-wide delivery path;
/// they require the Accessibility permission (which this app already needs to
/// insert text) and demonstrably receive fn on the same machines.
///
/// A global monitor covers presses while OTHER apps are frontmost; a matching
/// local monitor covers presses while Waveform itself is key. Both feed the
/// same pure `SingleTapDetector` used by the tap path, so the tap-vs-hold
/// gesture rules stay identical and tested.
@MainActor
final class FnEventMonitor {
    private let onGesture: (HotkeyGesture) -> Void

    private var monitors: [Any] = []
    private var detector = SingleTapDetector()
    private var fnWasDown = false

    init(onGesture: @escaping (HotkeyGesture) -> Void) {
        self.onGesture = onGesture
    }

    /// Throws when Accessibility is missing: global NSEvent monitors fail
    /// SILENTLY without it, which would look exactly like a dead hotkey.
    func start() throws {
        stop()
        guard TextInjector.isTrusted(promptIfNeeded: false) else {
            throw HotkeyManager.HotkeyError.accessibilityRequired
        }

        let flagsMask: NSEvent.EventTypeMask = [.flagsChanged]
        let contaminationMask: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: flagsMask, handler: { [weak self] event in
            self?.handleFlags(event)
        }) {
            monitors.append(global)
        }
        if let contamination = NSEvent.addGlobalMonitorForEvents(matching: contaminationMask, handler: { [weak self] event in
            self?.handleContamination(event)
        }) {
            monitors.append(contamination)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: flagsMask) { [weak self] event in
            self?.handleFlags(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: contaminationMask) { [weak self] event in
            self?.handleContamination(event)
            return event
        } as Any)

        Log.hotkey.notice("fn NSEvent monitors installed (\(self.monitors.count, privacy: .public))")
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        detector = SingleTapDetector()
        fnWasDown = false
    }

    // MARK: - Event handling (all on the main thread — NSEvent guarantees it)

    private func handleFlags(_ event: NSEvent) {
        let isFnKey = event.keyCode == UInt16(kVK_Function)
        let fnIsDown = event.modifierFlags.contains(.function)
        let others: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let othersActive = !event.modifierFlags.intersection(others).isEmpty

        if isFnKey || fnIsDown || fnWasDown {
            Log.hotkey.notice("raw NSEvent flagsChanged: keyCode=\(event.keyCode, privacy: .public) flags=0x\(String(event.modifierFlags.rawValue, radix: 16), privacy: .public)")
        }

        let time = event.timestamp
        if fnIsDown && !fnWasDown {
            fnWasDown = true
            emit(detector.process(othersActive ? .contamination : .modifierDown, at: time))
        } else if fnIsDown && othersActive {
            // Another modifier joined while fn is held: a chord, not a press.
            emit(detector.process(.contamination, at: time))
        } else if !fnIsDown && fnWasDown {
            fnWasDown = false
            emit(detector.process(.modifierUp, at: time))
        } else if !fnIsDown && othersActive {
            emit(detector.process(.contamination, at: time))
        }
    }

    private func handleContamination(_ event: NSEvent) {
        emit(detector.process(.contamination, at: event.timestamp))
    }

    private func emit(_ event: SingleTapDetector.Event) {
        switch event {
        case .none:
            return
        case .pressBegan:
            Log.hotkey.notice("gesture: pressBegan (NSEvent)")
            onGesture(.pressBegan)
        case .pressEnded(let held):
            Log.hotkey.notice("gesture: pressEnded heldFor \(String(format: "%.2f", held), privacy: .public)s (NSEvent)")
            onGesture(.pressEnded(heldFor: held))
        case .pressCancelled:
            Log.hotkey.notice("gesture: pressCancelled (NSEvent)")
            onGesture(.pressCancelled)
        }
    }
}
