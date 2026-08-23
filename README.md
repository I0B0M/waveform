<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Waveform app icon">

# Waveform

**Local-first dictation for macOS 26.** Speak anywhere, get clean text at your cursor.
Transcription, cleanup, and AI rewriting all run **on-device** — no cloud, no account,
no audio ever leaves your Mac.

</div>

**Flow:** hotkey → HUD appears → speak → live transcription → stop talking (it
auto-stops after silence) → cleaned text lands wherever your cursor is: Slack,
VS Code, a browser field, Notes, anywhere.

The HUD starts small and grows once it has words. It never takes focus from the
app you're typing into, and you can drag it anywhere — it remembers where.

<img src="docs/images/hud-compact.png" width="420" alt="Compact HUD: waveform only">

<img src="docs/images/hud-listening.png" width="560" alt="Expanded HUD with live transcript and controls">

Settled words are bright, the still-changing tail is dimmed, so you can watch the
recognizer commit as you speak. On the pill: **✕** discard · **✨** organize the
text first (⌥-click builds a prompt) · **✓** insert exactly as spoken.

## Install

**Just want to use it?** Get `Waveform-<version>.dmg`, drag the app to
Applications, then **right-click it → Open** the first time. That right-click is
required because this build is signed with a locally-generated certificate
rather than a paid Apple Developer ID; macOS shows a warning it won't show
again. Then press the hotkey once and grant **Microphone** and **Accessibility**.

**Building it yourself** requires **macOS 26** on Apple silicon and Xcode
**Command Line Tools** (`xcode-select --install`). No Xcode needed.

```bash
git clone <repo-url> && cd Waveform
INSTALL=1 Scripts/build-app.sh     # also copies to /Applications
open /Applications/Waveform.app
```

Drop `INSTALL=1` to keep it local (`open build/Waveform.app`). Once a copy
exists in /Applications, later builds sync it automatically — two copies of a
menu-bar app is a foot-gun, since you'd fix something and then launch the stale
one.

The build script creates a local "Waveform Dev" signing certificate on first run (so macOS permission grants survive rebuilds — without it, every rebuild looks like a new app and permissions silently reset).

First launch:
1. Press the hotkey once (default **⌘X** — yes, it replaces Cut; change it in Settings).
2. Grant **Microphone** when prompted.
3. Grant **Accessibility** (System Settings opens — toggle Waveform ON). Needed to insert text into other apps and for the double-tap-Control hotkey.
4. The first dictation may download the on-device speech model once (system-managed).

The menu-bar icon (waveform + mic) shows **live permission status** — if something isn't working, look there first: ✗ rows are clickable and open the right settings pane.

## The app window

Open Waveform (Applications, Spotlight, or the Dock) and the dashboard comes up;
the menu-bar icon → **Open Waveform…** does the same at any time. While the
window is open the app shows a Dock icon; close it and Waveform drops back to
being just a menu-bar icon. Launching at login does *not* pop the window.

<img src="docs/images/dashboard-home.png" width="720" alt="Home: stats, top apps, recent dictations">

Everything is local: the stats and history come from a capped file on your own
Mac, and clearing it means clearing it.

<img src="docs/images/dashboard-snippets.png" width="720" alt="Voice snippets tab">

<img src="docs/images/dashboard-settings.png" width="720" alt="Settings">

## Using it

- **Start/stop**: your hotkey (Settings offers ⌘X, ⌥Space, ⌃⌥D, F19, or **double-tap Control**). Dictation also **auto-stops** after ~2.5s of silence once you've spoken (configurable / off).
- **The ✨ button** (most reliable): while the HUD is up, press ✨ instead of ✓ — your words get organized by the on-device model, then inserted. ⌥-click it to build a prompt instead of tidying a message. No speech recognition involved, so it can't be misheard.
- **AI commands** (on-device, free — requires Apple Intelligence enabled). Say a `//command` at the start and then ramble; the local model restructures everything after it:
  - **"double slash prompt"** — turns your ramble into a clean, organized prompt to paste into Claude/ChatGPT
  - **"double slash better"** (also `organize`, `structure`, `professional`, `shorter`, `concise`) — tidies a message
  - Say the command with **nothing after it** while text is selected, and it rewrites the selection in place
  - Natural phrasing ("make this message better, …") still works, but the `//command` form never misfires
  If the model is unavailable or the rewrite fails a sanity check, your words are inserted as spoken and the HUD says why — it can never silently do nothing.
