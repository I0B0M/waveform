import SwiftUI

/// The floating pill. Starts COMPACT (waveform only); grows into the full
/// pill (transcript + ✕/✓ controls) the moment recognized words arrive, and
/// the whole thing disappears when dictation ends. Draggable anywhere on its
/// body; never steals focus.
struct HUDView: View {
    @ObservedObject var state: HUDState
    var onFinish: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// Finish, but run the text through the on-device model first.
    /// `promptMode` (⌥-click) builds a prompt instead of tidying a message.
    var onPolish: ((_ promptMode: Bool) -> Void)? = nil
    /// Fixed time for deterministic offscreen snapshots.
    var frozenTime: Double? = nil

    private static let accent = Color(red: 0.62, green: 0.44, blue: 1.00)
    private static let cyan = Color(red: 0.30, green: 0.80, blue: 1.00)

    private var statusText: String {
        switch state.phase {
        case .listening: return "LISTENING"
        case .finalizing: return "FINALIZING"
        case .polishing: return "POLISHING"
        case .noAccessibility: return "COPIED — PRESS ⌘V"
        case .error(let message): return message.uppercased()
        }
    }

    /// Working states stay quiet; only the two states that need the user's
    /// attention (press ⌘V yourself, an error) get a color of their own.
    private var statusColor: Color {
        switch state.phase {
        case .listening: return Self.accent
        case .finalizing, .polishing: return Self.cyan
        case .noAccessibility: return Color(red: 1.00, green: 0.80, blue: 0.20)
        case .error: return Color(red: 1.00, green: 0.36, blue: 0.36)
        }
    }

    private var statusTextColor: Color {
        switch state.phase {
        case .listening, .finalizing, .polishing: return .white.opacity(0.45)
        default: return statusColor
        }
    }

    private var isActive: Bool { state.phase == .listening }

    private var canPolish: Bool { LocalRewriter.isAvailable }

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
            roundButton(symbol: "xmark", color: .white.opacity(0.6), enabled: isActive) { onCancel?() }
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
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(statusTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: expanded ? 46 : 0)
                .opacity(expanded ? 1 : 0)
                .clipped()
            }

            roundButton(symbol: "sparkles", color: Self.accent, enabled: isActive && canPolish) {
                onPolish?(NSEvent.modifierFlags.contains(.option))
            }
            .frame(width: expanded ? 26 : 0)
            .opacity(expanded ? 1 : 0)
            .scaleEffect(expanded ? 1 : 0.4)
            .help(canPolish
                ? "Organize this, then insert  (⌥-click: turn it into a prompt)"
                : "Needs Apple Intelligence enabled")

            roundButton(symbol: "checkmark", color: Self.cyan, enabled: isActive) { onFinish?() }
                .frame(width: expanded ? 26 : 0)
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.4)
                .help("Insert exactly as spoken")
        }
        .padding(.horizontal, expanded ? 14 : 17)
        .padding(.vertical, expanded ? 11 : 9)
        .frame(width: expanded ? 520 : 196)
        .background(pillBackground)
        .overlay(pillRim)
        .shadow(color: .black.opacity(0.45), radius: expanded ? 18 : 12, y: 6)
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
        // One quiet gradient in the accent family — the rim frames the pill
        // instead of competing with the waveform inside it.
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [Self.accent.opacity(0.45), Self.cyan.opacity(0.35)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1
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
