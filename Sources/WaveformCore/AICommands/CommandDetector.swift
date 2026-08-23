import Foundation

/// A command the user spoke at the start of a dictation.
struct DictationCommand: Equatable {
    enum Kind: Equatable {
        case improve        // restructure / clean up
        case createPrompt   // turn the payload into a well-formed AI prompt
    }

    let kind: Kind
    /// What to transform. Empty means "use the current selection".
    let payload: String
    /// True when the user used an explicit `//command` prefix — those are
    /// unambiguous, so failures should be reported rather than swallowed.
    let wasExplicit: Bool
}

enum CommandDetector {
    /// Explicit prefixes are the reliable path: say "double slash prompt"
    /// (or "slash prompt") and everything after it is the payload. Natural
    /// language ("make this better, …") still works as a fallback, but guessing
    /// from prose is inherently fuzzy — the prefix never misfires.
    ///
    /// The recognizer writes the spoken marker several ways ("double slash",
    /// "slash slash", "slash", and occasionally the literal "//"), so all of
    /// them are accepted.
    private static let spokenPrefix =
        #"(?is)^\s*(?:(?:double|two)\s+)?slash(?:\s+slash)?\s+"#
        + #"(prompt|better|improve|organi[sz]e|organi[sz]ed|structure|structured|professional|clean(?:\s*up)?|shorter|concise)"#
        + #"\b[\s,.:;—-]*(.*)$"#

    private static let symbolPrefix =
        #"(?is)^\s*/{1,2}\s*"#
        + #"(prompt|better|improve|organi[sz]e|organi[sz]ed|structure|structured|professional|clean(?:\s*up)?|shorter|concise)"#
        + #"\b[\s,.:;—-]*(.*)$"#

    /// Payloads shorter than this aren't worth rewriting — but an explicit
    /// prefix with no payload is valid: it targets the selection instead.
    private static let minimumPayload = 6

    private static let improvePattern =
        #"(?is)^(?:please\s+)?(?:can\s+you\s+)?make\s+(?:this|it|my)\s*(?:message|text|email|note|prompt)?\s*"#
        + #"(?:better|more\s+structured|structured|more\s+professional|professional|more\s+organized|organized|clearer|more\s+concise|concise|formal|shorter)"#
        + #"(?:\s+and\s+(?:more\s+)?(?:better|structured|professional|organized|clear(?:er)?|concise|formal|shorter))*"#
        + #"\s*[,.:;—-]?\s*(.+)$"#

    private static let promptPattern =
        #"(?is)^(?:please\s+)?(?:can\s+you\s+)?(?:create|make|write)\s+(?:a\s+)?(?:quick\s+)?prompt\s*"#
        + #"(?:for\s+me)?\s*(?:about|for|to|that\s+says|saying)?\s*[,.:;—-]?\s*(.+)$"#

    static func detect(in text: String) -> DictationCommand? {
        // 1. Explicit prefixes win — no payload-length floor, because an
        //    empty payload means "act on my selection".
        for pattern in [spokenPrefix, symbolPrefix] {
            guard let (keyword, payload) = twoGroups(of: pattern, in: text) else { continue }
            let kind: DictationCommand.Kind = keyword.lowercased().hasPrefix("prompt")
                ? .createPrompt
                : .improve
            return DictationCommand(kind: kind, payload: payload, wasExplicit: true)
        }

        // 2. Natural-language fallback.
        if let payload = firstMatchPayload(of: promptPattern, in: text) {
            return DictationCommand(kind: .createPrompt, payload: payload, wasExplicit: false)
        }
        if let payload = firstMatchPayload(of: improvePattern, in: text) {
            return DictationCommand(kind: .improve, payload: payload, wasExplicit: false)
        }
        return nil
    }

    /// Selection mode: the user had text selected and spoke a short
    /// imperative ("make this more organized", "turn this into bullet
    /// points"). Returns the instruction, or nil when the speech looks like
    /// content rather than an instruction.
    static func selectionInstruction(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard !words.isEmpty else { return nil }

        while let first = words.first, ["please", "can", "you", "could"].contains(first) {
            words.removeFirst()
        }
        guard let verb = words.first, (2...24).contains(words.count) else { return nil }

        let instructionVerbs: Set<String> = [
            "make", "turn", "rewrite", "rework", "reword", "summarize", "summarise",
            "shorten", "expand", "fix", "improve", "clean", "translate", "convert",
            "simplify", "formalize", "formalise", "organize", "organise", "structure",
            "polish", "tighten", "bulletize", "condense",
        ]
        guard instructionVerbs.contains(verb) else { return nil }
        return trimmed
    }

    // MARK: - Regex helpers

    private static func twoGroups(of pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 2,
              let keywordRange = Range(match.range(at: 1), in: text),
              let payloadRange = Range(match.range(at: 2), in: text) else { return nil }
        return (
            String(text[keywordRange]),
            String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
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
