import SwiftUI

struct SettingsView: View {
    var onHotkeyChange: () -> Void

    @State private var hotkeyPreset: HotkeyPreset = AppSettings.shared.hotkeyPreset
    @State private var removeFillers: Bool = AppSettings.shared.removeFillers
    @State private var insertionMethod: TextInjector.Method = AppSettings.shared.insertionMethod

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
                    Text("Heads-up: while Discotype is running, ⌘X starts/stops dictation everywhere — it no longer performs Cut.")
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
                Text("Everything runs on-device. Audio and text never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
