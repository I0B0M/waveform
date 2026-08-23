import SwiftUI

struct SettingsView: View {
    var onHotkeyChange: () -> Void

    @State private var hotkeyPreset: HotkeyPreset = AppSettings.shared.hotkeyPreset
    @State private var removeFillers: Bool = AppSettings.shared.removeFillers
    @State private var insertionMethod: TextInjector.Method = AppSettings.shared.insertionMethod
    @State private var silenceTimeout: Double = AppSettings.shared.silenceTimeout
    @State private var aiCommandsEnabled: Bool = AppSettings.shared.aiCommandsEnabled
    @State private var contextAwareStyle: Bool = AppSettings.shared.contextAwareStyle


    private static let silenceChoices: [(label: String, value: Double)] = [
        ("Off (manual only)", 0), ("1.5 seconds", 1.5), ("2 seconds", 2),
        ("2.5 seconds", 2.5), ("3 seconds", 3), ("4 seconds", 4), ("5 seconds", 5),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Toggle hotkey", selection: $hotkeyPreset) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: hotkeyPreset) { _, newValue in
                    AppSettings.shared.hotkeyPreset = newValue
                    if newValue.isBareModifier {
                        // Modifier watching only works once Accessibility is
                        // granted — surface the prompt right away.
                        _ = TextInjector.isTrusted(promptIfNeeded: true)
                    }
                    onHotkeyChange()
                }

                if hotkeyPreset == .commandX {
                    Text("Heads-up: while Waveform is running, ⌘X starts/stops dictation everywhere — it no longer performs Cut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if hotkeyPreset == .controlDoubleTap {
                    Text("Tap Control twice quickly (nothing else pressed). Needs the Accessibility permission — the same one used for inserting text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Auto-stop after silence", selection: $silenceTimeout) {
                    ForEach(Self.silenceChoices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .onChange(of: silenceTimeout) { _, newValue in
                    AppSettings.shared.silenceTimeout = newValue
                }
                Text("Dictation ends on its own once you've spoken and then stayed quiet this long. Brief pauses between sentences don't count. The hotkey always stops immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Context-aware style", isOn: $contextAwareStyle)
                    .onChange(of: contextAwareStyle) { _, newValue in
                        AppSettings.shared.contextAwareStyle = newValue
                    }
                Text("No trailing period in Slack/Discord/Messages; no auto-capitalization or punctuation in editors and terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Remove filler words (um, uh, …)", isOn: $removeFillers)
                    .onChange(of: removeFillers) { _, newValue in
                        AppSettings.shared.removeFillers = newValue
                    }
            }

            Section {
                Picker("Insert text by", selection: $insertionMethod) {
                    ForEach(TextInjector.Method.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .onChange(of: insertionMethod) { _, newValue in
                    AppSettings.shared.insertionMethod = newValue
                }
                Text("If dictated text ever fails to appear, switch to “Type characters directly”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("AI commands (on-device Apple Intelligence)", isOn: $aiCommandsEnabled)
                    .onChange(of: aiCommandsEnabled) { _, newValue in
                        AppSettings.shared.aiCommandsEnabled = newValue
                    }
                Text("Start a dictation with “make this better, …” or “create a prompt, …” and the rest gets restructured by Apple's local model before inserting. Nothing goes to the cloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Changes save automatically — there is no Save button. Everything runs on-device; audio and text never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
