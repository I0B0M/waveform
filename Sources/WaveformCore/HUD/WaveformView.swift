import SwiftUI

/// 90s retro-futuristic music-visualizer waveform — three disco ribbons that
/// each answer a different question:
///
///   - **sunset orange** rides the microphone level: "is it hearing me?"
///   - **electric cyan** rides recognition recency — it flows while new words
///     are arriving and visibly stills when the recognizer stalls: "is it
///     understanding me?"
///   - **ultraviolet** is the ambient thread holding the mark together.
///
/// Rendering stays crisp: one clean stroke per ribbon, no glow layers, no
/// additive blending, and each stroke fades out at the ends so the line
/// dissolves at the pill's edge instead of clipping.
///
/// The stop moment is choreographed here too: when `processing` flips on, the
/// ribbons collapse to a flat line in ~150ms (ears closed), and if work
/// continues past that, a shimmer travels the line — never dead air.
struct WaveformView: View {
    var level: Float
    var animating: Bool = true
    /// When the recognizer last produced text (timeIntervalSinceReferenceDate).
    /// nil = treat as fresh (snapshots, previews).
    var recognitionAt: Double? = nil
    /// True while finalizing/polishing — plays the flatten-then-shimmer.
    var processing: Bool = false
    /// When `processing` began, for the 150ms collapse timing.
    var processingAt: Double = 0
    /// Fixed time for deterministic offscreen snapshots.
    var frozenTime: Double? = nil

    private enum Role {
        case mic, recognition, ambient
    }

    private struct Ribbon {
        let color: Color
        let role: Role
        let harmonics: [(frequency: Double, amplitude: Double, speed: Double)]
        let phaseOffset: Double
        let thickness: CGFloat
    }

    private static let ribbons: [Ribbon] = [
        Ribbon(
            color: Color(red: 1.00, green: 0.45, blue: 0.10), // sunset orange
            role: .mic,
            harmonics: [(1.7, 1.00, 4.2), (3.9, 0.42, -3.0), (7.1, 0.18, 6.0)],
            phaseOffset: 0.0,
            thickness: 2.3
        ),
        Ribbon(
            color: Color(red: 0.72, green: 0.20, blue: 1.00), // ultraviolet
            role: .ambient,
            harmonics: [(2.3, 1.00, -3.6), (4.7, 0.40, 4.8), (8.3, 0.16, -5.4)],
            phaseOffset: 2.1,
            thickness: 2.0
        ),
        Ribbon(
            color: Color(red: 0.16, green: 0.85, blue: 1.00), // electric cyan
            role: .recognition,
            harmonics: [(2.9, 1.00, 3.2), (5.3, 0.38, -4.4), (9.7, 0.15, 4.2)],
            phaseOffset: 4.2,
            thickness: 1.8
        ),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating && frozenTime == nil)) { context in
            Canvas { graphics, size in
                let time = frozenTime ?? context.date.timeIntervalSinceReferenceDate
                draw(in: &graphics, size: size, time: time)
            }
        }
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, time: Double) {
        let midY = size.height / 2
        let maxAmplitude = size.height * 0.42

        // Stop choreography: collapse everything to flat within 150ms of
        // processing starting, then shimmer while work continues.
        var collapse = 1.0
        if processing, frozenTime == nil {
            collapse = max(0, 1 - (time - processingAt) / 0.15)
            if collapse <= 0 {
                drawShimmer(in: &graphics, size: size, midY: midY, time: time)
                return
            }
        }

        let micEnergy = 0.22 + 0.78 * Double(min(max(level, 0), 1))

        // Recognition freshness: full flow while updates are <0.6s old,
        // easing down to a near-still 0.1 by 2s of silence from the ASR.
        let recognitionEnergy: Double
        if let recognitionAt, frozenTime == nil {
            let age = max(0, time - recognitionAt)
            let fresh = 1 - min(max((age - 0.6) / 1.4, 0), 1)
            recognitionEnergy = 0.10 + 0.75 * fresh
        } else {
            recognitionEnergy = 0.22 + 0.78 * Double(min(max(level, 0), 1))
        }

        for ribbon in Self.ribbons {
            let energy: Double
            switch ribbon.role {
            case .mic: energy = micEnergy
            case .recognition: energy = recognitionEnergy
            case .ambient: energy = 0.25 + 0.35 * (micEnergy + recognitionEnergy) / 2
            }

            let path = ribbonPath(
                ribbon: ribbon,
                size: size,
                midY: midY,
                maxAmplitude: maxAmplitude,
                energy: energy * collapse,
                time: time
            )

            // One clean stroke per ribbon; the gradient fades the ends to
            // transparent so the line dissolves instead of stopping dead.
            let faded = ribbon.color.mix(with: .white, by: 0.25)
            graphics.stroke(
                path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: faded.opacity(0), location: 0),
                        .init(color: faded.opacity(0.9), location: 0.12),
                        .init(color: faded.opacity(0.9), location: 0.88),
                        .init(color: faded.opacity(0), location: 1),
                    ]),
                    startPoint: CGPoint(x: 0, y: midY),
                    endPoint: CGPoint(x: size.width, y: midY)
                ),
                style: StrokeStyle(lineWidth: ribbon.thickness, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Flat line with a cyan pulse traveling left→right: "still working" at
    /// the exact height the ribbons held, so nothing shifts.
    private func drawShimmer(in graphics: inout GraphicsContext, size: CGSize, midY: CGFloat, time: Double) {
        var base = Path()
        base.move(to: CGPoint(x: size.width * 0.04, y: midY))
        base.addLine(to: CGPoint(x: size.width * 0.96, y: midY))
        graphics.stroke(
            base,
            with: .color(Color(red: 0.72, green: 0.20, blue: 1.00).opacity(0.25)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        let sweepWidth = size.width * 0.28
        let travel = (time - processingAt) * size.width * 1.1
        let x0 = travel.truncatingRemainder(dividingBy: size.width + sweepWidth) - sweepWidth
        let cyan = Color(red: 0.16, green: 0.85, blue: 1.00)
        var sweep = Path()
        sweep.move(to: CGPoint(x: 0, y: midY))
        sweep.addLine(to: CGPoint(x: size.width, y: midY))
        graphics.stroke(
            sweep,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: cyan.opacity(0), location: 0),
                    .init(color: cyan.opacity(0.95), location: 0.5),
                    .init(color: cyan.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: x0, y: midY),
                endPoint: CGPoint(x: x0 + sweepWidth, y: midY)
            ),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )
    }

    private func ribbonPath(
        ribbon: Ribbon,
        size: CGSize,
        midY: CGFloat,
        maxAmplitude: CGFloat,
        energy: Double,
        time: Double
    ) -> Path {
        var path = Path()
        let samples = 90
        for index in 0...samples {
            let progress = Double(index) / Double(samples)
            let x = CGFloat(progress) * size.width

            // Bell envelope: quiet at the edges, expressive in the middle —
            // the classic visualizer silhouette from the reference art.
            let bell = pow(sin(progress * .pi), 1.4)

            var wave = 0.0
            for harmonic in ribbon.harmonics {
                wave += harmonic.amplitude * sin(
                    progress * harmonic.frequency * 2 * .pi
                        + time * harmonic.speed
                        + ribbon.phaseOffset
                )
            }
            wave /= ribbon.harmonics.reduce(0) { $0 + $1.amplitude }

            let y = midY + CGFloat(wave * bell * energy) * maxAmplitude
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
