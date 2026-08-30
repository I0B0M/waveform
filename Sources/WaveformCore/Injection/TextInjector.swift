import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text at the FINAL cursor — wherever the caret is when dictation
/// stops. Moving between apps and tabs while dictating is normal; the last
/// focus wins. Every dictation is ALSO placed on the clipboard first, so ⌘V
/// is always the manual recovery when a target refuses insertion.
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
        case copiedNoField          // nothing focused accepts text — copied
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
        /// Wall-clock time: systemUptime pauses during sleep, which would
        /// keep the undo window alive across a closed lid overnight.
        let at: Date
    }

    private var lastInsertion: LastInsertion?
    private static let undoWindow: TimeInterval = 15

    /// Two AX timeout budgets, learned the hard way. A single 0.3s budget
    /// (added to stop hung apps freezing the UI through the caret-dot poll)
    /// made INSERTION fail intermittently: busy Electron apps routinely take
    /// longer than 300ms to answer the focused-element query, the read came
    /// back empty, and the app concluded "no text field" while the user sat
    /// in one — the definition of wonky. So:
    ///   - `systemWide` (2s): insertion-critical reads. The user is already
    ///     waiting for their text; patience here is correctness.
    ///   - `systemWideFast` (0.25s): the caret-dot poll only — it fires every
    ///     400ms and must never be able to stall the main actor.
    private let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 2.0)
        return element
    }()

    private let systemWideFast: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    /// The focused AX element at dictation start — the anchor the text
    /// belongs to. AX writes don't require the app to be frontmost, so an
    /// anchored insert lands at the original caret even while the user reads
    /// something else; a dead anchor (tab closed, message sent) just errors
    /// and the insert falls back to the focus-based path.
    func captureFocusedElement() -> AXUIElement? {
        captureFocusedElementDetailed().element
    }

    /// The AXError matters: `.success`/nil-value means genuinely nothing is
    /// focused (typing would hit app shortcuts — refuse); a timeout or error
    /// means the app was too busy to ANSWER, which is not evidence of
    /// anything (type; the field is probably right there).
    ///
    /// Resolution order matters even more: Electron/Chromium apps keep their
    /// accessibility tree DISABLED until an assistive client wakes it — the
    /// system-wide focus query then returns nothing (or just the window)
    /// while the user sits in a perfectly good text field. So: wake the
    /// frontmost app's tree (AXManualAccessibility, the documented Electron
    /// switch; harmless where unsupported), ask that app directly, and only
    /// then fall back to the system-wide query.
    private func captureFocusedElementDetailed() -> (element: AXUIElement?, error: AXError) {
        guard Self.isTrusted(promptIfNeeded: false) else { return (nil, .apiDisabled) }

        var lastError: AXError = .noValue
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 2.0)
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue
            )
            for attempt in 0..<2 {
                var focusedRef: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(
                    appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
                )
                if status == .success, let focusedRef {
                    let element = focusedRef as! AXUIElement
                    AXUIElementSetMessagingTimeout(element, 2.0)
                    // A window is not a text target; Chromium reports it while
                    // the tree is still waking. Retry once, then let the
                    // system-wide path have a look.
                    if Self.role(of: element) == (kAXWindowRole as String), attempt == 0 {
                        usleep(200_000)
                        continue
                    }
                    return (element, .success)
                }
                lastError = status
                // Freshly woken trees need a beat to build.
                usleep(200_000)
            }
        }

        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard status == .success, let focusedRef else {
            return (nil, status == .success ? lastError : status)
        }
        return ((focusedRef as! AXUIElement), .success)
    }

    private static func role(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
        else { return nil }
        return roleRef as? String
    }

    /// Guards a background write from the two audit-identified disasters:
    /// replacing a selection the user made AFTER dictation started
    /// (kAXSelectedTextAttribute means "replace selection" — collapse it to
    /// its end first), and a stale/reused token pointing at the wrong element
    /// (when the field's value is readable and we know what preceded the
    /// caret, the value must still contain it).
    private func anchoredWriteIsSafe(to element: AXUIElement, expectedSuffix: String) -> Bool {
        // Identity check, when we have the material for it.
        if !expectedSuffix.isEmpty {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? String, value.utf16.count < 200_000 {
                let probe = String(expectedSuffix.suffix(80))
                if !probe.isEmpty, !value.contains(probe) {
                    Log.injection.notice("anchor identity check failed — element content changed")
                    return false
                }
            }
        }
        // Never replace a live selection in a window the user may not be
        // looking at: collapse it to its end so the write only inserts.
        if let range = selectedRange(of: element), range.length > 0 {
            var caret = CFRange(location: range.location + range.length, length: 0)
            guard let caretValue = AXValueCreate(.cfRange, &caret),
                  AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, caretValue
                  ) == .success else { return false }
        }
        return true
    }

    /// The clipboard safety net, callable by paths that bypass inject()
    /// (the streaming finisher).
    func copyToClipboard(_ text: String) {
        putOnPasteboard(text)
    }

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
    func inject(
        _ text: String,
        method: Method = .auto,
        targetBundleId: String? = nil,
        anchor: AXUIElement? = nil,
        expectedBeforeSuffix: String = ""
    ) async -> Outcome {
        guard !text.isEmpty else { return .insertedDirectly }

        guard Self.isTrusted(promptIfNeeded: false) else {
            Log.injection.error("BLOCKED — Accessibility not granted; text is on the clipboard")
            putOnPasteboard(text)
            return .copiedOnly
        }

        // THE SAFETY NET, unconditionally and first: every dictation goes to
        // the clipboard, so whatever any target does or refuses to do, ⌘V
        // always recovers the words. This is deliberate — no snapshotting, no
        // restoring: the dictation IS the clipboard content the user wants.
        putOnPasteboard(text)

        // Dictating from Waveform's own dashboard is the one case where the
        // final focus is wrong by construction — hand focus back to the app
        // the dictation started from.
        let selfId = Bundle.main.bundleIdentifier
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == selfId,
           let targetBundleId, targetBundleId != selfId {
            _ = await refront(bundleId: targetBundleId)
        }

        // FINAL CURSOR FIRST: the user moves between tabs and apps while
        // dictating on purpose; wherever the caret is at stop time is where
        // the text belongs. The element captured at START is the fallback —
        // an AX write reaches it without its app being frontmost, so when the
        // final focus can't take text (a bare Safari page), the words land
        // back at the original caret instead of being lost.
        if method != .pasteOnly {
            var candidates: [(element: AXUIElement, isStartAnchor: Bool)] = []
            if let current = captureFocusedElement() {
                candidates.append((current, false))
            }
            if let anchor {
                candidates.append((anchor, true))
            }
            for candidate in candidates {
                // The start anchor gets the strict guards: it may be stale
                // (identity check) and its window may hold a selection the
                // user made later (collapse, never replace, out of sight).
                // The CURRENT focus gets neither — replacing a selection the
                // user is looking at right now is what they asked for.
                if candidate.isStartAnchor {
                    guard anchoredWriteIsSafe(to: candidate.element, expectedSuffix: expectedBeforeSuffix) else { continue }
                }
                if injectViaAccessibility(text, into: candidate.element) {
                    Log.injection.notice("injected \(text.count, privacy: .public) chars via AX (\(candidate.isStartAnchor ? "start anchor" : "final cursor", privacy: .public))")
                    lastInsertion = LastInsertion(
                        text: text,
                        bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        at: Date()
                    )
                    return .insertedDirectly
                }
            }
        }

        // Synthesized events are silently discarded while a secure input
        // field (password box) holds the keyboard — never fake success there.
        if method != .pasteOnly, IsSecureEventInputEnabled() {
            Log.injection.error("secure event input active — text is on the clipboard")
            return .copiedSecureInput
        }

        // Never type into the void: when nothing focused can take text,
        // synthesized keystrokes become app shortcuts (space scrolls Safari)
        // and the words are gone without an error. The clipboard already has
        // them — say so instead.
        if method != .pasteOnly, !focusAcceptsText() {
            Log.injection.error("no text-accepting element focused — text is on the clipboard")
            return .copiedNoField
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
                outcome = .copiedOnly   // clipboard already holds the text
            }
        case .pasteOnly:
            await injectViaPasteboard(text)
            outcome = .pasted
        }
        Log.injection.notice("injected \(text.count, privacy: .public) chars via \(String(describing: outcome), privacy: .public) (method: \(method.rawValue, privacy: .public))")
        lastInsertion = LastInsertion(
            text: text,
            bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            at: Date()
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
              Date().timeIntervalSince(last.at) <= Self.undoWindow else {
            return .nothingToUndo
        }
        guard Self.isTrusted(promptIfNeeded: false),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.bundleId else {
            return .fieldChanged
        }

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

    /// Read what surrounds the caret — on-device context awareness. Secure
    /// fields are detected FIRST and never read: the returned context then
    /// carries only the flag. Bounded reads (400 before / 120 after) — enough
    /// for tone and continuation, never the document.
    func readFieldContext() -> FieldContext {
        var context = FieldContext(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            windowTitle: nil
        )
        guard Self.isTrusted(promptIfNeeded: false) else { return context }

        // Fail closed on BOTH secure signals before reading anything: the AX
        // subrole, and the system-wide secure-input flag (a password field
        // holding the keyboard raises it even when the app's AX tree lies).
        if IsSecureEventInputEnabled() {
            context.isSecure = true
            return context
        }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return context }
        let focused = focusedRef as! AXUIElement

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            context.isSecure = true
            return context
        }

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &windowRef) == .success,
           let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                context.windowTitle = String(title.prefix(120))
            }
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              !value.isEmpty, value.utf16.count < 200_000,
              let range = selectedRange(of: focused) else { return context }

        let caret = min(max(0, range.location), value.utf16.count)
        let utf16 = value.utf16
        if let caretIndex = utf16.index(utf16.startIndex, offsetBy: caret, limitedBy: utf16.endIndex)?
            .samePosition(in: value) {
            context.before = String(value[..<caretIndex].suffix(400))
            // Skip past the selection (doomed text) — in UTF-16 units, which
            // is what the AX range counts in.
            let selectionEnd = min(caret + max(range.length, 0), value.utf16.count)
            let afterStart = utf16.index(utf16.startIndex, offsetBy: selectionEnd, limitedBy: utf16.endIndex)?
                .samePosition(in: value) ?? caretIndex
            context.after = String(value[afterStart...].prefix(120))
        }
        return context
    }

    /// Screen rectangle of the caret in the focused element, in Cocoa
    /// (bottom-left-origin) coordinates — for the caret-side recording dot.
    /// nil whenever the focused app doesn't expose it; callers must not guess.
    func caretScreenRect() -> CGRect? {
        guard Self.isTrusted(promptIfNeeded: false) else { return nil }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideFast,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.25)

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
        guard let focused = captureFocusedElement() else { return false }
        return injectViaAccessibility(text, into: focused)
    }

    /// Three-valued typing gate (audit A.5): refuse to type only on POSITIVE
    /// evidence that the focused thing takes no text — a readable role that
    /// is clearly not editable, with no text traits. AX-opaque targets
    /// (remote desktops, VMs, games) expose nothing readable yet accept
    /// keystrokes perfectly; absence of evidence must not become a refusal.
    private func focusAcceptsText() -> Bool {
        let read = captureFocusedElementDetailed()
        guard let focused = read.element else {
            if read.error == .noValue || read.error == .success {
                // Nothing focused at all is positive evidence: keystrokes
                // would land on whatever the frontmost app does with bare keys.
                return false
            }
            // The app couldn't be ASKED (timeout, busy) — absence of an
            // answer is not evidence of absence; type.
            Log.injection.notice("focus unreadable (\(read.error.rawValue, privacy: .public)) — typing anyway")
            return true
        }
        if selectedRange(of: focused) != nil { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // No text traits — decide by role, and only when the role is readable.
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else {
            return true   // opaque target (VM, remote desktop): type, honestly logged
        }
        let textRoles: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String,
            kAXComboBoxRole as String, "AXSearchField", "AXTerminal",
            // A FOCUSED web area is Electron/browser shorthand for "the caret
            // is in web content" (contenteditable composers report this way);
            // refusing here turned every Electron dictation into a clipboard
            // pill. A window with focus, by contrast, really is no-field.
            "AXWebArea",
        ]
        if textRoles.contains(role) { return true }
        Log.injection.notice("focused role \(role, privacy: .public) has no text traits — refusing to type")
        return false
    }

    private func injectViaAccessibility(_ text: String, into focused: AXUIElement) -> Bool {
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

        private func injectViaPasteboard(_ text: String) async {
        // The dictation is already on the clipboard (the universal safety
        // net) — just give the pasteboard server a beat, then paste. No
        // restore: the clipboard copy is deliberate.
        try? await Task.sleep(nanoseconds: 40_000_000)
        postCommandV()
    }

    private func putOnPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
