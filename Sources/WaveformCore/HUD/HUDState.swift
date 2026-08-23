import SwiftUI

/// Observable model driving the HUD. All mutation happens on the main actor.
@MainActor
final class HUDState: ObservableObject {
    enum Phase: Equatable {
        case listening
        case finalizing
        case polishing         // on-device AI rewrite in progress
        case noAccessibility   // text was copied; user must press ⌘V themselves
        case error(String)
    }

    @Published var phase: Phase = .listening
    @Published var finalizedText: String = ""
    @Published var volatileText: String = ""

    var transcript: String {
        (finalizedText + " " + volatileText).trimmingCharacters(in: .whitespaces)
    }

    /// Smoothed 0…1 microphone level (attack fast, release slow so the
    /// waveform feels alive without flickering).
    @Published var level: Float = 0

    func pushLevel(_ raw: Float) {
        if raw > level {
            level += (raw - level) * 0.6
        } else {
            level += (raw - level) * 0.15
        }
    }

    func reset() {
        phase = .listening
        finalizedText = ""
        volatileText = ""
        level = 0
    }
}
