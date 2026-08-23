import Foundation

/// Buckets the target app into a formatting category (Wispr-style context
/// awareness — computed entirely on-device from the frontmost app's bundle id).
enum AppStyle {
    private static let messagingApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
        "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.microsoft.teams2",
    ]
    private static let codeApps: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode", "com.googlecode.iterm2", "com.apple.Terminal",
        "dev.zed.Zed", "com.sublimetext.4", "com.jetbrains.intellij",
        "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]

    static func cleanStyle(forBundleId bundleId: String?) -> TextCleaner.CleanStyle {
        guard let bundleId else { return .standard }
        if codeApps.contains(bundleId) { return .code }
        if messagingApps.contains(bundleId) { return .chat }
        return .standard
    }
}
