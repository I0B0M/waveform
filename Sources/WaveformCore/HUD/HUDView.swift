import SwiftUI

/// The floating pill, Wispr-style: while dictating it shows ONLY the moving
/// waveform (plus the three small controls) — no live transcript. The words
/// belong at the cursor, not in the pill; the ribbons' movement answers "is
/// it hearing me / understanding me". Text appears in the pill only for
/// states that need words: errors, "copied — press ⌘V", "undone".
/// Draggable anywhere on its body; never steals focus.
struct HUDView: View {
    @ObservedObject var state: HUDState
    @State private var hovering = false
    var onFinish: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// Finish, but run the text through the on-device model first.
    /// `promptMode` (⌥-click) builds a prompt instead of tidying a message.
    var onPolish: ((_ promptMode: Bool) -> Void)? = nil
    /// Fixed time for deterministic offscreen snapshots.
    var frozenTime: Double? = nil

    // The dashboard's quiet system, worn by the pill: color belongs to the
    // ribbons; the chrome stays hairline-and-card like every other surface.
    private static let violet = DashboardView.violet
    private static let cyan = DashboardView.cyan
    private static let card = Color(red: 0.067, green: 0.039, blue: 0.122).opacity(0.96)
    private static let line = DashboardView.line
    private static let ink2 = DashboardView.ink2
    private static let ink3 = DashboardView.ink3

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
        case .listening, .finalizing, .polishing: return Self.ink3
        case .noAccessibility: return Color(red: 1.00, green: 0.80, blue: 0.20)
        case .notice: return Self.cyan
        case .error: return Color(red: 1.00, green: 0.36, blue: 0.36)
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

    // Aurora (option C): a small capsule whose 1px rim IS the spectrum, the
    // ribbons carrying the rest. Controls stay hidden until the pointer
    // arrives — they were rarely used, so they stopped costing width.
    var body: some View {
        HStack(spacing: 10) {
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
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .animation(.easeOut(duration: 0.18), value: showsMessage)

            HStack(spacing: 7) {
                roundButton(symbol: "xmark", color: Self.ink3, enabled: isActive) { onCancel?() }
                    .help("Cancel — discard this dictation")
                roundButton(symbol: "sparkles", color: Self.violet, enabled: isActive && canPolish) {
                    onPolish?(NSEvent.modifierFlags.contains(.option))
                }
                .help(canPolish
                    ? "Organize this, then insert  (⌥-click: turn it into a prompt)"
                    : "Needs Apple Intelligence enabled")
                roundButton(symbol: "checkmark", color: DashboardView.ink, enabled: isActive) { onFinish?() }
                    .help("Insert exactly as spoken")
            }
            .frame(width: hovering ? 80 : 0)
            .opacity(hovering ? 1 : 0)
            .clipped()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: hovering ? 300 : 216)
        .background(pillBackground)
        .overlay(pillRim)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.22), value: hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(Self.card)
    }

    private var pillRim: some View {
        // The aurora: the spectrum lives in the border itself, at an opacity
        // that reads as a glow's memory rather than the old neon.
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        DashboardView.orange.opacity(0.38),
                        DashboardView.pink.opacity(0.30),
                        DashboardView.violet.opacity(0.38),
                        DashboardView.cyan.opacity(0.38),
                    ],
                    startPoint: .leading, endPoint: .trailing
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(enabled ? color : Self.ink3.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.05 : 0.02)))
                .overlay(Circle().strokeBorder(Self.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
