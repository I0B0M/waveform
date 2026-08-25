# Waveform — what to fix, in order

Updated 25 Aug 2026 (evening). Build clean, **95 tests / 15 suites pass**. Verify after every task with:

```bash
swift build && swift run waveform-tests
```

(`swift test` runs zero tests here — always use the executable runner.)

---

## Done — verified in the code, not just the commit message

- [x] **✨ button no longer arms the next dictation.** `forcedCommand` is
  consumed once at `DictationCoordinator.swift:195–196`; the ✨ flag is also
  passed into the planner as data (`DictationContext.forced`) so it cannot
  outlive one dictation at all.
- [x] **Finalize timeout salvages the words.** `AppleSpeechEngine.swift:160–167`
  catches `TimeoutError`, returns the mirrored `finalizedSoFar` text, and still
  rethrows when there is nothing to salvage.
- [x] **Audio route change mid-dictation.** `AudioCaptureService.swift:44–49`
  observes `.AVAudioEngineConfigurationChange` and rebuilds the tap; the
  observer is removed in `stop()`.
- [x] **README roadmap fixed.** Shipped features are now documented as shipped.
- [x] **Interpretation ladder is testable** — done better than planned: instead
  of injecting collaborators, the six-branch decision moved into a pure
  `DictationPlanner` (`DictationPlanner.swift`) with `DictationPlannerTests`
  covering the ordering rules.
- [x] **User-defined commands** — shipped as the **Prompt Library**: editable
  templates with spoken `//trigger`s, four shipped defaults, a Prompts tab,
  planner branch 2, `CommandDetector.templateCommand`. One gap remains → task 1
  below.
- [x] **Dictionary auto-learn** — `CorrectionLearner` + `WordDiff` (tested):
  watches the field after insertion, learns 1:1 word substitutions.
- [x] **Template triggers fed to the recognizer** — `composeRecognitionHints`
  (pure, tested, mutation-checked): "slash <trigger>" hints for every prompt
  template, ordered so a huge dictionary can never evict command hints.
- [x] **fn hotkey** — tap to toggle, hold 2+ s for push-to-talk; default
  preset; menu-bar one-click fix for the macOS Globe/emoji conflict.
- [x] **Undo Last Insertion** — menu-bar item; AX-verified (field must still
  end with the inserted text in the same app; 15 s window; never blind-fires).
- [x] **The five pill-lab HUD upgrades** — jump-free transcript strip,
  190→340 pill with asymmetric springs + snap zones, semantic ribbons,
  stop choreography (flatten → shimmer → receipt), caret dot.

## Still open — next tier, in rough value order

- **Health tab** in the dashboard: last ten insertions with method + outcome,
  rewrite rejections with reason, live permission state.
- **Incognito + app blocklist**: "pause history 30 min" and "never activate in
  these apps"; history is plaintext JSON.
- **Language picker**: locale still fixed to `Locale.current` at
  `AppleSpeechEngine.init`.
- **Auto-update**: the DMG has no update path.
- **Guided first run**: permissions flow with a live test field — Accessibility
  vs Input Monitoring confusion is now the #1 observed support issue.
- **Smarter snippets**: exact-match only; add contains-matching +
  `{date}`/`{clipboard}` tokens.
- **Per-app tone**: a per-app default prompt template (Slack casual, Mail
  formal) — cheap now that the Prompt Library exists.
