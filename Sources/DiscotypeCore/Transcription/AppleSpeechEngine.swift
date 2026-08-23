import AVFoundation
import Speech

/// On-device transcription via the macOS 26 SpeechAnalyzer / SpeechTranscriber
/// API. Fully local: the model is downloaded once by the OS, then audio never
/// leaves the machine. Punctuation and capitalization are produced by the
/// model itself; `.volatileResults` gives the live-updating tail for the HUD.
actor AppleSpeechEngine: TranscriptionEngine {
    enum EngineError: LocalizedError {
        case localeUnsupported(Locale)
        case notPrepared
        case noSession

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let locale):
                return "Transcription is not supported for \(locale.identifier(.bcp47))."
            case .notPrepared:
                return "The speech model is not ready yet."
            case .noSession:
                return "No dictation session is active."
            }
        }
    }

    private let locale: Locale
    private var prepared = false
    private var cachedFormat: AVAudioFormat?

    /// Keep the system-side model loaded for the whole process so every
    /// dictation after the first starts hot.
    private let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    // Per-session state.
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private let inputContinuation = LockedBox<AsyncStream<AnalyzerInput>.Continuation?>(nil)
    private var resultsTask: Task<String, Error>?
    private var finalizedText = ""

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    // MARK: - Preparation (asset download)

    func prepare() async throws {
        guard !prepared else { return }

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.localeUnsupported(locale)
        }

        let probe = Self.makeTranscriber(locale: supported)
        let status = await AssetInventory.status(forModules: [probe])
        if status == .unsupported {
            throw EngineError.localeUnsupported(supported)
        }
        if status != .installed {
            // Reserving can fail if the OS-wide reservation cap is hit; the
            // installation request below is the authoritative step.
            _ = try? await AssetInventory.reserve(locale: supported)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        }

        cachedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])

        // Prewarm: force the model into memory now (app launch) instead of on
        // the first hotkey press.
        let warmup = SpeechAnalyzer(modules: [probe], options: analyzerOptions)
        try? await warmup.prepareToAnalyze(in: cachedFormat)
        await warmup.cancelAndFinishNow()

        prepared = true
    }

    var preferredAudioFormat: AVAudioFormat? {
        cachedFormat
    }

    // MARK: - Live session

    func startSession(onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        guard prepared else { throw EngineError.notPrepared }
        await cancelSession()

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.localeUnsupported(locale)
        }
        let transcriber = Self.makeTranscriber(locale: supported)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputContinuation.value = continuation
        self.finalizedText = ""

        resultsTask = Task {
            var finalized = ""
            var volatileTail = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized = Self.append(text, to: finalized)
                        volatileTail = ""
                    } else {
                        volatileTail = text
                    }
                    onUpdate(TranscriptionUpdate(finalized: finalized, volatile: volatileTail))
                }
            } catch is CancellationError {
                // Cancelled sessions just return what they had.
            }
            return Self.append(volatileTail, to: finalized)
        }

        try await analyzer.start(inputSequence: stream)
    }

    // Called from the audio thread: yields straight into the stream with no
    // actor hop or per-buffer Task allocation.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.value?.yield(AnalyzerInput(buffer: buffer))
    }

    func finishSession() async throws -> String {
        guard let analyzer, let resultsTask else { throw EngineError.noSession }
        inputContinuation.value?.finish()
        inputContinuation.value = nil

        // A hung finalization must not wedge the app (Murmur has no such
        // timeout); 10s is generous for flushing a few seconds of tail audio.
        try await withThrowingTimeout(seconds: 10) {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        let text = try await resultsTask.value
        clearSession()
        return text
    }

    func cancelSession() async {
        inputContinuation.value?.finish()
        inputContinuation.value = nil
        resultsTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        clearSession()
    }

    private func clearSession() {
        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    /// `.fastResults` trades a little accuracy on the volatile (gray) text
    /// for noticeably lower display latency; the finalized text is unaffected.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private static func append(_ fragment: String, to base: String) -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return base }
        return base.isEmpty ? trimmed : base + " " + trimmed
    }
}

// MARK: - Timeout helper

struct TimeoutError: Error {}

func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}
