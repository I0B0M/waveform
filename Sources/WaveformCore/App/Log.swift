import OSLog

/// Unified-log channel for the app. Preferred over `NSLog`: entries are
/// queryable by subsystem, which makes it possible to see what a *running*
/// instance is doing —
///
///   log show --last 5m --predicate 'subsystem == "com.ibrahim.waveform"'
///
/// — without needing Accessibility permission to inspect the app from outside.
enum Log {
    static let app = Logger(subsystem: "com.ibrahim.waveform", category: "app")
    static let injection = Logger(subsystem: "com.ibrahim.waveform", category: "injection")
    static let hotkey = Logger(subsystem: "com.ibrahim.waveform", category: "hotkey")
    static let selftest = Logger(subsystem: "com.ibrahim.waveform", category: "selftest")
}
