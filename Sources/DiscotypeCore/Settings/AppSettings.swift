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

    var removeFillers: Bool {
        get {
            if defaults.object(forKey: Key.removeFillers) == nil { return true }
            return defaults.bool(forKey: Key.removeFillers)
        }
        set { defaults.set(newValue, forKey: Key.removeFillers) }
    }
}
