import SwiftUI

/// The full HUD card: dark glass capsule, neon waveform, live transcript line,
/// and a phase indicator. Sized for the bottom-center of the screen.
struct HUDView: View {
    @ObservedObject var state: HUDState
    /// Fixed time for deterministic offscreen snapshots.
    var frozenTime: Double? = nil

    private var statusText: String {
        switch state.phase {
        case .listening: return "LISTENING"
        case .finalizing: return "FINALIZING"
        case .noAccessibility: return "COPIED — PRESS ⌘V"
        case .error(let message): return message.uppercased()
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .listening: return Color(red: 1.00, green: 0.45, blue: 0.10)
        case .finalizing: return Color(red: 0.16, green: 0.85, blue: 1.00)
        case .noAccessibility: return Color(red: 1.00, green: 0.80, blue: 0.20)
        case .error: return Color(red: 1.00, green: 0.30, blue: 0.30)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            WaveformView(
                level: state.level,
                animating: state.phase == .listening || state.phase == .finalizing,
                frozenTime: frozenTime
            )
            .frame(height: 72)
            .padding(.horizontal, 18)
            .padding(.top, 14)

            HStack(spacing: 10) {
                // Pulsing record dot.
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.9), radius: 4)

                Text(statusText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(statusColor.opacity(0.95))
                    .shadow(color: statusColor.opacity(0.7), radius: 6)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)

            Text(transcriptDisplay)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(state.transcript.isEmpty ? 0.35 : 0.92))
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
        }
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.03, green: 0.01, blue: 0.09).opacity(0.92))
        )
        .overlay(
            // Thin chromatic rim — the "premium disco" edge.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.45, blue: 0.10).opacity(0.55),
                            Color(red: 0.72, green: 0.20, blue: 1.00).opacity(0.55),
                            Color(red: 0.16, green: 0.85, blue: 1.00).opacity(0.55),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color(red: 0.72, green: 0.20, blue: 1.00).opacity(0.25), radius: 24, y: 6)
    }

    private var transcriptDisplay: String {
        state.transcript.isEmpty ? "Speak — text appears here…" : state.transcript
    }
}
