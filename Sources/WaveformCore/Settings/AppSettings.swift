import Foundation

/// UserDefaults-backed settings. Read at point of use (no restart needed).
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotkeyPreset = "hotkeyPreset"
        static let removeFillers = "removeFillers"
        static let insertionMethod = "insertionMethod"
        static let silenceTimeout = "silenceTimeout"
        static let dictionaryTerms = "dictionaryTerms"
        static let aiCommandsEnabled = "aiCommandsEnabled"
        static let saveHistory = "saveHistory"
        static let contextAwareStyle = "contextAwareStyle"
        static let snippets = "snippets"
        static let voiceCommandsEnabled = "voiceCommandsEnabled"
        static let toneStyle = "toneStyle"
        static let styleLearningEnabled = "styleLearningEnabled"
        static let styleCard = "styleCard"
        static let styleCardUpdatedAt = "styleCardUpdatedAt"
        static let contextAwarenessEnabled = "contextAwarenessEnabled"
        static let learnedTerms = "learnedTerms"
        static let learnFromCorrections = "learnFromCorrections"
        static let promptTemplates = "promptTemplates"
    }

    var hotkeyPreset: HotkeyPreset {
        get {
            guard let raw = defaults.string(forKey: Key.hotkeyPreset),
                  let preset = HotkeyPreset(rawValue: raw) else { return .fnTap }
            return preset
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyPreset) }
    }

    var insertionMethod: TextInjector.Method {
        get {
            guard let raw = defaults.string(forKey: Key.insertionMethod),
                  let method = TextInjector.Method(rawValue: raw) else { return .auto }
            return method
        }
        set { defaults.set(newValue.rawValue, forKey: Key.insertionMethod) }
    }

    /// Seconds of sustained silence (after speech) before dictation stops on
    /// its own. 0 disables auto-stop.
    var silenceTimeout: Double {
        get {
            if defaults.object(forKey: Key.silenceTimeout) == nil { return 2.5 }
            return defaults.double(forKey: Key.silenceTimeout)
        }
        set { defaults.set(newValue, forKey: Key.silenceTimeout) }
    }

    /// Personal dictionary: one term per line (names, jargon, acronyms).
    /// Fed to the recognizer as contextual bias strings.
    var dictionaryText: String {
        get { defaults.string(forKey: Key.dictionaryTerms) ?? "" }
        set { defaults.set(newValue, forKey: Key.dictionaryTerms) }
    }

    var dictionaryTerms: [String] {
        dictionaryText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Spoken commands like "make this better, …" rewritten by the on-device
    /// Apple Intelligence model. Local only; off means commands insert verbatim.
    var aiCommandsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.aiCommandsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.aiCommandsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.aiCommandsEnabled) }
    }

    /// Keep a local, capped dictation history (never leaves the Mac).
    var saveHistory: Bool {
        get {
            if defaults.object(forKey: Key.saveHistory) == nil { return true }
            return defaults.bool(forKey: Key.saveHistory)
        }
        set { defaults.set(newValue, forKey: Key.saveHistory) }
    }

    /// Adapt output to the target app: no trailing period in chat apps, no
    /// auto-capitalization/punctuation in code editors and terminals.
    var contextAwareStyle: Bool {
        get {
            if defaults.object(forKey: Key.contextAwareStyle) == nil { return true }
            return defaults.bool(forKey: Key.contextAwareStyle)
        }
        set { defaults.set(newValue, forKey: Key.contextAwareStyle) }
    }

    var snippets: [Snippet] {
        get {
            guard let data = defaults.data(forKey: Key.snippets),
                  let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.snippets)
            }
        }
    }

    /// Spoken formatting: "new paragraph", "bullet point", "comma", …
    var voiceCommandsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.voiceCommandsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.voiceCommandsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.voiceCommandsEnabled) }
    }

    /// Watch for words you fix by hand after Waveform types them, and add
    /// them to the dictionary so the mistake stops repeating.
    var learnFromCorrections: Bool {
        get {
            if defaults.object(forKey: Key.learnFromCorrections) == nil { return true }
            return defaults.bool(forKey: Key.learnFromCorrections)
        }
        set { defaults.set(newValue, forKey: Key.learnFromCorrections) }
    }

    /// Terms picked up from corrections, newest first. Kept separate from the
    /// hand-written dictionary so they can be reviewed and cleared on their own.
    var learnedTerms: [String] {
        get { defaults.stringArray(forKey: Key.learnedTerms) ?? [] }
        set { defaults.set(Array(newValue.prefix(200)), forKey: Key.learnedTerms) }
    }

    func addLearnedTerms(_ terms: [String]) {
        var existing = learnedTerms
        for term in terms where !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            existing.insert(term, at: 0)
        }
        learnedTerms = existing
    }

    /// Everything fed to the recognizer as contextual bias.
    var recognitionHints: [String] {
        Self.composeRecognitionHints(
            commandHints: CommandDetector.vocabularyHints,
            templateTriggers: promptTemplates.map(\.trigger),
            learned: learnedTerms,
            dictionary: dictionaryTerms
        )
    }

    /// Pure so the ordering rules are testable. Two rules matter:
    ///   1. The user's own template triggers get spoken-marker hints — a
    ///      trigger the recognizer can't hear is a command that silently
    ///      never fires (the "prompt" → "prom" bug, custom edition).
    ///   2. Command and trigger hints come FIRST: the list is capped (an
    ///      unbounded bias set dilutes rather than helps), and a 140-term
    ///      dictionary must never evict the handful of hints that make
    ///      commands work at all.
    static func composeRecognitionHints(
        commandHints: [String],
        templateTriggers: [String],
        learned: [String],
        dictionary: [String]
    ) -> [String] {
        let triggerHints = templateTriggers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { ["slash \($0)", "double slash \($0)"] }
        return Array((commandHints + triggerHints + learned + dictionary).prefix(140))
    }

    var promptTemplates: [PromptTemplate] {
        get {
            guard let data = defaults.data(forKey: Key.promptTemplates),
                  let decoded = try? JSONDecoder().decode([PromptTemplate].self, from: data) else {
                return PromptLibrary.defaults
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.promptTemplates)
            }
        }
    }

    /// The tone dial for AI rewrites: auto follows the target app's category
    /// (chat casual, email neutral), or force casual/formal everywhere.
    enum ToneStyle: String, CaseIterable, Identifiable {
        case auto, casual, formal
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto (match the app)"
            case .casual: return "Casual"
            case .formal: return "Formal"
            }
        }
    }

    var toneStyle: ToneStyle {
        get {
            guard let raw = defaults.string(forKey: Key.toneStyle),
                  let tone = ToneStyle(rawValue: raw) else { return .auto }
            return tone
        }
        set { defaults.set(newValue.rawValue, forKey: Key.toneStyle) }
    }

    /// Distill a local style profile from history and condition rewrites on
    /// it. Everything stays on this Mac.
    var styleLearningEnabled: Bool {
        get {
            if defaults.object(forKey: Key.styleLearningEnabled) == nil { return true }
            return defaults.bool(forKey: Key.styleLearningEnabled)
        }
        set { defaults.set(newValue, forKey: Key.styleLearningEnabled) }
    }

    var styleCard: String {
        get { defaults.string(forKey: Key.styleCard) ?? "" }
        set { defaults.set(newValue, forKey: Key.styleCard) }
    }

    var styleCardUpdatedAt: Double {
        get { defaults.double(forKey: Key.styleCardUpdatedAt) }
        set { defaults.set(newValue, forKey: Key.styleCardUpdatedAt) }
    }

    /// Read the text around the caret (via Accessibility, on-device only) to
    /// ground names and match tone. Secure fields are always excluded.
    var contextAwarenessEnabled: Bool {
        get {
            if defaults.object(forKey: Key.contextAwarenessEnabled) == nil { return true }
            return defaults.bool(forKey: Key.contextAwarenessEnabled)
        }
        set { defaults.set(newValue, forKey: Key.contextAwarenessEnabled) }
    }

    var removeFillers: Bool {
        get {
            if defaults.object(forKey: Key.removeFillers) == nil { return true }
            return defaults.bool(forKey: Key.removeFillers)
        }
        set { defaults.set(newValue, forKey: Key.removeFillers) }
    }
}
