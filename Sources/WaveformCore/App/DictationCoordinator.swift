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
            let style: TextCleaner.CleanStyle = AppSettings.shared.contextAwareStyle
                ? AppStyle.cleanStyle(forBundleId: targetBundleId)
                : .standard
            let cleaner = TextCleaner(removeFillers: AppSettings.shared.removeFillers, style: style)
            let spoken = AppSettings.shared.voiceCommandsEnabled ? VoiceCommands.apply(to: raw) : raw
            var cleaned = cleaner.clean(spoken)

            if cleaned.isEmpty {
                hud.hide()
                state = .idle
                return
            }

            // Interpretation, most-explicit first. Each branch is mutually
            // exclusive: a snippet is not a command, a command is not speech.
            var failureNotice: String?

            // 0. The ✨ button was pressed — an explicit, unmistakable request.
            if let kind = forcedCommand {
                forcedCommand = nil
                if !LocalRewriter.isAvailable {
                    failureNotice = "Apple Intelligence is off — inserted as spoken"
                } else {
                    hud.state.phase = .polishing
                    let subject = selectionAtStart ?? cleaned
                    let command = DictationCommand(kind: kind, payload: subject, wasExplicit: true)
                    if let rewritten = await rewriter.rewrite(command) {
                        cleaned = rewritten
                    } else {
                        failureNotice = "Rewrite failed — inserted as spoken"
                    }
                }
            }
            // 1. Voice snippet ("insert my calendar link").
            else if let expansion = SnippetMatcher.expansion(for: cleaned, in: AppSettings.shared.snippets) {
                cleaned = expansion
            }
            // 1b. One of the user's prompt templates ("//plan …").
            else if AppSettings.shared.aiCommandsEnabled,
                    case let templates = AppSettings.shared.promptTemplates,
                    let hit = CommandDetector.templateCommand(
                        in: cleaned,
                        triggers: templates.map(\.trigger)
                    ),
                    let template = templates.first(where: {
                        $0.trigger.caseInsensitiveCompare(hit.trigger) == .orderedSame
                    }) {
                let input = hit.payload.isEmpty ? (selectionAtStart ?? "") : hit.payload
                if input.isEmpty {
                    failureNotice = "Nothing to work on — say the details after the command"
                } else if !LocalRewriter.isAvailable {
                    cleaned = input
                    failureNotice = "Apple Intelligence is off — inserted as spoken"
                } else {
                    hud.state.phase = .polishing
                    if let built = await rewriter.build(from: template, input: input) {
                        cleaned = built
                    } else {
                        cleaned = input
                        failureNotice = "\(template.title) failed — inserted as spoken"
                    }
                }
            }
            // 2. Explicit command prefix ("//prompt …", "//better …"). With no
            //    payload it targets the current selection.
            else if AppSettings.shared.aiCommandsEnabled,
                    let command = CommandDetector.detect(in: cleaned),
                    command.wasExplicit {
                let payload = command.payload.isEmpty ? (selectionAtStart ?? "") : command.payload
                if payload.isEmpty {
                    failureNotice = "Nothing to work on — say the text after the command"
                } else if !LocalRewriter.isAvailable {
                    cleaned = payload
                    failureNotice = "Apple Intelligence is off — inserted as spoken"
                } else if let selection = selectionAtStart,
                          !command.payload.isEmpty,
                          CommandDetector.selectionInstruction(in: command.payload) != nil {
                    // "//better — make it shorter" with text selected: the
                    // payload is the instruction, the selection is the subject.
                    hud.state.phase = .polishing
                    if let transformed = await rewriter.transform(
                        selection: selection,
                        instruction: command.payload
                    ) {
                        cleaned = transformed
                    } else {
                        hud.state.phase = .error("Rewrite failed — selection left unchanged")
                        hideHUDAfterDelay(seconds: 3)
                        state = .idle
                        return
                    }
                } else {
                    hud.state.phase = .polishing
                    let resolved = DictationCommand(
                        kind: command.kind,
                        payload: payload,
                        wasExplicit: true
                    )
                    if let rewritten = await rewriter.rewrite(resolved) {
                        cleaned = rewritten
                    } else {
                        // Never lose the words: insert the payload and say so.
                        cleaned = payload
                        failureNotice = "Rewrite failed — inserted as spoken"
                    }
                }
            }
            // 3. Selection instruction ("make this more organized") with a
            //    selection present — transform the SELECTION, not the speech.
            else if AppSettings.shared.aiCommandsEnabled,
                    LocalRewriter.isAvailable,
                    let selection = selectionAtStart,
                    let instruction = CommandDetector.selectionInstruction(in: cleaned) {
                hud.state.phase = .polishing
                if let transformed = await rewriter.transform(selection: selection, instruction: instruction) {
                    cleaned = transformed
                } else {
                    // Leave the user's selection untouched rather than
                    // overwriting it with the spoken instruction.
                    hud.state.phase = .error("Rewrite failed — selection left unchanged")
                    hideHUDAfterDelay(seconds: 3)
                    state = .idle
                    return
                }
            }
            // 4. Natural-language command ("make this message better, …").
            else if AppSettings.shared.aiCommandsEnabled,
                    LocalRewriter.isAvailable,
                    let command = CommandDetector.detect(in: cleaned) {
                hud.state.phase = .polishing
                if let rewritten = await rewriter.rewrite(command) {
                    cleaned = rewritten
                } else {
                    cleaned = command.payload
                    failureNotice = "Rewrite failed — inserted as spoken"
                }
            }
            // 5. Spoken self-corrections ("…at 5, no wait, 6").
            else if AppSettings.shared.aiCommandsEnabled,
                    LocalRewriter.isAvailable,
                    SelfCorrection.hasMarkers(cleaned) {
                hud.state.phase = .polishing
                cleaned = await rewriter.resolveCorrections(in: cleaned) ?? cleaned
            }

            if let failureNotice, cleaned.isEmpty {
                hud.state.phase = .error(failureNotice)
                hideHUDAfterDelay(seconds: 3)
                state = .idle
                return
            }

            let outcome = await injector.inject(cleaned, method: AppSettings.shared.insertionMethod)
            if AppSettings.shared.saveHistory {
                HistoryStore.shared.add(
                    text: cleaned,
                    duration: ProcessInfo.processInfo.systemUptime - sessionStartedAt,
                    appName: targetAppName
                )
            }
            // Watch for hand corrections to this text and learn the words.
            learner.noteInsertion(of: cleaned)

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
            NSLog("Waveform: finish failed: \(error)")
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
