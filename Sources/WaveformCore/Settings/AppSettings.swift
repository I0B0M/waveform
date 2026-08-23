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
    }

    var hotkeyPreset: HotkeyPreset {
        get {
            guard let raw = defaults.string(forKey: Key.hotkeyPreset),
                  let preset = HotkeyPreset(rawValue: raw) else { return .commandX }
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

    var removeFillers: Bool {
        get {
            if defaults.object(forKey: Key.removeFillers) == nil { return true }
            return defaults.bool(forKey: Key.removeFillers)
        }
        set { defaults.set(newValue, forKey: Key.removeFillers) }
    }
}
