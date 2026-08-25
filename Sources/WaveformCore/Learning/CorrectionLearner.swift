import AppKit
import ApplicationServices

/// Learns vocabulary from the corrections you make by hand.
///
/// After Waveform types something, it snapshots the field. A short while later
/// it reads the field again and looks for single words that were swapped —
/// "prom" → "prompt", "nestjs" → "NestJS". Those go into the dictionary, which
/// biases the recognizer next time, so the same mistake stops recurring.
///
/// Deliberately conservative, because a wrong lesson is worse than no lesson:
///   • only 1:1 word substitutions (see `WordDiff`),
///   • only where the new word is close to what was heard (a mishearing) or
///     differs just in capitalization,
///   • never stores the field's contents — only the corrected word itself.
@MainActor
final class CorrectionLearner {
    /// How long to wait before looking. Long enough that you've noticed the
    /// mistake and fixed it, short enough that the field still exists.
    private let inspectionDelay: TimeInterval = 12

    private var pending: Task<Void, Never>?

    func noteInsertion(of text: String) {
        guard AppSettings.shared.learnFromCorrections,
              TextInjector.isTrusted(promptIfNeeded: false),
              !text.isEmpty else { return }

        guard let element = Self.focusedElement() else { return }

        let insertedTokens = WordDiff.tokens(text)
        guard !insertedTokens.isEmpty else { return }

        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            // The typed injection path is still posting events when this is
            // called — snapshotting instantly would diff the insertion itself
            // as a "correction". Let the field settle first.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let baseline = Self.value(of: element) else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.inspectionDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.inspect(element: element, baseline: baseline, inserted: Set(insertedTokens.map { $0.lowercased() }))
        }
    }

    /// Undo rips the inserted text back out — a pending inspection would
    /// then read the hole (or a retype) as vocabulary corrections.
    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func inspect(element: AXUIElement, baseline: String, inserted: Set<String>) {
        guard let current = Self.value(of: element), current != baseline else { return }

        let substitutions = WordDiff.substitutions(
            from: WordDiff.tokens(baseline),
            to: WordDiff.tokens(current)
        )
        let learned = substitutions
            // Only words WE put there — edits elsewhere in the field aren't
            // corrections of our transcription.
            .filter { inserted.contains($0.from.lowercased()) }
            .filter { Self.isWorthLearning(from: $0.from, to: $0.to) }
            .map(\.to)

        guard !learned.isEmpty else { return }
        AppSettings.shared.addLearnedTerms(learned)
        // Count only — the corrected words are the user's private vocabulary.
        Log.app.notice("learned \(learned.count, privacy: .public) term(s) from a correction")
    }

    /// Pure rule — no actor state, so it stays testable on its own.
    nonisolated static func isWorthLearning(from old: String, to new: String) -> Bool {
        guard new.count >= 3, new.count <= 40 else { return false }
        // Must look like a word/identifier, not punctuation or a number.
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'_"))
        guard new.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard new.contains(where: { $0.isLetter }) else { return false }

        // A pure capitalization fix is worth learning ("nestjs" -> "NestJS").
        if old.lowercased() == new.lowercased() { return old != new }

        // Otherwise only when the recognizer was *close* — that's a mishearing.
        // A wholly different word is an edit of meaning, not of vocabulary.
        let distance = WordDiff.editDistance(old, new)
        return distance <= max(2, new.count / 3)
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              text.count < 20_000 else { return nil }
        return text
    }
}
