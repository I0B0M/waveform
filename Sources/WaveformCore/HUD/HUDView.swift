import SwiftUI

/// The floating pill (Wispr-Flow-style ergonomics, disco identity):
/// ✕ cancel on the left, ✓ finish on the right, neon waveform in the middle,
/// live transcript below it. Draggable anywhere on its body; buttons are only
/// active while listening.
struct HUDView: View {
    @ObservedObject var state: HUDState
    var onFinish: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
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
        case .noAccessibility: return "COPIED — PRESS ⌘V"
        case .error(let message): return message.uppercased()
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .listening: return Self.orange
        case .finalizing: return Self.cyan
        case .polishing: return Self.violet
        case .noAccessibility: return Color(red: 1.00, green: 0.80, blue: 0.20)
        case .error: return Color(red: 1.00, green: 0.30, blue: 0.30)
        }
    }

    private var isActive: Bool {
        state.phase == .listening
    }

    var body: some View {
        HStack(spacing: 12) {
            roundButton(
                symbol: "xmark",
                color: Self.pink,
                enabled: isActive,
                action: { onCancel?() }
            )
            .help("Cancel — discard this dictation")

            VStack(spacing: 4) {
                WaveformView(
                    level: state.level,
                    animating: state.phase != .noAccessibility,
                    frozenTime: frozenTime
                )
                .frame(height: 44)

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.9), radius: 4)
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2.5)
                        .foregroundStyle(statusColor.opacity(0.95))
                    Spacer(minLength: 0)
                    Text(transcriptDisplay)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(state.transcript.isEmpty ? 0.35 : 0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            roundButton(
                symbol: "checkmark",
                color: Self.cyan,
                enabled: isActive,
                action: { onFinish?() }
            )
            .help("Finish now and insert")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 460)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.03, green: 0.01, blue: 0.09).opacity(0.94))
        )
        .overlay(
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
        )
        .shadow(color: Self.violet.opacity(0.30), radius: 22, y: 6)
    }

    private var transcriptDisplay: String {
        state.transcript.isEmpty ? "Speak — text appears here…" : state.transcript
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
                .background(
                    Circle().fill(Color.white.opacity(enabled ? 0.08 : 0.03))
                )
                .overlay(
                    Circle().strokeBorder(color.opacity(enabled ? 0.5 : 0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
