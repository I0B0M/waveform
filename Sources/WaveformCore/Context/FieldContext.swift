import Foundation

/// What the app can see about the place text is about to land — Wispr's
/// flagship "Context Awareness", rebuilt fully on-device: read via
/// Accessibility at dictation start, used to ground recognition and shape
/// rewrites, then forgotten. Never persisted, never sent anywhere.
struct FieldContext {
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    /// Tail of the text before the caret (bounded — enough for tone and
    /// mid-sentence continuation, not the whole document).
    var before: String = ""
    /// Head of the text after the caret.
    var after: String = ""
    /// Secure fields (passwords) are never read: a context with `isSecure`
    /// carries no text and suppresses history for the session too.
    var isSecure: Bool = false

    var isEmpty: Bool { before.isEmpty && after.isEmpty && windowTitle == nil }
}

/// Pure helpers for mining the surrounding text — extracted for tests.
enum ContextHints {
    /// Proper nouns and jargon from the text around the cursor, fed to the
    /// recognizer as bias so names are heard the way the conversation
    /// already spells them ("Aqeeb", "NestJS", "playground PR").
    static func extract(from text: String, limit: Int = 20) -> [String] {
        var seen = Set<String>()
        var hints: [String] = []
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for (index, raw) in words.enumerated() {
            let word = String(raw)
            guard word.count >= 2, word.count <= 24 else { continue }
            guard looksLikeProperNoun(word) else { continue }
            // Sentence-initial capitals are usually just capitals; keep them
            // only when the same word also appears elsewhere or is unusual.
            if index == 0, word.first!.isUppercase, word.dropFirst().allSatisfy(\.isLowercase) {
                continue
            }
            let key = word.lowercased()
            if seen.insert(key).inserted {
                hints.append(word)
                if hints.count >= limit { break }
            }
        }
        return hints
    }

    private static func looksLikeProperNoun(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        let rest = word.dropFirst()
        // Ordinary capitalized word (Sarah, Waveform).
        if first.isUppercase, rest.allSatisfy(\.isLowercase), rest.count >= 2 { return true }
        // ALLCAPS acronyms (TCC, HIPAA) — but not single letters or "I".
        if word.count >= 2, word.count <= 6, word.allSatisfy(\.isUppercase) { return true }
        // Mixed case / camelCase / letters+digits (NestJS, iPhone, GPT4).
        let hasUpperInside = rest.contains(where: \.isUppercase)
        let hasDigit = word.contains(where: \.isNumber)
        if hasUpperInside || (hasDigit && word.contains(where: \.isLetter)) { return true }
        return false
    }
}
