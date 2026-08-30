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
    private let caretDot = CaretDotController()
    private let streamer = StreamingInserter()

    private var enginePrepared = false
    private var prepareFailure: String?
    private var promptedAccessibility = false

    // Per-session context.
    private var sessionStartedAt: TimeInterval = 0
    private var selectionAtStart: String?
    /// What surrounds the caret at dictation start — read on-device via AX,
    /// used for grounding and tone, discarded with the session.
    private var fieldContext: FieldContext?
    /// The focused element at dictation start — where the text will land,
    /// even if the user is reading another window when they stop.
    private var anchorElement: AXUIElement?
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

    private var prepareTask: Task<Void, Never>?

    func prepareEngine() async {
        if let prepareTask {
            // Launch warm-up and a first hotkey press can race here; the
            // second caller must wait, not start a second model download.
            await prepareTask.value
            return
        }
        let task = Task { await self.performPrepare() }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    private func performPrepare() async {
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
        case .recording, .starting:
            requestStop()
        case .finishing:
            pendingStartRequested = true
        }
    }

    // MARK: - fn press gestures

    /// Holding fn past this long makes the press push-to-talk: release stops
    /// and inserts. A quicker press is a tap: recording keeps going until the
    /// next tap (or silence auto-stop).
    private static let pushToTalkThreshold: TimeInterval = 2.0

    /// True while the CURRENT fn press is the one that started this session.
    private var sessionStartedByPress = false
    /// True while the current fn press landed during an active session (a
    /// second tap) — its release stops, regardless of how long it was held.
    private var pressArmsStop = false
    /// A stop that arrived while the session was still STARTING. `start()`
    /// can take seconds on a cold launch — a push-to-talk release or second
    /// tap in that window must stop the session the moment it's up, not be
    /// silently discarded (which reads as "the hotkey is dead").
    private var pendingStopRequested = false
    /// A start that arrived during .finishing (the model rewrite can run for
    /// seconds) — begins the moment the pipeline is idle, instead of being
    /// silently swallowed as a dead-feeling hotkey press.
    private var pendingStartRequested = false

    /// Stop now if possible; if the session is still starting, arm the stop
    /// to fire the moment it finishes coming up.
    private func requestStop() {
        switch state {
        case .recording:
            Task { await stop() }
        case .starting:
            pendingStopRequested = true
        case .idle, .finishing:
            break
        }
    }

    /// The fn preset reports raw presses; resolve them against real session
    /// state here, because only the coordinator knows whether the session the
    /// press started is still running (silence auto-stop may have ended it).
    func handleGesture(_ gesture: HotkeyGesture) {
        switch gesture {
        case .toggle:
            toggle()

        case .pressBegan:
            // Recording starts on the DOWN edge, so push-to-talk hears the
            // first word of the hold — nothing is lost deciding tap vs hold.
            switch state {
            case .idle:
                sessionStartedByPress = true
                pressArmsStop = false
                Task { await start() }
            case .recording:
                pressArmsStop = true
            case .starting:
                // A second tap while the first is still spinning up: its
                // release should stop, same as if the session were live.
                if !sessionStartedByPress { pressArmsStop = true }
            case .finishing:
                pendingStartRequested = true
            }

        case .pressEnded(let held):
            if pressArmsStop {
                // Second tap of a toggle: release always stops.
                pressArmsStop = false
                requestStop()
            } else if sessionStartedByPress {
                sessionStartedByPress = false
                if held >= Self.pushToTalkThreshold {
                    // Push-to-talk: they held fn while speaking; letting go
                    // is the whole gesture — even if startup hasn't finished.
                    requestStop()
                }
                // A quick tap: leave the session running (toggle mode).
            }

        case .pressCancelled:
            // The press turned out to be a keyboard chord (fn+arrow, fn+
            // delete). If that chord is what started this session, the user
            // never meant to dictate — discard it. A chord during a session
            // someone started earlier is just typing; ignore it.
            pressArmsStop = false
            if sessionStartedByPress {
                sessionStartedByPress = false
                Task { await cancelDictation() }
            }
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
        // Context awareness, the on-device way: read what surrounds the caret
        // now; it grounds recognition below and tones rewrites later. Secure
        // fields come back empty by construction.
        fieldContext = AppSettings.shared.contextAwarenessEnabled
            ? injector.readFieldContext()
            : nil
        // The insertion anchor: the exact element holding the caret right
        // now. Captured independently of the context toggle — it's where the
        // text lands, not what the model reads. Never anchor to a secure
        // field.
        anchorElement = fieldContext?.isSecure == true
            ? nil
            : injector.captureFocusedElement()
        sessionStartedAt = ProcessInfo.processInfo.systemUptime

        hudGeneration += 1
        hud.show()
        let hudState = hud.state
        sawSpeech = false
        lastVoiceActivityAt = ProcessInfo.processInfo.systemUptime

        do {
            // Bias recognition toward the command words too — without this the
            // recognizer hears "prompt" as "prom" and the command silently
            // looks like ordinary speech.
            // Dictionary + terms learned from corrections + the command words.
            // Ground recognition in the conversation itself: names and jargon
            // visible around the caret are exactly the words about to be
            // spoken ("reply to Aqeeb about the NestJS branch").
            var hints = AppSettings.shared.recognitionHints
            if let fieldContext, !fieldContext.isSecure {
                let contextHints = ContextHints.extract(
                    from: fieldContext.before + " " + fieldContext.after
                )
                hints = Array((contextHints + hints).prefix(150))
            }
            try await engine.startSession(contextualStrings: hints) { update in
                Task { @MainActor [weak self] in
                    if update.display != hudState.transcript {
                        hudState.applyTranscript(
                            finalized: update.finalized,
                            volatile: update.volatile
                        )
                        if let self, self.streamer.isActive {
                            var live = update.display
                            if let context = self.fieldContext, !context.before.isEmpty {
                                live = TextCleaner.fitContinuation(live, after: context.before)
                            }
                            self.streamer.update(live)
                        }
                        // The recognizer producing new text is the strongest
                        // "still speaking" signal there is — and it drives
                        // the cyan "understanding" ribbon.
                        if let self, !update.display.isEmpty {
                            hudState.noteRecognition()
                            self.sawSpeech = true
                            self.lastVoiceActivityAt = ProcessInfo.processInfo.systemUptime
                        }
                    }
                }
            }

            // A cancel (fn chord, HUD ✕) may have landed while we were
            // suspended above — resurrecting the session here would leave an
            // invisible recording with no HUD. Check before touching audio.
            guard state == .starting else {
                await engine.cancelSession()
                hud.hide()
                return
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
            guard state == .starting else {
                await engine.cancelSession()
                hud.hide()
                return
            }
            try audio.start(targetFormat: format)
            state = .recording
            // Live streaming: words land at the caret as they're recognized.
            // begin() failing just means this field can't take verified live
            // writes — the classic insert-at-stop path takes over untouched.
            if AppSettings.shared.streamingEnabled,
               fieldContext?.isSecure != true,
               let anchorElement {
                if streamer.begin(element: anchorElement) {
                    Log.injection.notice("streaming session started")
                }
            }
            caretDot.show { [injector] in injector.caretScreenRect() }
            startSilenceWatchdog()
            if pendingStopRequested {
                // A push-to-talk release or second tap arrived during the
                // spin-up: honor it now that there is a session to stop.
                pendingStopRequested = false
                Task { await stop() }
            }
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
        pendingStopRequested = false
        caretDot.hide()
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
                streamer.abort()
                hud.hide()
                state = .idle
                return
            }

            // One context block for every model call this session: where the
            // text is going, the tone dial, and the learned style card.
            let tone: String?
            switch AppSettings.shared.toneStyle {
            case .casual: tone = "casual"
            case .formal: tone = "formal"
            case .auto:
                // Directly from the app category — independent of the
                // punctuation-style toggle, or Auto would be silently inert.
                tone = AppStyle.cleanStyle(forBundleId: targetBundleId) == .chat
                    ? "casual, chat-appropriate" : nil
            }
            let rewriteContext = LocalRewriter.contextBlock(
                field: fieldContext,
                tone: tone,
                styleCard: AppSettings.shared.styleLearningEnabled
                    ? AppSettings.shared.styleCard : ""
            )

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
            var finalText: String

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
                if let rewritten = await rewriter.rewrite(command, context: rewriteContext) {
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
                if let built = await rewriter.build(from: template, input: input, context: rewriteContext) {
                    finalText = built
                } else {
                    finalText = fallback
                    failureNotice = "\(template.title) failed — inserted as spoken"
                }

            case .transformSelection(let selection, let instruction):
                hud.state.phase = .polishing
                guard let transformed = await rewriter.transform(
                    selection: selection,
                    instruction: instruction,
                    context: rewriteContext
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

            // Fit onto the caret: mid-sentence, the utterance-initial capital
            // is wrong and the joining space is missing — fix both. Only when
            // the final cursor is still in the app the context was read from;
            // after a deliberate app switch the text stands alone.
            if let fieldContext, !fieldContext.isSecure, !fieldContext.before.isEmpty,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleId {
                finalText = TextCleaner.fitContinuation(
                    finalText,
                    after: fieldContext.before,
                    following: fieldContext.after
                )
            }

            // Streamed sessions finish with one in-place replace of the live
            // text; a frozen stream (the user typed mid-dictation) must never
            // be topped with a second, duplicate insert — the clipboard pill
            // is the honest fallback there.
            let outcome: TextInjector.Outcome
            let streamedSomething = streamer.hasStreamedText
            if streamer.isActive || streamedSomething {
                injector.copyToClipboard(finalText)
                if streamer.finish(with: finalText) {
                    Log.injection.notice("streamed session finished in place (\(finalText.count, privacy: .public) chars)")
                    outcome = .insertedDirectly
                } else if streamedSomething {
                    Log.injection.error("stream frozen mid-session — final text on the clipboard")
                    outcome = .copiedFocusLost
                } else {
                    outcome = await injector.inject(
                        finalText,
                        method: AppSettings.shared.insertionMethod,
                        targetBundleId: targetBundleId,
                        anchor: anchorElement,
                        expectedBeforeSuffix: fieldContext?.before ?? ""
                    )
                }
            } else {
                outcome = await injector.inject(
                    finalText,
                    method: AppSettings.shared.insertionMethod,
                    targetBundleId: targetBundleId,
                    anchor: anchorElement,
                    expectedBeforeSuffix: fieldContext?.before ?? ""
                )
            }
            anchorElement = nil
            // Two independent secure signals gate persistence: the AX subrole
            // read at start, AND the injector's live IsSecureEventInputEnabled
            // check — the app must never store a password it visibly refused
            // to type.
            let dictatedIntoSecureField = fieldContext?.isSecure == true
                || outcome == .copiedSecureInput
            if AppSettings.shared.saveHistory, !dictatedIntoSecureField {
                HistoryStore.shared.add(
                    text: finalText,
                    duration: ProcessInfo.processInfo.systemUptime - sessionStartedAt,
                    appName: targetAppName
                )
            }

            // Watch for hand corrections to this text and learn the words —
            // never around secure fields.
            if !dictatedIntoSecureField {
                learner.noteInsertion(of: finalText)
            }

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
            case .copiedFocusLost:
                hud.state.phase = .error("App changed — copied, press ⌘V")
                hideHUDAfterDelay(seconds: 3)
            case .copiedSecureInput:
                hud.state.phase = .error("Secure field — copied, press ⌘V")
                hideHUDAfterDelay(seconds: 3)
            case .copiedNoField:
                hud.state.phase = .error("No text field — copied, press ⌘V")
                hideHUDAfterDelay(seconds: 3)
            }
        } catch {
            streamer.abort()
            await engine.cancelSession()
            hud.state.phase = .error("Transcription failed")
            Log.app.error("finish failed: \(String(describing: error), privacy: .public)")
            hideHUDAfterDelay()
        }
        state = .idle
        if pendingStartRequested {
            pendingStartRequested = false
            Task { await start() }
        }
    }

    /// ✨ on the HUD: stop, then run the words through the on-device model
    /// before inserting. Removes any dependence on the command being *heard*.
    func finishWithPolish(_ kind: DictationCommand.Kind) {
        guard state == .recording else { return }
        forcedCommand = kind
        Task { await stop() }
    }

    /// Menu bar: take back the last insertion, with the outcome shown on the
    /// HUD either way — a silent undo is as untrustworthy as no undo.
    func undoLastInsertion() {
        guard state == .idle else { return }
        switch injector.undoLastInsertion() {
        case .undone:
            learner.cancelPending()
            hud.show()
            hud.state.phase = .notice("Undone")
            hideHUDAfterDelay(seconds: 1.5)
        case .nothingToUndo:
            showTransientError("Nothing to undo")
        case .fieldChanged:
            showTransientError("Can't undo — the text changed")
        }
    }

    /// ✕ on the HUD: throw the session away — nothing is inserted.
    func cancelDictation() async {
        guard state == .recording || state == .starting else { return }
        state = .finishing
        forcedCommand = nil
        pendingStopRequested = false
        pendingStartRequested = false
        sessionStartedByPress = false
        pressArmsStop = false
        streamer.abort()
        caretDot.hide()
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

    /// Bumped every time the HUD is shown for a new session, so a stale
    /// delayed hide from a previous session's error pill can never fade out
    /// the HUD of a dictation that is currently live.
    private var hudGeneration = 0

    private func hideHUDAfterDelay(seconds: TimeInterval = 2) {
        let generation = hudGeneration
        Task { [hud, weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self?.hudGeneration == generation else { return }
            hud.hide()
        }
    }
}
