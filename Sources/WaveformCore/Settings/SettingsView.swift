import SwiftUI

/// Settings, wearing the same system as every other surface: mono section
/// labels, hairline-ruled cards, captions in the quiet ink — no system Form,
/// so the tab matches the dashboard instead of the OS defaults.
struct SettingsView: View {
    var onHotkeyChange: () -> Void

    @State private var hotkeyPreset: HotkeyPreset = AppSettings.shared.hotkeyPreset
    @State private var removeFillers: Bool = AppSettings.shared.removeFillers
    @State private var insertionMethod: TextInjector.Method = AppSettings.shared.insertionMethod
    @State private var silenceTimeout: Double = AppSettings.shared.silenceTimeout
    @State private var aiCommandsEnabled: Bool = AppSettings.shared.aiCommandsEnabled
    @State private var contextAwareStyle: Bool = AppSettings.shared.contextAwareStyle
    @State private var voiceCommandsEnabled: Bool = AppSettings.shared.voiceCommandsEnabled
    @State private var toneStyle: AppSettings.ToneStyle = AppSettings.shared.toneStyle
    @State private var contextAwareness: Bool = AppSettings.shared.contextAwarenessEnabled
    @State private var styleLearning: Bool = AppSettings.shared.styleLearningEnabled
    @State private var streaming: Bool = AppSettings.shared.streamingEnabled
    @State private var finishCommands: Bool = AppSettings.shared.finishCommandsEnabled
    @State private var aiBrain: AppSettings.AIBrain = AppSettings.shared.aiBrain
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyConfigured: Bool = CloudBrain.isConfigured

    private static let silenceChoices: [(label: String, value: Double)] = [
        ("Off (manual only)", 0), ("1.5 seconds", 1.5), ("2 seconds", 2),
        ("2.5 seconds", 2.5), ("3 seconds", 3), ("4 seconds", 4), ("5 seconds", 5),
    ]

