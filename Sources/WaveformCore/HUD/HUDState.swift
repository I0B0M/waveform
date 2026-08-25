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

    @Published var phase: Phase = .listening {
        didSet {
            if phase != oldValue {
                phaseChangedAt = Date().timeIntervalSinceReferenceDate
            }
        }
    }
    /// When the current phase began — the waveform uses it to time the
    /// "ears closed" collapse and the processing shimmer.
    @Published var phaseChangedAt: Double = Date().timeIntervalSinceReferenceDate

    @Published var finalizedText: String = ""
    @Published var volatileText: String = ""

    /// The transcript as identity-stable words for the jump-free strip.
    @Published var words: [TranscriptWord] = []

    /// When the recognizer last produced new text. Drives the cyan
    /// "understanding" ribbon: fresh = flowing, stale = still.
    @Published var lastRecognitionAt: Double = Date().timeIntervalSinceReferenceDate

    private var pendingShrink: Task<Void, Never>?

    var transcript: String {
        (finalizedText + " " + volatileText).trimmingCharacters(in: .whitespaces)
    }

    /// Apply a live transcription update. Growth lands instantly; SHRINKAGE
    /// (the recognizer retracting volatile words) is held for 200ms — if the
    /// retracted words come back reworded, the eye never sees the dip.
    func applyTranscript(finalized: String, volatile: String) {
        let candidate = TranscriptComposer.compose(
            finalized: finalized, volatile: volatile, previous: words
        )
        if candidate.count < words.count {
            pendingShrink?.cancel()
            pendingShrink = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }
                self.finalizedText = finalized
                self.volatileText = volatile
                self.words = TranscriptComposer.compose(
                    finalized: finalized, volatile: volatile, previous: self.words
                )
            }
            return
        }
        pendingShrink?.cancel()
        pendingShrink = nil
        finalizedText = finalized
        volatileText = volatile
        words = candidate
    }

    func noteRecognition() {
        lastRecognitionAt = Date().timeIntervalSinceReferenceDate
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
        pendingShrink?.cancel()
        pendingShrink = nil
        phase = .listening
        finalizedText = ""
        volatileText = ""
        words = []
        lastRecognitionAt = Date().timeIntervalSinceReferenceDate
        level = 0
    }
}
