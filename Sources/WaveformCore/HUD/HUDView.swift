import SwiftUI

/// The floating pill. Starts COMPACT (waveform only); grows into the full
/// pill (transcript + ✕/✓ controls) the moment recognized words arrive, and
/// the whole thing disappears when dictation ends. Draggable anywhere on its
/// body; never steals focus.
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

    private var isActive: Bool { state.phase == .listening }

    /// Compact until words arrive (or something needs attention). Transcripts
    /// only grow within a session, so this never flip-flops mid-dictation.
    private var expanded: Bool {
        !state.transcript.isEmpty || state.phase != .listening
    }

    // One capsule that MORPHS between the two sizes — the buttons and text are
    // always in the tree, animating their width/height/opacity, so there is no
    // cross-fade between two different views (which read as a flicker).
    var body: some View {
        HStack(spacing: expanded ? 12 : 9) {
            roundButton(symbol: "xmark", color: Self.pink, enabled: isActive) { onCancel?() }
                .frame(width: expanded ? 26 : 0)
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.4)
                .help("Cancel — discard this dictation")

            Circle()
                .fill(statusColor)
                .frame(width: expanded ? 0 : 6, height: 6)
                .opacity(expanded ? 0 : 1)
                .shadow(color: statusColor.opacity(0.9), radius: 4)

            VStack(spacing: expanded ? 5 : 0) {
                WaveformView(
                    level: state.level,
                    animating: state.phase != .noAccessibility,
                    frozenTime: frozenTime
                )
                .frame(height: expanded ? 38 : 30)

                VStack(alignment: .leading, spacing: 3) {
                    liveText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2.5)
                        .foregroundStyle(statusColor.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: expanded ? 46 : 0)
                .opacity(expanded ? 1 : 0)
                .clipped()
            }

            roundButton(symbol: "checkmark", color: Self.cyan, enabled: isActive) { onFinish?() }
                .frame(width: expanded ? 26 : 0)
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.4)
                .help("Finish now and insert")
        }
        .padding(.horizontal, expanded ? 14 : 17)
        .padding(.vertical, expanded ? 11 : 9)
        .frame(width: expanded ? 500 : 196)
        .background(pillBackground)
        .overlay(pillRim)
        .shadow(color: Self.violet.opacity(0.30), radius: expanded ? 22 : 16, y: 5)
        .animation(.spring(response: 0.40, dampingFraction: 0.84), value: expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Settled words bright, still-changing tail dimmed — you can watch the
    /// recognizer commit as you speak.
    private var liveText: some View {
        (
            Text(state.finalizedText)
                .foregroundColor(.white.opacity(0.92))
            + Text(state.finalizedText.isEmpty ? state.volatileText : " " + state.volatileText)
                .foregroundColor(.white.opacity(0.45))
        )
        .font(.system(size: 12.5, weight: .medium, design: .rounded))
        .lineLimit(2)
        .truncationMode(.head)
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
