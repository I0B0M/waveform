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
    private let learner = CorrectionLearner()

    private var enginePrepared = false
    private var prepareFailure: String?
    private var promptedAccessibility = false

    // Per-session context.
    private var sessionStartedAt: TimeInterval = 0
    private var selectionAtStart: String?
    private var targetAppName: String?
    private var targetBundleId: String?
    /// Set by the HUD's ✨ button: treat this dictation as a command of this
    /// kind regardless of what the words look like.
    private var forcedCommand: DictationCommand.Kind?

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
        hud.onFinish = { [weak self] in self?.toggle() }
        hud.onPolish = { [weak self] promptMode in
            self?.finishWithPolish(promptMode ? .createPrompt : .improve)
        }
        hud.onCancel = { [weak self] in Task { await self?.cancelDictation() } }
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

        // Selection command mode: capture what's selected in the target app
        // BEFORE the HUD appears, so "make this more organized" can rewrite it.
        selectionAtStart = injector.readSelectedText()
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        targetBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sessionStartedAt = ProcessInfo.processInfo.systemUptime

        hud.show()
        let hudState = hud.state
        sawSpeech = false
        lastVoiceActivityAt = ProcessInfo.processInfo.systemUptime

        do {
            // Bias recognition toward the command words too — without this the
            // recognizer hears "prompt" as "prom" and the command silently
            // looks like ordinary speech.
            // Dictionary + terms learned from corrections + the command words.
            let hints = AppSettings.shared.recognitionHints
            try await engine.startSession(contextualStrings: hints) { update in
                Task { @MainActor [weak self] in
                    if update.display != hudState.transcript {
                        hudState.finalizedText = update.finalized
                        hudState.volatileText = update.volatile
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
            audio.onCaptureLost = { [weak self] in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.hud.state.phase = .error("Microphone lost — press the hotkey to retry")
                    await self.cancelDictation()
                    self.hideHUDAfterDelay(seconds: 3)
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

        // Read-and-clear immediately: whatever happens below — empty
        // transcript, a thrown error, an early return — this dictation is the
        // only one the ✨ button can affect.
        let forced = forcedCommand
        forcedCommand = nil

        do {
            let raw = try await engine.finishSession()
            let style: TextCleaner.CleanStyle = AppSettings.shared.contextAwareStyle
                ? AppStyle.cleanStyle(forBundleId: targetBundleId)
                : .standard
            let cleaner = TextCleaner(removeFillers: AppSettings.shared.removeFillers, style: style)
            let spoken = AppSettings.shared.voiceCommandsEnabled ? VoiceCommands.apply(to: raw) : raw
            let cleaned = cleaner.clean(spoken)

            if cleaned.isEmpty {
                hud.hide()
                state = .idle
                return
            }

            let templates = AppSettings.shared.promptTemplates
            let plan = DictationPlanner.plan(for: DictationContext(
                text: cleaned,
                forced: forced,
                selection: selectionAtStart,
                snippets: AppSettings.shared.snippets,
                templates: templates,
                aiEnabled: AppSettings.shared.aiCommandsEnabled,
                modelAvailable: LocalRewriter.isAvailable
            ))

            var failureNotice: String?
            let finalText: String

            switch plan {
            case .insert(let text):
                finalText = text

            case .insertWithNotice(let text, let notice):
                finalText = text
                failureNotice = notice

            case .snippet(let expansion):
                finalText = expansion

            case .rewrite(let kind, let subject, let fallback):
                hud.state.phase = .polishing
                let command = DictationCommand(kind: kind, payload: subject, wasExplicit: true)
                if let rewritten = await rewriter.rewrite(command) {
                    finalText = rewritten
                } else {
                    // Never lose the words: insert them and say what happened.
                    finalText = fallback
                    failureNotice = "Rewrite failed — inserted as spoken"
                }

            case .template(let id, let input, let fallback):
                guard let template = templates.first(where: { $0.id == id }) else {
                    finalText = fallback
                    break
                }
                hud.state.phase = .polishing
                if let built = await rewriter.build(from: template, input: input) {
                    finalText = built
                } else {
                    finalText = fallback
                    failureNotice = "\(template.title) failed — inserted as spoken"
                }

            case .transformSelection(let selection, let instruction):
                hud.state.phase = .polishing
                guard let transformed = await rewriter.transform(
                    selection: selection,
                    instruction: instruction
                ) else {
                    // Leave the selection alone rather than overwriting it with
                    // the instruction the user just spoke.
                    hud.state.phase = .error("Rewrite failed — selection left unchanged")
                    hideHUDAfterDelay(seconds: 3)
                    state = .idle
                    return
                }
                finalText = transformed

            case .resolveCorrections(let text):
                hud.state.phase = .polishing
                finalText = await rewriter.resolveCorrections(in: text) ?? text

            case .abort(let notice):
                hud.state.phase = .error(notice)
                hideHUDAfterDelay(seconds: 3)
                state = .idle
                return
            }

            let outcome = await injector.inject(finalText, method: AppSettings.shared.insertionMethod)
            if AppSettings.shared.saveHistory {
                HistoryStore.shared.add(
                    text: finalText,
                    duration: ProcessInfo.processInfo.systemUptime - sessionStartedAt,
                    appName: targetAppName
                )
            }

            // Watch for hand corrections to this text and learn the words.
            learner.noteInsertion(of: finalText)

            switch outcome {
            case .insertedDirectly, .pasted, .typed:
                if let failureNotice {
                    hud.state.phase = .error(failureNotice)
                    hideHUDAfterDelay(seconds: 3)
                } else {
                    hud.hide()
                }
            case .copiedOnly:
                hud.state.phase = .noAccessibility
                hideHUDAfterDelay(seconds: 3)
            }
        } catch {
            await engine.cancelSession()
            hud.state.phase = .error("Transcription failed")
            Log.app.error("finish failed: \(String(describing: error), privacy: .public)")
            hideHUDAfterDelay()
        }
        state = .idle
    }

    /// ✨ on the HUD: stop, then run the words through the on-device model
    /// before inserting. Removes any dependence on the command being *heard*.
    func finishWithPolish(_ kind: DictationCommand.Kind) {
        guard state == .recording else { return }
        forcedCommand = kind
        Task { await stop() }
    }

    /// ✕ on the HUD: throw the session away — nothing is inserted.
    func cancelDictation() async {
        guard state == .recording || state == .starting else { return }
        state = .finishing
        forcedCommand = nil
        stopSilenceWatchdog()
        audio.stop()
        await engine.cancelSession()
        hud.hide()
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
