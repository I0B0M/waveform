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

    private var enginePrepared = false
    private var prepareFailure: String?

    var engineStatusLine: String? {
        if enginePrepared { return nil }
        if let prepareFailure { return "Engine error: \(prepareFailure)" }
        return "Downloading speech model…"
    }

    // MARK: - Engine warm-up

    func prepareEngine() async {
        do {
            try await engine.prepare()
            enginePrepared = true
        } catch {
            prepareFailure = error.localizedDescription
            NSLog("Discotype: engine prepare failed: \(error)")
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

        // Microphone permission (first run prompts; the HUD would hide the dialog,
        // so ask before showing it).
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            state = .idle
            showTransientError("Microphone access denied — enable it in System Settings → Privacy.")
            return
        }

        // Nudge the Accessibility prompt on first use so injection works later.
        _ = TextInjector.isTrusted(promptIfNeeded: true)

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

        do {
            try await engine.startSession { update in
                Task { @MainActor in
                    hudState.transcript = update.display
                }
            }

            let format = await engine.preferredAudioFormat
            audio.onBuffer = { [engine] buffer in
                engine.feed(buffer)
            }
            audio.onLevel = { level in
                Task { @MainActor in
                    hudState.pushLevel(level)
                }
            }
            try audio.start(targetFormat: format)
            state = .recording
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
        hud.state.phase = .finalizing
        audio.stop()

        do {
            let raw = try await engine.finishSession()
            let cleaner = TextCleaner(removeFillers: AppSettings.shared.removeFillers)
            let cleaned = cleaner.clean(raw)

            if cleaned.isEmpty {
                hud.hide()
                state = .idle
                return
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
            NSLog("Discotype: finish failed: \(error)")
            hideHUDAfterDelay()
        }
        state = .idle
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