    private var hotkeyCaption: String {
        switch hotkeyPreset {
        case .fnTap:
            return "Tap fn (🌐) to start, tap again to stop — or hold it 2+ seconds to push-to-talk: release inserts immediately. Using fn as a modifier (fn+arrows, fn+delete) never triggers it. If macOS also opens the emoji picker on fn, set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing."
        case .commandX:
            return "Heads-up: while Waveform is running, ⌘X starts/stops dictation everywhere — it no longer performs Cut."
        case .controlDoubleTap:
            return "Tap Control twice quickly (nothing else pressed). Needs the Accessibility permission — the same one used for inserting text."
        default:
            return "Press once to start, again to stop."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DashboardView.ink)
                    .padding(.bottom, 4)
                Text("Changes save automatically. Everything runs on-device — audio and text never leave this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardView.ink3)
                    .padding(.bottom, 30)

                sectionLabel("HOTKEY")
                card {
                    pickerRow("Toggle hotkey", selection: $hotkeyPreset, options: HotkeyPreset.allCases, label: \.label) { newValue in
                        AppSettings.shared.hotkeyPreset = newValue
                        if newValue.isBareModifier {
                            _ = TextInjector.isTrusted(promptIfNeeded: true)
                        }
                        onHotkeyChange()
                    }
                    caption(hotkeyCaption)
                }

                sectionLabel("TIMING")
                card {
                    HStack {
                        rowTitle("Auto-stop after silence")
                        Spacer()
                        Picker("", selection: $silenceTimeout) {
                            ForEach(Self.silenceChoices, id: \.value) { choice in
                                Text(choice.label).tag(choice.value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: silenceTimeout) { _, newValue in
                            AppSettings.shared.silenceTimeout = newValue
                        }
                    }
                    caption("Dictation ends on its own once you've spoken and then stayed quiet this long. Brief pauses between sentences don't count; the hotkey always stops immediately.")
                }

                sectionLabel("INSERTION")
                card {
                    toggleRow("Stream words as you speak", isOn: $streaming) {
                        AppSettings.shared.streamingEnabled = $0
                    }
                    caption("Text appears at your cursor live while you talk, then the cleaned version replaces it in place. Fields that can't take live writes fall back to inserting when you stop.")
                    rule
                    toggleRow("Finish commands (“send it”)", isOn: $finishCommands) {
                        AppSettings.shared.finishCommandsEnabled = $0
                    }
                    caption("End a dictation with “send it” to insert AND press the app's send key (chat and mail apps), or “scratch that” to discard everything. Only counts when it's its own sentence — “please send it” mid-message is just words.")
                    rule
                    HStack {
                        rowTitle("Insert text by")
                        Spacer()
                        Picker("", selection: $insertionMethod) {
                            ForEach(TextInjector.Method.allCases) { method in
                                Text(method.label).tag(method)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: insertionMethod) { _, newValue in
                            AppSettings.shared.insertionMethod = newValue
                        }
                    }
                    caption("Every dictation is also copied to the clipboard, so ⌘V always recovers it. If text ever fails to appear, switch to “Type characters directly”.")
                }

                sectionLabel("CLEANUP")
                card {
                    toggleRow("Context-aware punctuation", isOn: $contextAwareStyle) {
                        AppSettings.shared.contextAwareStyle = $0
                    }
                    caption("No trailing period in Slack/Discord/Messages; no auto-capitalization or punctuation in editors and terminals.")
                    rule
                    toggleRow("Spoken formatting commands", isOn: $voiceCommandsEnabled) {
                        AppSettings.shared.voiceCommandsEnabled = $0
                    }
                    caption("Say “new paragraph”, “bullet point”, “comma”, “question mark”, or “delete that” and Waveform types the formatting instead of the words.")
                    rule
                    toggleRow("Remove filler words (um, uh, …)", isOn: $removeFillers) {
                        AppSettings.shared.removeFillers = $0
                    }
                }

                sectionLabel("INTELLIGENCE")
                card {
                    toggleRow("Context awareness (on-device)", isOn: $contextAwareness) {
                        AppSettings.shared.contextAwarenessEnabled = $0
                    }
                    caption("Reads the text around your cursor via Accessibility — locally, never stored, never sent — to hear names the way the conversation spells them, continue mid-sentence naturally, and match tone. Password fields are always excluded.")
                    rule
                    pickerRow("Rewrite tone", selection: $toneStyle, options: AppSettings.ToneStyle.allCases, label: \.label) { newValue in
                        AppSettings.shared.toneStyle = newValue
                    }
                    rule
                    toggleRow("Learn my writing style", isOn: $styleLearning) {
                        AppSettings.shared.styleLearningEnabled = $0
                        if !$0 {
                            AppSettings.shared.styleCard = ""
                            AppSettings.shared.styleCardUpdatedAt = 0
                        }
                    }
                    caption("Distills your local dictation history into a style profile — greetings, formality, emoji habits — that shapes AI rewrites. Built and kept on this Mac only.")
                    rule
                    toggleRow("AI commands (Apple Intelligence)", isOn: $aiCommandsEnabled) {
                        AppSettings.shared.aiCommandsEnabled = $0
                    }
                    caption("Start with “make this better, …” or say a //command and the rest is restructured by Apple's local model before inserting. Nothing goes to the cloud.")
                    rule
                    pickerRow("AI-mode brain", selection: $aiBrain, options: AppSettings.AIBrain.allCases, label: \.label) { newValue in
                        AppSettings.shared.aiBrain = newValue
                    }
                    caption("Applies to AI mode (double-tap fn) and reply-to-selection only. With your own Claude API key, those composes run on a larger model — sending TEXT only: your spoken instruction, the selection, and the context around your cursor. Audio and ordinary dictation never leave this Mac. Key is stored in the macOS Keychain.")
                    if aiBrain == .claudeAPI {
                        HStack(spacing: 8) {
                            SecureField("sk-ant-…", text: $apiKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Button(apiKeyConfigured ? "Replace" : "Save") {
                                CloudBrain.saveKey(apiKeyDraft)
                                apiKeyDraft = ""
                                apiKeyConfigured = CloudBrain.isConfigured
                            }
                            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            if apiKeyConfigured {
                                Button("Remove", role: .destructive) {
                                    CloudBrain.deleteKey()
                                    apiKeyConfigured = false
                                }
                            }
                        }
                        caption(apiKeyConfigured
                            ? "Key saved in the Keychain ✓ — AI mode composes will use the Claude API."
                            : "No key saved — composes stay on-device until one is added.")
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - The shared vocabulary

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(DashboardView.ink3)
            .padding(.bottom, 10)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardView.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.lineSoft, lineWidth: 1))
        .padding(.bottom, 28)
    }

    private var rule: some View {
        DashboardView.lineSoft.frame(height: 1).padding(.vertical, 4)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DashboardView.ink)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineSpacing(2)
            .foregroundStyle(DashboardView.ink3)
    }

    private func toggleRow(
        _ title: String,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            rowTitle(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DashboardView.violet)
                .onChange(of: isOn.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
    }

    private func pickerRow<Option: Hashable & Identifiable>(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        label: KeyPath<Option, String>,
        onChange: @escaping (Option) -> Void
    ) -> some View {
        HStack {
            rowTitle(title)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(option[keyPath: label]).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: selection.wrappedValue) { _, newValue in
                onChange(newValue)
            }
        }
    }
}
