import Foundation

/// Detects a spoken command at the START of a dictation, e.g.:
///   "make this message better and more structured, so basically we …"
///   "create a quick prompt for me, I want an agent that …"
///
/// Pure and unit-tested. Anything that isn't clearly a command passes through
/// untouched — false positives (rewriting text the user wanted verbatim) are
/// far worse than false negatives.
struct DictationCommand: Equatable {
    enum Kind: Equatable {
        case improve        // restructure / clean up the payload
        case createPrompt   // turn the payload into a well-formed AI prompt
    }

    let kind: Kind
    let payload: String
}

enum CommandDetector {
    /// Payloads shorter than this are not worth rewriting (and the "command"
    /// was probably just a normal sentence).
    private static let minimumPayload = 12

    private static let improvePattern =
        #"(?is)^(?:please\s+)?(?:can\s+you\s+)?make\s+(?:this|it|my)\s*(?:message|text|email|note|prompt)?\s*"#
        + #"(?:better|more\s+structured|structured|more\s+professional|professional|more\s+organized|organized|clearer|more\s+concise|concise|formal|shorter)"#
        + #"(?:\s+and\s+(?:more\s+)?(?:better|structured|professional|organized|clear(?:er)?|concise|formal|shorter))*"#
        + #"\s*[,.:;—-]?\s*(.+)$"#

    private static let promptPattern =
        #"(?is)^(?:please\s+)?(?:can\s+you\s+)?(?:create|make|write)\s+(?:a\s+)?(?:quick\s+)?prompt\s*"#
        + #"(?:for\s+me)?\s*(?:about|for|to|that\s+says|saying)?\s*[,.:;—-]?\s*(.+)$"#

    static func detect(in text: String) -> DictationCommand? {
        if let payload = firstMatchPayload(of: promptPattern, in: text) {
            return DictationCommand(kind: .createPrompt, payload: payload)
        }
        if let payload = firstMatchPayload(of: improvePattern, in: text) {
            return DictationCommand(kind: .improve, payload: payload)
        }
        return nil
    }

    private static func firstMatchPayload(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let payloadRange = Range(match.range(at: 1), in: text) else { return nil }
        let payload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.count >= minimumPayload else { return nil }
        return payload
    }
}