- **Personal dictionary** (Settings): one term per line — names, jargon, acronyms. Biases recognition from the next dictation.
- **Filler removal**: "um okay so basically…" → "Okay, so basically…". Toggleable.
- All settings save automatically — there is no Save button.

## Sharing a build

```bash
Scripts/release.sh        # → dist/Waveform-<version>.dmg
```

The disk image holds the app, an Applications shortcut, and setup notes.
Recipients need nothing installed. To drop the first-launch warning entirely,
sign with a real Apple Developer ID and notarize — no code changes required.

## Icon

The app mark — an audio waveform built from disco-ball mirror facets — is drawn
in code (`Sources/WaveformCore/Branding/DiscoIconView.swift`), not shipped as
bitmaps, so it stays crisp at every size. `Scripts/build-app.sh` regenerates
`Support/AppIcon.icns` automatically whenever that drawing changes.

```bash
.build/debug/Waveform --render-icon icon.png 1024   # preview one size
.build/debug/Waveform --export-iconset out.iconset  # all macOS sizes
.build/debug/Waveform --render-docs docs/images     # regenerate README images
.build/debug/Waveform --render-social docs/social-preview.png   # GitHub card
```

The GitHub social-preview card (`docs/social-preview.jpg`, 1280×640) is drawn
from the same mark. GitHub has no API for it — upload it under
**Settings → General → Social preview**.

The README images are generated by the app itself with **demo data**, so
screenshots stay current after a UI change and never contain real dictation
history.

## Verification harnesses (no permissions needed)

```bash
swift run waveform-tests                      # unit tests
/usr/bin/log show --last 5m --predicate 'subsystem == "com.ibrahim.waveform"'  # what a running copy is doing
.build/debug/Waveform --selftest              # end-to-end: say → SpeechAnalyzer → cleanup, with timings
.build/debug/Waveform --fm-check              # is the on-device LLM available?
.build/debug/Waveform --render-hud out.png    # render the HUD for design review
.build/debug/Waveform --render-settings out.png
```

(`swift test` runs zero tests under Command Line Tools — hence the executable runner.)

## Architecture

```
Sources/Waveform/            thin executable (main.swift, CLI flags)
Sources/WaveformCore/
  Hotkey/                     Carbon hotkey (combos) + CGEventTap on a dedicated
                              thread (bare-modifier double-tap), pure tested detector
  Audio/                      AVAudioEngine tap → converter → engine format; throttled levels
  Transcription/              TranscriptionEngine seam; AppleSpeechEngine
                              (SpeechAnalyzer, volatile+fast results, model kept hot,
                              contextual-strings dictionary bias)
  Cleanup/TextCleaner         conservative rules — never rephrases
  AICommands/                 CommandDetector (pure, tested) + LocalRewriter
                              (FoundationModels, guarded: timeout, preamble & length checks)
  Injection/TextInjector      AX insert (verified) → unicode typing; ⌘V as explicit option;
                              clipboard snapshot/restore, change-count guarded
  HUD/                        non-activating NSPanel (never steals focus), neon Canvas waveform
  Settings/                   UserDefaults-backed, save-on-change
  App/DictationCoordinator    state machine + silence watchdog
```

Idle cost is ~zero: no audio engine, no timers, no animation while not dictating. The one exception: the double-tap-Control preset keeps a listen-only event tap alive (microseconds per keystroke).

## Roadmap (from studying Wispr Flow — all locally feasible)

Self-correction resolution ("…at 5, no wait, 6pm" → "6pm") · per-app formatting (Slack casual / email formal / code mode) · command mode on selected text ("make this formal") · voice snippets ("insert my calendar link") · dictionary auto-learn from your corrections · history & scratchpad · multilingual picker. Notably: Wispr has **no offline mode at all** — this app's fully local pipeline is the point.
