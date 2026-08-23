import AVFoundation

/// Live update pushed while dictating: the stable (finalized) prefix plus the
/// still-changing (volatile) tail.
struct TranscriptionUpdate: Sendable {
    let finalized: String
    let volatile: String

    var display: String {
        (finalized + " " + volatile).trimmingCharacters(in: .whitespaces)
    }
}

/// Seam that lets the transcription backend be swapped later (e.g. for a
/// whisper.cpp or Parakeet engine) without touching audio, HUD, or injection.
protocol TranscriptionEngine: AnyObject {
    /// One-time (per launch) setup: verify locale support and download model
    /// assets if missing. Safe to call repeatedly.
    func prepare() async throws

    /// The audio format buffers should be delivered in, once prepared.
    var preferredAudioFormat: AVAudioFormat? { get async }

    /// Begin a live session. `contextualStrings` bias recognition toward the
    /// user's personal dictionary (names, jargon). `onUpdate` is called on an
    /// arbitrary executor.
    func startSession(
        contextualStrings: [String],
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws

    /// Feed one audio buffer (already in `preferredAudioFormat`).
    func feed(_ buffer: AVAudioPCMBuffer)

    /// End the session, wait for remaining audio to finalize, and return the
    /// complete raw transcript.
    func finishSession() async throws -> String

    /// Abort without waiting for results (error/cancel path).
    func cancelSession() async
}
