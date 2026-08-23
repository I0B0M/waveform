import Carbon.HIToolbox
import AppKit

/// A global hotkey the user can pick in Settings.
///
/// Carbon `RegisterEventHotKey` is used deliberately instead of a CGEventTap or
/// NSEvent global monitor: it needs no Accessibility/Input Monitoring permission,
/// costs nothing while idle (no tap callback on every keystroke), and it CONSUMES
/// the event — the frontmost app never sees the keystroke, so ⌘X won't also cut.
/// The trade-off of ⌘X specifically: while Discotype runs, ⌘X no longer performs
/// Cut anywhere. That is the user's explicit choice; alternatives are offered.
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

    /// Bare-modifier presets can't use Carbon hotkeys; they watch modifier
    /// events instead, which needs the Accessibility permission (already
    /// required for text insertion) and never swallows anything — a lone
    /// Control press has no meaning to other apps anyway.
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

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // Double-tap-Control state.
    private var monitors: [Any] = []
    private var controlIsDown = false
    private var holdWasContaminated = false
    private var lastCleanTapAt: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.45

    enum HotkeyError: Error {
        case registrationFailed(OSStatus)
    }

    func register(preset: HotkeyPreset) throws {
        unregister()

        if preset.isBareModifier {
            startControlDoubleTapMonitor()
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
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        controlIsDown = false
        lastCleanTapAt = 0
    }

    // MARK: - Double-tap Control

    /// Two clean Control taps (down → up with nothing else pressed) within
    /// 0.45s. A tap is discarded when any key, mouse button, or additional
    /// modifier is used while Control is held — so ⌃-clicks (right-click) and
    /// ⌃-shortcuts never trigger dictation. Global NSEvent monitors observe
    /// only (they can't swallow events), which is fine: a lone Control press
    /// means nothing to other apps. They silently receive nothing until the
    /// Accessibility permission is granted.
    private func startControlDoubleTapMonitor() {
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        let contaminate: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.controlIsDown else { return }
            self.holdWasContaminated = true
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(monitor)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
        let contaminating: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: contaminating, handler: contaminate) {
            monitors.append(monitor)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: contaminating) { event in
            contaminate(event)
            return event
        } as Any)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !controlIsDown, flags == .control {
            // Clean start: Control went down with no other modifier active.
            controlIsDown = true
            holdWasContaminated = false
        } else if controlIsDown, flags.contains(.control), flags != .control {
            // A second modifier joined (⌃⌥ etc.) — not a bare tap.
            holdWasContaminated = true
        } else if controlIsDown, !flags.contains(.control) {
            controlIsDown = false
            let now = ProcessInfo.processInfo.systemUptime
            guard !holdWasContaminated else {
                lastCleanTapAt = 0
                return
            }
            if now - lastCleanTapAt <= doubleTapWindow {
                lastCleanTapAt = 0
                onHotkey?()
            } else {
                lastCleanTapAt = now
            }
        }
    }

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
}
