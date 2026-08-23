import SwiftUI

/// The 1280×640 card GitHub shows when the repo is linked or shared
/// ("social preview"). Drawn from the same mark and palette as the app, so
/// the repo, the icon, and the HUD all read as one product.
struct SocialPreviewView: View {
    private static let orange = Color(red: 1.00, green: 0.45, blue: 0.10)
    private static let pink = Color(red: 1.00, green: 0.18, blue: 0.57)
    private static let violet = Color(red: 0.72, green: 0.20, blue: 1.00)
    private static let cyan = Color(red: 0.16, green: 0.85, blue: 1.00)

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.06, blue: 0.24),
                    Color(red: 0.02, green: 0.01, blue: 0.05),
                ],
                center: .init(x: 0.28, y: 0.30),
                startRadius: 40,
                endRadius: 900
            )

            // A single ribbon across the lower third for texture — quiet
            // enough that the wordmark stays the loudest thing on the card.
            WaveformView(level: 0.85, animating: false, frozenTime: 2.4)
                .frame(height: 300)
                .opacity(0.30)
                .offset(y: 170)

            HStack(spacing: 54) {
                DiscoIconView(showsPlate: false)
                    .frame(width: 240, height: 240)

                VStack(alignment: .leading, spacing: 18) {
                    Text("Waveform")
                        .font(.system(size: 104, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Self.orange, Self.pink, Self.violet, Self.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("Local-first dictation for macOS")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    HStack(spacing: 12) {
                        badge("100% on-device", Self.cyan)
                        badge("No cloud", Self.pink)
                        badge("No account", Self.violet)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 84)
        }
        .frame(width: 1280, height: 640)
        .clipped()
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }
}
