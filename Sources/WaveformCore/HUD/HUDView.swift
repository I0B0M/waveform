import SwiftUI

/// The floating pill, Wispr-style: while dictating it shows ONLY the moving
/// waveform (plus the three small controls) — no live transcript. The words
/// belong at the cursor, not in the pill; the ribbons' movement answers "is
/// it hearing me / understanding me". Text appears in the pill only for
/// states that need words: errors, "copied — press ⌘V", "undone".
/// Draggable anywhere on its body; never steals focus.
struct HUDView: View {
    @ObservedObject var state: HUDState
    var onFinish: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// Finish, but run the text through the on-device model first.
    /// `promptMode` (⌥-click) builds a prompt instead of tidying a message.
    var onPolish: ((_ promptMode: Bool) -> Void)? = nil
    /// Fixed time for deterministic offscreen snapshots.
    var frozenTime: Double? = nil

    private static let orange = Color(red: 1.00, green: 0.45, blue: 0.10)
    private static let violet = Color(red: 0.72, green: 0.20, blue: 1.00)
    private static let cyan = Color(red: 0.16, green: 0.85, blue: 1.00)
    private static let pink = Color(red: 1.00, green: 0.18, blue: 0.57)

    private var statusText: String {
        switch state.phase {
        case .listening: return "LISTENING"
        case .finalizing: return "FINALIZING"
        case .polishing: return "POLISHING"
        case .noAccessibility: return "NO ACCESS — COPIED, ⌘V"
        case .notice(let message): return message.uppercased()
        case .error(let message): return message.uppercased()
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .listening: return Self.orange
        case .finalizing: return Self.cyan
        case .polishing: return Self.violet
        case .noAccessibility: return Color(red: 1.00, green: 0.80, blue: 0.20)
        case .notice: return Self.cyan
        case .error: return Color(red: 1.00, green: 0.30, blue: 0.30)
        }
    }

    private var isActive: Bool { state.phase == .listening }

    private var canPolish: Bool { LocalRewriter.isAvailable }

    /// Words appear in the pill only when something needs saying — an error,
    /// "copied, press ⌘V", "undone". Ordinary dictation is waveform-only.
    private var showsMessage: Bool {
        switch state.phase {
        case .listening, .finalizing, .polishing: return false
        case .noAccessibility, .notice, .error: return true
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            roundButton(symbol: "xmark", color: Self.pink, enabled: isActive) { onCancel?() }
                .help("Cancel — discard this dictation")

            // Waveform and message share one fixed stage: state changes swap
            // opacity, never layout, so the pill never jumps.
            ZStack {
                WaveformView(
                    level: state.level,
                    animating: state.phase != .noAccessibility,
                    recognitionAt: state.lastRecognitionAt,
                    processing: state.phase == .finalizing || state.phase == .polishing,
                    processingAt: state.phaseChangedAt,
                    frozenTime: frozenTime
                )
                .opacity(showsMessage ? 0 : 1)

                Text(statusText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .opacity(showsMessage ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .animation(.easeOut(duration: 0.18), value: showsMessage)

            roundButton(symbol: "sparkles", color: Self.violet, enabled: isActive && canPolish) {
                onPolish?(NSEvent.modifierFlags.contains(.option))
            }
            .help(canPolish
                ? "Organize this, then insert  (⌥-click: turn it into a prompt)"
                : "Needs Apple Intelligence enabled")

            roundButton(symbol: "checkmark", color: Self.cyan, enabled: isActive) { onFinish?() }
                .help("Insert exactly as spoken")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 300)
        .background(pillBackground)
        .overlay(pillRim)
        .shadow(color: .black.opacity(0.40), radius: 16, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(Color(red: 0.03, green: 0.01, blue: 0.09).opacity(0.94))
    }

    private var pillRim: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Self.orange.opacity(0.6),
                        Self.pink.opacity(0.5),
                        Self.violet.opacity(0.6),
                        Self.cyan.opacity(0.6),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1.2
            )
    }

    private func roundButton(
        symbol: String,
        color: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? color : Color.white.opacity(0.18))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.08 : 0.03)))
                .overlay(Circle().strokeBorder(color.opacity(enabled ? 0.5 : 0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
