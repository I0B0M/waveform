# Discotype

Local-first dictation for macOS 26 with a retro-futuristic neon HUD.

**⌘X → HUD appears, recording starts → speak → live transcription → ⌘X → cleaned text lands at your cursor** — in Slack, VS Code, a browser field, Notes, anywhere.

Everything runs on-device: Apple's macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` model transcribes locally, cleanup is rule-based, and no audio, text, or clipboard data ever leaves the Mac. While idle the app holds no audio hardware, no timers, and no event taps — effectively zero CPU/battery cost.

## Build & run

Requires macOS 26 and Command Line Tools (no Xcode needed).

```bash
Scripts/build-app.sh            # → build/Discotype.app (release, ad-hoc signed)
open build/Discotype.app
```

First run:
1. Press the hotkey once — macOS asks for **Microphone** (transcription) and **Accessibility** (inserting text into other apps). Grant both; Accessibility requires a manual toggle in System Settings → Privacy & Security.
2. The first dictation may download the on-device speech model (one-time, system-managed, shared across apps).

Menu bar icon (waveform + mic) → Settings for hotkey choice, filler-word removal, and insertion method.

### Signing note (important for daily use)

Ad-hoc signatures change identity on every rebuild, so macOS forgets the Microphone/Accessibility grants each time you rebuild. One-time fix: create a self-signed code-signing certificate (Keychain Access → Certificate Assistant → Create a Certificate… → type **Code Signing**, name it e.g. `Discotype Dev`), then:

```bash
CODESIGN_IDENTITY="Discotype Dev" Scripts/build-app.sh
```

Grants then survive rebuilds. If TCC entries ever get stale: `tccutil reset Accessibility com.ibrahim.discotype`.

### ⌘X and Cut

The hotkey is registered with Carbon `RegisterEventHotKey`, which consumes the keystroke — so while Discotype runs, **⌘X no longer performs Cut in any app**. That is the intended toggle behavior; pick ⌥Space, ⌃⌥D, or F19 in Settings if you want Cut back.

## Verification harnesses

```bash
swift run discotype-tests                     # unit tests (TextCleaner)
.build/debug/Discotype --selftest             # headless end-to-end: `say` → SpeechAnalyzer → cleanup
.build/debug/Discotype --render-hud hud.png   # render the HUD to a PNG for design review
```

(`swift test` is a no-op under Command Line Tools — it silently runs zero swift-testing tests, hence the executable runner.)

## Architecture

```
Sources/Discotype/            thin executable (main.swift, CLI flags)
Sources/DiscotypeCore/
  Hotkey/HotkeyManager        Carbon RegisterEventHotKey — no permissions, consumes the key
  Audio/AudioCaptureService   AVAudioEngine tap → AVAudioConverter → engine format; throttled RMS levels
  Transcription/
    TranscriptionEngine       protocol seam — swap the backend without touching anything else
    AppleSpeechEngine         SpeechAnalyzer + SpeechTranscriber (.progressiveTranscription, volatile results)
  Cleanup/TextCleaner         conservative rules: fillers, repeats, whitespace, caps, terminal punctuation
  Injection/TextInjector      AX insert (verified) → ⌘V paste (clipboard snapshot/restore, change-count guarded)
                              → unicode typing fallback; transient pasteboard marker for clipboard managers
  HUD/                        non-activating NSPanel (never steals focus), SwiftUI neon waveform
  Settings/                   UserDefaults-backed; hotkey, fillers, insertion method
  App/DictationCoordinator    idle → recording → finishing state machine
```

Design decisions and trade-offs are commented at the top of each file.

## V1 scope

Included: global toggle hotkey, live on-device transcription, cleanup, injection into the focused app, reactive HUD, settings, headless self-tests.

Deliberately deferred: personal dictionary (hook exists — `AnalysisContext.contextualStrings`), history, voice commands ("new paragraph"), multi-language switching, FoundationModels-based cleanup, context-aware formatting per app, launch-at-login.
