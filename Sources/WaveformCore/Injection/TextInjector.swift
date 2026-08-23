import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text at the caret of whatever app is frontmost.
///
/// Strategy 1: write `kAXSelectedTextAttribute` on the focused AX element and
/// verify the caret actually moved (many apps return success and do nothing).
/// The clipboard is untouched on this path.
///
/// Strategy 2: pasteboard + synthetic ⌘V. The previous pasteboard contents are
/// snapshotted and restored afterwards — but only if the change count still
/// matches what we wrote, so a copy the user makes in the meantime is never
/// clobbered (a race Murmur has).
///
/// Both need the Accessibility permission. Without it, the text is left on the
/// clipboard and the caller shows "press ⌘V" guidance.
@MainActor
final class TextInjector {
    enum Outcome {
        case insertedDirectly       // AX write, clipboard untouched
        case pasted                 // ⌘V path, clipboard restored after
        case typed                  // per-character synthesis, clipboard untouched
        case copiedOnly             // no permission — text left on clipboard
    }

    /// How the text reaches the focused app once Accessibility is granted.
    /// `.typeDirectly` exists because macOS 26 has been seen dropping
    /// modifier-bearing synthesized events (like ⌘V) from ad-hoc-signed
    /// binaries — unicode typing uses bare key events and dodges that gate.
    enum Method: String, CaseIterable, Identifiable {
        case auto          // AX insert, verified; fall back to ⌘V paste
        case pasteOnly     // always ⌘V paste
        case typeDirectly  // AX insert, verified; fall back to unicode typing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto (insert, else type)"
            case .pasteOnly: return "Paste (⌘V)"
            case .typeDirectly: return "Type characters directly"
            }
        }
    }

    static func isTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func inject(_ text: String, method: Method = .auto) async -> Outcome {
        guard !text.isEmpty else { return .insertedDirectly }

        guard Self.isTrusted(promptIfNeeded: false) else {
            putOnPasteboard(text, transient: false)
            return .copiedOnly
        }

        // Auto prefers unicode typing over ⌘V as the fallback: macOS 26.5's
        // WindowServer has been seen dropping modifier-bearing synthesized
        // events (⌘V) from ad-hoc-signed binaries, while bare typing events
        // pass. Paste remains available as an explicit setting.
        let outcome: Outcome
        switch method {
        case .auto:
            if injectViaAccessibility(text) {
                outcome = .insertedDirectly
            } else {
                injectViaTyping(text)
                outcome = .typed
            }
        case .pasteOnly:
            await injectViaPasteboard(text)
            outcome = .pasted
        case .typeDirectly:
            if injectViaAccessibility(text) {
                outcome = .insertedDirectly
            } else {
                injectViaTyping(text)
                outcome = .typed
            }
        }
        NSLog("Waveform: injected %d chars via %@ (method: %@)", text.count, String(describing: outcome), method.rawValue)
        return outcome
    }

    /// The selected text in the focused element of the frontmost app, when
    /// readable (native apps). Used for selection command mode.
    func readSelectedText() -> String? {
        guard Self.isTrusted(promptIfNeeded: false) else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - AX path

    private func injectViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return false }
        let focused = focusedRef as! AXUIElement

        // Snapshot the selection range so the write can be verified.
        let rangeBefore = selectedRange(of: focused)

        let status = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard status == .success else { return false }

        // Verify: after a real insert the selection range moves (caret lands
        // after the inserted text). If nothing changed, the app lied.
        let rangeAfter = selectedRange(of: focused)
        guard let after = rangeAfter else { return false }
        if let before = rangeBefore, before.location == after.location, before.length == after.length {
            return false
        }
        return true
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Pasteboard path

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func injectViaPasteboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        putOnPasteboard(text, transient: true)
        let ourChangeCount = pasteboard.changeCount

        // Give the pasteboard server a beat before the target app reads it.
        try? await Task.sleep(nanoseconds: 40_000_000)
        postCommandV()

        // Restore off the critical path — the caller (and the HUD) shouldn't
        // wait 600ms for clipboard etiquette. Only restore if nobody else
        // wrote to the pasteboard in the meantime.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, pasteboard.changeCount == ourChangeCount else { return }
            self.restorePasteboard(pasteboard, from: snapshot)
        }
    }

    private func putOnPasteboard(_ text: String, transient: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if transient {
            // Tell clipboard managers not to record this entry.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) {
                    data[type] = value
                }
            }
            return data
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Direct typing path

    /// Synthesizes bare key events carrying unicode payloads — no modifiers,
    /// no clipboard. ~20 UTF-16 units per event is the practical batch limit.
    private func injectViaTyping(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            index += 20
        }
    }

    private func postCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
