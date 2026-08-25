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
        case copiedFocusLost        // target app wouldn't come back — copied
        case copiedSecureInput      // secure input field — typing is discarded
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

    /// What the last successful insertion put where, for undo. Never
    /// persisted; expires quickly because the field keeps changing without us.
    private struct LastInsertion {
        let text: String
        let bundleId: String?
        let at: TimeInterval
    }

    private var lastInsertion: LastInsertion?
    private static let undoWindow: TimeInterval = 15

    static func isTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// `targetBundleId` is the app that was frontmost when dictation STARTED —
    /// the one whose cursor the user was speaking at. If something else has
    /// grabbed focus since (an alert, a stray click, a notification), the text
    /// would land in the wrong window or nowhere; re-front the target first,
    /// and if that fails leave the text on the clipboard rather than type it
    /// into the wrong app.
    func inject(_ text: String, method: Method = .auto, targetBundleId: String? = nil) async -> Outcome {
        guard !text.isEmpty else { return .insertedDirectly }

        guard Self.isTrusted(promptIfNeeded: false) else {
            Log.injection.error("BLOCKED — Accessibility not granted; text left on clipboard")
            putOnPasteboard(text, transient: false)
            return .copiedOnly
        }

        if let targetBundleId,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != targetBundleId {
            guard await refront(bundleId: targetBundleId) else {
                // NOT a permissions problem — say so, or the user concludes
                // their Accessibility grant "didn't work".
                Log.injection.error("target \(targetBundleId, privacy: .public) would not re-front — text left on clipboard")
                putOnPasteboard(text, transient: false)
                return .copiedFocusLost
            }
        }

        // Synthesized events are silently discarded while a secure input
        // field (password box) holds the keyboard — never fake success there.
        if method != .pasteOnly, IsSecureEventInputEnabled() {
            Log.injection.error("secure event input active — text left on clipboard")
            putOnPasteboard(text, transient: false)
            return .copiedSecureInput
        }

        // Auto prefers unicode typing over ⌘V as the fallback: macOS 26.5's
        // WindowServer has been seen dropping modifier-bearing synthesized
        // events (⌘V) from ad-hoc-signed binaries, while bare typing events
        // pass. Paste remains available as an explicit setting.
        let outcome: Outcome
        switch method {
        case .auto, .typeDirectly:
            if injectViaAccessibility(text) {
                outcome = .insertedDirectly
            } else if injectViaTyping(text) {
                outcome = .typed
            } else {
                putOnPasteboard(text, transient: false)
                outcome = .copiedOnly
            }
        case .pasteOnly:
            await injectViaPasteboard(text)
            outcome = .pasted
        }
        Log.injection.notice("injected \(text.count, privacy: .public) chars via \(String(describing: outcome), privacy: .public) (method: \(method.rawValue, privacy: .public))")
        lastInsertion = LastInsertion(
            text: text,
            bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            at: ProcessInfo.processInfo.systemUptime
        )
        return outcome
    }

    enum UndoResult {
        case undone
        case nothingToUndo      // no recent insertion (or it expired)
        case fieldChanged       // the text is no longer sitting where we left it
    }

    /// Take back the last insertion — but never blind-fire deletions. The
    /// undo only proceeds when the focused field is still in the app we
    /// inserted into AND its value still ENDS WITH exactly what we inserted;
    /// then that suffix is selected via AX and replaced with nothing. Any
    /// doubt — different app, edited field, unreadable value — refuses,
    /// because deleting the wrong characters is far worse than not undoing.
    func undoLastInsertion() -> UndoResult {
        guard let last = lastInsertion,
              ProcessInfo.processInfo.systemUptime - last.at <= Self.undoWindow else {
            return .nothingToUndo
        }
        guard Self.isTrusted(promptIfNeeded: false),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.bundleId else {
            return .fieldChanged
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return .fieldChanged }
        let focused = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              // Locate the suffix by STRING INDEX, not by subtracting UTF-16
              // counts: an app that normalized the text (café → cafe+́ ) still
              // matches canonically, but with a different unit count — count
              // arithmetic would select and delete the wrong span.
              let suffixRange = value.range(of: last.text, options: [.anchored, .backwards])
        else { return .fieldChanged }

        let location = value.utf16.distance(from: value.utf16.startIndex, to: suffixRange.lowerBound.samePosition(in: value.utf16) ?? value.utf16.endIndex)
        let length = value.utf16.distance(
            from: suffixRange.lowerBound.samePosition(in: value.utf16) ?? value.utf16.endIndex,
            to: suffixRange.upperBound.samePosition(in: value.utf16) ?? value.utf16.endIndex
        )
        guard length > 0 else { return .fieldChanged }
        let expectedPrefix = String(value[..<suffixRange.lowerBound])

        // Select exactly the inserted suffix, then replace it with nothing.
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                focused, kAXSelectedTextRangeAttribute as CFString, rangeValue
              ) == .success else { return .fieldChanged }
        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, "" as CFString
        ) == .success else {
            // The range was set but the delete refused: collapse the selection
            // back to a caret so the user's next keystroke can't wipe it.
            var caret = CFRange(location: location + length, length: 0)
            if let caretValue = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, caretValue)
            }
            return .fieldChanged
        }

        // Verify EXACTLY: the field must now equal what preceded the suffix.
        // Anything else means the delete landed somewhere unexpected — report
        // failure rather than a false "Undone".
        var afterRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &afterRef) == .success,
              let after = afterRef as? String,
              after == expectedPrefix else { return .fieldChanged }
        lastInsertion = nil
        return .undone
    }

    /// Screen rectangle of the caret in the focused element, in Cocoa
    /// (bottom-left-origin) coordinates — for the caret-side recording dot.
    /// nil whenever the focused app doesn't expose it; callers must not guess.
    func caretScreenRect() -> CGRect? {
        guard Self.isTrusted(promptIfNeeded: false) else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRef,
            &boundsRef
        ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.height < 200 else { return nil }

        // AX reports top-left-origin global coordinates; Cocoa wants
        // bottom-left, flipped against the primary screen.
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.height - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    /// Bring the dictation target back to the front and wait for the switch
    /// to land, plus a beat for the app to restore its first responder (the
    /// field the caret was in). Returns false if it never becomes frontmost.
    private func refront(bundleId: String) async -> Bool {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first else { return false }
        // macOS 14+ cooperative activation denies a plain activate() from a
        // background app unless someone yields to the target — so yield our
        // own claim first, then ask.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleId)
        app.activate()
        for attempt in 0..<10 {
            // Check FIRST: an instant activation shouldn't pay a 100ms toll.
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                // A beat for the app to restore its first responder.
                try? await Task.sleep(nanoseconds: 120_000_000)
                return true
            }
            if attempt == 4 {
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleId)
                app.activate()   // one more nudge
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
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

        // Electron-style apps apply AX writes asynchronously; reading back
        // instantly sees stale state and a REAL insert gets typed a second
        // time. A short settle is cheaper than duplicated text.
        usleep(40_000)

        // Verify pass 1 — the field's value, when readable, is authoritative.
        // Compare through a fold that survives what apps do to inserted text
        // (smart quotes, case fixes, single-line fields flattening newlines):
        // a transformed insert is still a SUCCESSFUL insert.
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String,
           value.count < 200_000 {
            let probe = Self.verifyFold(String(text.prefix(80)))
            if !probe.isEmpty {
                return Self.verifyFold(value).contains(probe)
            }
        }

        // Verify pass 2 (value unreadable): the caret must have moved. Apps
        // that report no range at all, or a frozen range, fail here and fall
        // back to typing — for them the AX write almost never landed anyway.
        guard let after = selectedRange(of: focused) else { return false }
        if let before = rangeBefore, before.location == after.location, before.length == after.length {
            return false
        }
        return true
    }

    /// Case, curly quotes, and whitespace runs — the transforms target apps
    /// apply to freshly inserted text — folded away for verification.
    static func verifyFold(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
    /// no clipboard. Chunks are built on GRAPHEME boundaries (≤20 UTF-16
    /// units each): cutting a surrogate pair in half sends two broken events
    /// and the target renders � instead of the emoji. Posts are paced 2ms
    /// apart — Electron targets drop or reorder unpaced synthetic unicode.
    /// Returns false when the events could not even be created.
    private func injectViaTyping(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.injection.error("typing path unavailable — CGEventSource creation failed")
            return false
        }
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if current.count + units.count > 20, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }

        for chunk in chunks {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            usleep(2_000)
        }
        return true
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
