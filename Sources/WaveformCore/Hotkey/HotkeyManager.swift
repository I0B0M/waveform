import Carbon.HIToolbox
import AppKit
import IOKit.hid

/// A global hotkey the user can pick in Settings.
///
/// Two mechanisms, chosen per preset:
///
/// 1. Key combos (⌘X, ⌥Space, …): Carbon `RegisterEventHotKey` — needs no
///    permission, costs nothing while idle, and CONSUMES the event so the
///    frontmost app never sees the keystroke (⌘X won't also cut).
///
/// 2. Bare-modifier presets (double-tap ⌃): a listen-only `CGEventTap` on
///    modifier/keyboard/mouse events. Carbon fundamentally cannot register a
///    bare modifier, and `NSEvent` global monitors fail *silently* without
///    Accessibility — a tap fails *loudly* (creation returns nil), which lets
///    the app tell the user exactly what's missing and retry after the grant.
///    Not consuming is fine here: a lone Control press means nothing to apps.
public enum HotkeyPreset: String, CaseIterable, Identifiable {
    case fnTap
    case commandX
    case optionSpace
    case controlOptionD
    case f19
    case controlDoubleTap

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fnTap: return "fn 🌐 (Globe) — press to talk"
        case .commandX: return "⌘X (replaces Cut!)"
        case .optionSpace: return "⌥Space"
        case .controlOptionD: return "⌃⌥D"
        case .f19: return "F19"
        case .controlDoubleTap: return "Double-tap ⌃ (Control)"
        }
    }

    /// Bare-modifier presets watch events instead of registering a Carbon
    /// hotkey; that needs the Accessibility permission (the same one used for
    /// inserting text).
    public var isBareModifier: Bool {
        self == .controlDoubleTap || self == .fnTap
    }

    var keyCode: UInt32 {
        switch self {
        case .commandX: return UInt32(kVK_ANSI_X)
        case .optionSpace: return UInt32(kVK_Space)
        case .controlOptionD: return UInt32(kVK_ANSI_D)
        case .f19: return UInt32(kVK_F19)
        case .controlDoubleTap, .fnTap: return 0
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .commandX: return UInt32(cmdKey)
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionD: return UInt32(controlKey | optionKey)
        case .f19, .controlDoubleTap, .fnTap: return 0
        }
    }
}

/// What a hotkey wants from the coordinator. Key combos and double-tap emit
/// `.toggle`; the fn preset emits raw press gestures the coordinator resolves
/// against actual session state (tap = toggle, hold ≥ threshold = push-to-talk).
enum HotkeyGesture {
    case toggle
    case pressBegan
    case pressEnded(heldFor: TimeInterval)
    case pressCancelled
}

@MainActor
final class HotkeyManager {
    var onGesture: ((HotkeyGesture) -> Void)?

    // Carbon path.
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // Event-tap path (runs on its own thread — see ModifierTapController).
    private var tapController: ModifierTapController?

    /// True when a bare-modifier preset is selected but its tap isn't running
    /// (permission missing) — the condition the retry loop watches.
    var tapControllerMissing: Bool {
        AppSettings.shared.hotkeyPreset.isBareModifier && tapController == nil
    }

    enum HotkeyError: Error, LocalizedError {
        case registrationFailed(OSStatus)
        case accessibilityRequired

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let status):
                return "Hotkey registration failed (\(status))."
            case .accessibilityRequired:
                return "Detecting a bare modifier key needs Input Monitoring (or Accessibility). "
                    + "If it was working and stopped after an update, toggle Waveform OFF and back ON "
                    + "in System Settings → Privacy & Security → Input Monitoring."
            }
        }
    }

    func register(preset: HotkeyPreset) throws {
        unregister()

        if preset.isBareModifier {
            // Creating the tap can SUCCEED without Input Monitoring (the mask
            // includes permission-free mouse events) while macOS silently
            // withholds every keyboard event — a hotkey that looks registered
            // and never fires. Ask for the grant explicitly, up front: this
            // is also what puts Waveform's row into the Input Monitoring list
            // at all after a TCC reset.
            let listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            if listenAccess != kIOHIDAccessTypeGranted {
                Log.hotkey.notice("Input Monitoring not granted (\(listenAccess.rawValue, privacy: .public)) — requesting")
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }

            // The gesture closure is @Sendable but always dispatched onto the
            // main queue by the controller, so hopping back onto the main
            // actor here is safe.
            let controller = ModifierTapController(
                watching: preset == .fnTap ? .maskSecondaryFn : .maskControl,
                trigger: preset == .fnTap ? .press : .doubleTap
            ) { [weak self] gesture in
                // Already on the main queue (the controller dispatches there);
                // deliver synchronously — a Task per gesture has no FIFO
                // guarantee, and an up processed before its own down would
                // scramble the press state machine.
                MainActor.assumeIsolated {
                    switch gesture {
                    case .toggle: self?.onGesture?(.toggle)
                    case .pressBegan: self?.onGesture?(.pressBegan)
                    case .pressEnded(let held): self?.onGesture?(.pressEnded(heldFor: held))
                    case .pressCancelled: self?.onGesture?(.pressCancelled)
                    }
                }
            }
            try controller.start()
            tapController = controller
            // Tap creation ≠ keyboard delivery: log the grant state so a
            // "running" tap that receives nothing is self-diagnosing.
            let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            Log.hotkey.notice("event tap running for preset \(preset.rawValue, privacy: .public) (input monitoring granted: \(granted, privacy: .public))")
            return
        }
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x44534354), id: 1) // 'DSCT'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            preset.keyCode,
            preset.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw HotkeyError.registrationFailed(status)
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        tapController?.stop()
        tapController = nil
    }

    // MARK: - Carbon path

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onGesture?(.toggle)
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }

}
