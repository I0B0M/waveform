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
    /// People don't start talking at the command — "Okay, double slash
    /// prompt…" is the normal way it comes out. These lead-ins are skipped
    /// before matching (they carry no meaning of their own).
    private static let leadIn =
        #"(?:(?:okay|ok|so|alright|all\s+right|right|hey|now|yeah|well|let's\s+see(?:\s+how)?)\b[\s,.:;—-]*)*"#

    /// Stripped from the PAYLOAD too — but only openers that can't begin a
    /// real sentence. "so", "now", "right" and "well" are excluded on
    /// purpose: "Now that we shipped…" must survive intact.
    private static let payloadLeadIn =
        #"(?:(?:okay|ok|alright|all\s+right|hey|yeah|let's\s+see(?:\s+how)?)\b[\s,.:;—-]*)*"#

    /// "I need you to …", "I want you to …" — the way a request usually
    /// arrives when it isn't a bare imperative.
    private static let requestLeadIn =
        #"(?:i\s+(?:need|want|would\s+like)\s+(?:you\s+to\s+)?|(?:please\s+)?(?:can|could)\s+you\s+)?"#

    /// The command keyword, including the ways the recognizer actually mangles
    /// it. "prompt" very often comes back as "prom" or "promt" — matching only
    /// the correct spelling is why this silently did nothing.
    private static let keyword =
        #"(prom(?:pt|t|pts|pted)?|better|improve|organi[sz]ed?|structured?|professional|clean(?:\s*up)?|shorter|concise)"#

    /// Separator between the spoken words: whitespace, but also the hyphen the
    /// recognizer likes to insert ("double-slash") and stray punctuation.
    private static let sep = #"[\s,.:;—–-]+"#

    /// "double slash prompt", "slash slash prompt", "slash prompt" — and the
    /// literal "//prompt" if symbols come through. Searched ANYWHERE in the
    /// transcript, not just at the start: people restate the command
    /// mid-sentence ("let's start again — double slash prompt, …").
    // Marker only — the payload is whatever follows it. Keeping the payload
    // OUT of the pattern matters: a greedy trailing group consumes the rest of
    // the transcript, so the engine finds exactly one match and "use the last
    // occurrence" silently becomes "use the first".
    private static let spokenMarker =
        #"(?is)(?:(?:double|two)"# + sep + #")?slash(?:"# + sep + #"slash)?"# + sep
        + keyword + #"\b"#

    private static let symbolMarker =
        #"(?is)/{1,2}\s*"# + keyword + #"\b"#

    /// Payloads shorter than this aren't worth rewriting — but an explicit
    /// prefix with no payload is valid: it targets the selection instead.
    private static let minimumPayload = 6

    private static let improvePattern =
        #"(?is)^"# + leadIn + requestLeadIn + #"make\s+(?:this|it|my)\s*(?:message|text|email|note|prompt)?\s*"#
        + #"(?:better|more\s+structured|structured|more\s+professional|professional|more\s+organized|organized|clearer|more\s+concise|concise|formal|shorter)"#
        + #"(?:\s+and\s+(?:more\s+)?(?:better|structured|professional|organized|clear(?:er)?|concise|formal|shorter))*"#
        + #"\s*[,.:;—-]?\s*(.+)$"#

    private static let promptPattern =
        #"(?is)^"# + leadIn + requestLeadIn + #"(?:create|make|write|build)\s+(?:me\s+)?(?:a\s+)?(?:quick\s+)?prompt\s*"#
        + #"(?:for\s+me)?\s*(?:about|for|to|that\s+says|saying)?\s*[,.:;—-]?\s*(.+)$"#

    /// Fed to the recognizer as contextual bias so the command words are
    /// actually heard as themselves.
    static let vocabularyHints = [
        "double slash prompt", "slash prompt", "double slash better",
        "slash better", "slash organize", "slash professional",
        "slash shorter", "prompt",
    ]

    static func detect(in text: String) -> DictationCommand? {
        // 1. Explicit markers win — no payload-length floor, because an empty
        //    payload means "act on my selection".
        for pattern in [spokenMarker, symbolMarker] {
            guard let (word, payload) = lastMatch(of: pattern, in: text) else { continue }
            let kind: DictationCommand.Kind = word.lowercased().hasPrefix("prom")
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

    /// Lead-ins can also trail the command ("//prompt, let's see how, I
    /// need…") — they are noise wherever they land.
    private static func stripLeadIn(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: "(?is)^" + payloadLeadIn) else { return trimmed }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let matched = Range(match.range, in: trimmed),
              !matched.isEmpty else { return trimmed }
        return String(trimmed[matched.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The LAST marker in the transcript wins: when someone says the command,
    /// talks about it, then says it again, the final one is the real request.
    private static func lastMatch(of pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let match = matches.last,
              match.numberOfRanges > 1,
              let keywordRange = Range(match.range(at: 1), in: text),
              let markerRange = Range(match.range, in: text) else { return nil }

        let remainder = text[markerRange.upperBound...]
            .drop(while: { $0.isWhitespace || ",.:;—–-".contains($0) })
        return (String(text[keywordRange]), stripLeadIn(String(remainder)))
    }

    private static func firstMatchPayload(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let payloadRange = Range(match.range(at: 1), in: text) else { return nil }
        let payload = stripLeadIn(String(text[payloadRange]))
        guard payload.count >= minimumPayload else { return nil }
        return payload
    }
}
