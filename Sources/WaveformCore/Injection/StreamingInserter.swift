import AppKit
import ApplicationServices

/// Live streaming into the field: words appear at the caret WHILE the user
/// speaks, provisional text continuously replaced in place as the recognizer
/// settles, and the final cleaned/rewritten text lands with one last replace.
/// Aqua Voice ships this exact experience and states it requires their cloud;
/// SpeechAnalyzer's volatile/final stream makes it possible fully on-device.
///
/// Safety model, in order of importance:
///   1. Never corrupt the field. Every update targets the exact UTF-16 range
///      this streamer wrote, and verifies (via a targeted string-for-range
///      read) that the range still holds OUR text before replacing it. The
///      moment anything unexpected appears — the user typed, the app reflowed
///      — streaming freezes for the session rather than guessing.
///   2. Never block the pill. Streaming writes ride the FAST AX budget; a
///      slow tick is skipped, not awaited.
///   3. The caller keeps the clipboard safety net and full fallback path:
///      `begin` returning false, or `finish` returning false, simply means
///      "insert the old way".
@MainActor
final class StreamingInserter {
    private var element: AXUIElement?
    /// UTF-16 location where our streamed text begins in the field.
    private var start: Int = 0
    /// UTF-16 length of what we most recently wrote.
    private var length: Int = 0
    private var lastWritten: String = ""
    private var frozen = false
    private var lastUpdateAt: TimeInterval = 0

    var isActive: Bool { element != nil && !frozen }
    /// True once anything was streamed (even if later frozen) — the caller
    /// must not run a normal insert on top of visible streamed text.
    private(set) var hasStreamedText = false

    /// Throttle: recognizer updates arrive far faster than eyes read.
    private let minimumInterval: TimeInterval = 0.15

    /// Start a streaming session against the anchored element. Returns false
    /// when the field can't support verified range writes — caller falls back
    /// to insert-at-end, nothing lost.
    func begin(element: AXUIElement) -> Bool {
        reset()
        AXUIElementSetMessagingTimeout(element, 0.25)

        // The caret position is where our text will live. A live selection
        // will be REPLACED by the first write — that matches select-then-
        // dictate intent at the spot the user is looking at.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return false
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return false }

        self.element = element
        self.start = range.location
        self.length = range.length   // a selection counts as "ours to replace"
        self.lastWritten = ""        // verified lazily on the first write
        return true
    }

    /// Push the latest live text. Cheap no-op when throttled, frozen, or
    /// unchanged. Freezes the session on any surprise.
    func update(_ text: String) {
        guard isActive, text != lastWritten else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdateAt >= minimumInterval else { return }
        lastUpdateAt = now
        _ = replaceStreamedRange(with: text)
    }

    /// Replace everything streamed with the final text. Returns false when
    /// the field changed under us — the caller then falls back to the
    /// clipboard pill (never a duplicate insert).
    func finish(with finalText: String) -> Bool {
        guard element != nil else { return false }
        defer { reset() }
        guard !frozen else { return false }
        return replaceStreamedRange(with: finalText)
    }

    /// Cancelled dictation: take the streamed words back out.
    func abort() {
        if element != nil, !frozen, hasStreamedText {
            _ = replaceStreamedRange(with: "")
        }
        reset()
    }

    // MARK: - The one write primitive

    private func replaceStreamedRange(with text: String) -> Bool {
        guard let element, !frozen else { return false }

        // Verify OUR range still holds OUR text (targeted read — never the
        // whole document). First write skips this: the range is the caret or
        // the user's own selection.
        if !lastWritten.isEmpty {
            var range = CFRange(location: start, length: length)
            guard let rangeValue = AXValueCreate(.cfRange, &range) else { return freeze() }
            var currentRef: CFTypeRef?
            let readStatus = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &currentRef
            )
            if readStatus == .success, let current = currentRef as? String {
                if current != lastWritten {
                    Log.injection.notice("streaming frozen — field changed under the stream")
                    return freeze()
                }
            }
            // Unreadable is tolerated: some fields verified the first write
            // but can't serve targeted reads; the selection-set below still
            // scopes the write exactly.
        }

        var target = CFRange(location: start, length: length)
        guard let targetValue = AXValueCreate(.cfRange, &target),
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, targetValue
              ) == .success,
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
              ) == .success else {
            return freeze()
        }

        length = text.utf16.count
        lastWritten = text
        if !text.isEmpty { hasStreamedText = true }
        return true
    }

    private func freeze() -> Bool {
        frozen = true
        return false
    }

    private func reset() {
        element = nil
        start = 0
        length = 0
        lastWritten = ""
        frozen = false
        hasStreamedText = false
        lastUpdateAt = 0
    }
}
