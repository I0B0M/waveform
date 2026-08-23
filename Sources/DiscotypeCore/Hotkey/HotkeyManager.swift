import Carbon.HIToolbox
import AppKit

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
    case commandX
    case optionSpace
    case controlOptionD
    case f19
    case controlDoubleTap

    public var id: String { rawValue }

    public var label: String {
        switch self {
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
        self == .controlDoubleTap
    }

    var keyCode: UInt32 {
        switch self {
        case .commandX: return UInt32(kVK_ANSI_X)
        case .optionSpace: return UInt32(kVK_Space)
        case .controlOptionD: return UInt32(kVK_ANSI_D)
        case .f19: return UInt32(kVK_F19)
        case .controlDoubleTap: return 0
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .commandX: return UInt32(cmdKey)
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionD: return UInt32(controlKey | optionKey)
        case .f19, .controlDoubleTap: return 0
        }
    }
}

@MainActor
final class HotkeyManager {
    var onHotkey: (() -> Void)?

    // Carbon path.
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // Event-tap path.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector = DoubleTapDetector()
    private var controlWasDown = false

    enum HotkeyError: Error, LocalizedError {
        case registrationFailed(OSStatus)
        case accessibilityRequired

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let status):
                return "Hotkey registration failed (\(status))."
            case .accessibilityRequired:
                return "Detecting a bare modifier key needs the Accessibility permission."
            }
        }
    }

    func register(preset: HotkeyPreset) throws {
        unregister()

        if preset.isBareModifier {
            try startEventTap()
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
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        detector = DoubleTapDetector()
        controlWasDown = false
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
                    manager.onHotkey?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }

    // MARK: - Event-tap path (double-tap Control)

    private func startEventTap() throws {
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
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                // Extract primitives before hopping threads; CGEvents must not
                // be retained past the callback.
                let flags = event.flags
                let seconds = Double(event.timestamp) / 1_000_000_000
                DispatchQueue.main.async {
                    manager.handleTapEvent(type: type, flags: flags, timestamp: seconds)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            throw HotkeyError.accessibilityRequired
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func handleTapEvent(type: CGEventType, flags: CGEventFlags, timestamp: TimeInterval) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system paused us (slow callback or secure input); resume.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return

        case .flagsChanged:
            let relevant: CGEventFlags = [
                .maskControl, .maskShift, .maskCommand, .maskAlternate, .maskSecondaryFn,
            ]
            let active = flags.intersection(relevant)
            let controlIsDown = active.contains(.maskControl)
            let controlIsAlone = active == .maskControl

            if controlIsDown && !controlWasDown {
                controlWasDown = true
                fire(detector.process(controlIsAlone ? .modifierDown : .contamination, at: timestamp))
            } else if controlIsDown && controlWasDown && !controlIsAlone {
                // A second modifier joined mid-hold (⌃⌥ etc.).
                fire(detector.process(.contamination, at: timestamp))
            } else if !controlIsDown && controlWasDown {
                controlWasDown = false
                fire(detector.process(.modifierUp, at: timestamp))
            } else if !controlIsDown && !active.isEmpty {
                // Some other lone modifier tapped between our taps.
                fire(detector.process(.contamination, at: timestamp))
            }

        default:
            // Keys, clicks, scrolls — contaminate holds and pending taps.
            fire(detector.process(.contamination, at: timestamp))
        }
    }

    private func fire(_ triggered: Bool) {
        if triggered {
            onHotkey?()
        }
    }
}
