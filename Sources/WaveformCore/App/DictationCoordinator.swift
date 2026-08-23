import AppKit
import AVFoundation

/// State machine for one dictation cycle:
///
///   idle --hotkey--> recording --hotkey--> finalizing --> injecting --> idle
///
/// A hotkey press during `finalizing` is ignored (prevents double-runs of the
/// tail); errors surface briefly on the HUD and return to idle.
@MainActor
final class DictationCoordinator {
    private enum State {
        case idle
        case starting
        case recording
        case finishing
    }

    private var state: State = .idle
    private let engine: TranscriptionEngine = AppleSpeechEngine()
    private let audio = AudioCaptureService()
    private let injector = TextInjector()
    private let hud = HUDController()
    private let rewriter = LocalRewriter()

    private var enginePrepared = false
    private var prepareFailure: String?
    private var promptedAccessibility = false

    // Silence auto-stop state.
    private var lastVoiceActivityAt: TimeInterval = 0
    private var sawSpeech = false
    private var silenceTimer: Timer?
    /// Mic level above this counts as voice activity (0…1 on the -50…0 dBFS map).
    private let voiceLevelThreshold: Float = 0.22

    var engineStatusLine: String? {
        if enginePrepared { return nil }
        if let prepareFailure { return "Engine error: \(prepareFailure)" }
        return "Downloading speech model…"
    }

    // MARK: - Engine warm-up

    func prepareEngine() async {
        hud.preload()
        do {
            try await engine.prepare()
            enginePrepared = true
        } catch {
            prepareFailure = error.localizedDescription
            NSLog("Waveform: engine prepare failed: \(error)")
        }
    }

    // MARK: - Hotkey entry point

    func toggle() {
        switch state {
        case .idle:
            Task { await start() }
        case .recording:
            Task { await stop() }
        case .starting, .finishing:
            break
        }
    }

    private func start() async {
        guard state == .idle else { return }
        state = .starting

        // Hot path: when the mic is already authorized there is nothing to
        // wait for — show the HUD immediately. Prompts only on first run.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .idle
                showTransientError("Microphone access denied — enable it in System Settings → Privacy.")
                return
            }
        default:
            state = .idle
            showTransientError("Microphone access denied — enable it in System Settings → Privacy.")
            return
        }

        // Nudge the Accessibility prompt once per launch so injection works later.
        if !promptedAccessibility {
            promptedAccessibility = true
            _ = TextInjector.isTrusted(promptIfNeeded: true)
        }

        if !enginePrepared {
            await prepareEngine()
            guard enginePrepared else {
                state = .idle
                showTransientError(prepareFailure ?? "Speech engine unavailable.")
                return
            }
        }

        hud.show()
        let hudState = hud.state
        sawSpeech = false
        lastVoiceActivityAt = ProcessInfo.processInfo.systemUptime

        do {
            try await engine.startSession(contextualStrings: AppSettings.shared.dictionaryTerms) { update in
                Task { @MainActor [weak self] in
                    if update.display != hudState.transcript {
                        hudState.transcript = update.display
                        // The recognizer producing new text is the strongest
                        // "still speaking" signal there is.
                        if let self, !update.display.isEmpty {
                            self.sawSpeech = true
                            self.lastVoiceActivityAt = ProcessInfo.processInfo.systemUptime
                        }
                    }
                }
            }

            let format = await engine.preferredAudioFormat
            audio.onBuffer = { [engine] buffer in
                engine.feed(buffer)
            }
            audio.onLevel = { [weak self] level in
                Task { @MainActor in
                    hudState.pushLevel(level)
                    if let self, level > self.voiceLevelThreshold {
                        self.lastVoiceActivityAt = ProcessInfo.processInfo.systemUptime
                    }
                }
            }
            try audio.start(targetFormat: format)
            state = .recording
            startSilenceWatchdog()
        } catch {
            audio.stop()
            await engine.cancelSession()
            hud.state.phase = .error("Couldn't start: \(error.localizedDescription)")
            hideHUDAfterDelay()
            state = .idle
        }
    }

    private func stop() async {
        guard state == .recording else { return }
        state = .finishing
        stopSilenceWatchdog()
        hud.state.phase = .finalizing
        audio.stop()

        do {
            let raw = try await engine.finishSession()
            let cleaner = TextCleaner(removeFillers: AppSettings.shared.removeFillers)
            var cleaned = cleaner.clean(raw)

            if cleaned.isEmpty {
                hud.hide()
                state = .idle
                return
            }

            // Spoken AI command ("make this better, …")? Rewrite on-device;
            // any failure falls back to the payload as dictated.
            if AppSettings.shared.aiCommandsEnabled,
               LocalRewriter.isAvailable,
               let command = CommandDetector.detect(in: cleaned) {
                hud.state.phase = .polishing
                cleaned = await rewriter.rewrite(command) ?? command.payload
            }

            let outcome = await injector.inject(cleaned, method: AppSettings.shared.insertionMethod)
            switch outcome {
            case .insertedDirectly, .pasted, .typed:
                hud.hide()
            case .copiedOnly:
                hud.state.phase = .noAccessibility
                hideHUDAfterDelay(seconds: 3)
            }
        } catch {
            await engine.cancelSession()
            hud.state.phase = .error("Transcription failed")
            NSLog("Waveform: finish failed: \(error)")
            hideHUDAfterDelay()
        }
        state = .idle
    }

    // MARK: - Silence auto-stop

    /// Ends dictation on its own once you have spoken and then stayed silent
    /// for the configured grace period. Brief pauses between sentences keep
    /// the session alive: any voice-level activity or new recognized text
    /// resets the clock. Never fires before the first recognized words, so
    /// gathering your thoughts at the start costs nothing. The hotkey still
    /// stops manually at any time.
    private func startSilenceWatchdog() {
        stopSilenceWatchdog()
        let timeout = AppSettings.shared.silenceTimeout
        guard timeout > 0 else { return }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording, self.sawSpeech else { return }
                let quietFor = ProcessInfo.processInfo.systemUptime - self.lastVoiceActivityAt
                if quietFor >= timeout {
                    await self.stop()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceWatchdog() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Helpers

    private func showTransientError(_ message: String) {
        hud.show()
        hud.state.phase = .error(message)
        hideHUDAfterDelay(seconds: 3)
    }

    private func hideHUDAfterDelay(seconds: TimeInterval = 2) {
        Task { [hud] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            hud.hide()
        }
    }
}
