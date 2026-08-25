import SwiftUI

/// Music-visualizer waveform: two ribbons in the app's accent family
/// (violet and cyan) weaving across a dark void, amplitude driven by the
/// live microphone level. Two hues that sit next to each other read as one
/// glowing voice; a third contrasting hue read as noise.
///
/// Rendering notes for efficiency: one Canvas, three strokes per ribbon
/// (halo, glow, core), no offscreen effects, and the TimelineView pauses
/// whenever the HUD is not animating — zero cost while idle.
struct WaveformView: View {
    var level: Float
    var animating: Bool = true
    /// Fixed time for deterministic offscreen snapshots.
    var frozenTime: Double? = nil

    private struct Ribbon {
        let color: Color
        let harmonics: [(frequency: Double, amplitude: Double, speed: Double)]
        let phaseOffset: Double
        let thickness: CGFloat
    }

    private static let ribbons: [Ribbon] = [
        Ribbon(
            color: Color(red: 0.62, green: 0.44, blue: 1.00), // accent violet
            harmonics: [(1.7, 1.00, 4.2), (3.9, 0.42, -3.0), (7.1, 0.18, 6.0)],
            phaseOffset: 0.0,
            thickness: 2.2
        ),
        Ribbon(
            color: Color(red: 0.30, green: 0.80, blue: 1.00), // cyan partner
            harmonics: [(2.3, 1.00, -3.6), (4.7, 0.40, 4.8), (8.3, 0.16, -5.4)],
            phaseOffset: 2.6,
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
        // Idle breathing keeps the ribbons alive at low level; voice opens them up.
        let energy = 0.22 + 0.78 * Double(min(max(level, 0), 1))
        let midY = size.height / 2
        let maxAmplitude = size.height * 0.42

        graphics.blendMode = .plusLighter

        for ribbon in Self.ribbons {
            let path = ribbonPath(
                ribbon: ribbon,
                size: size,
                midY: midY,
                maxAmplitude: maxAmplitude,
                energy: energy,
                time: time
            )

            // Halo → glow → hot core, additively blended.
            graphics.stroke(
                path,
                with: .color(ribbon.color.opacity(0.12)),
                style: StrokeStyle(lineWidth: ribbon.thickness * 4, lineCap: .round, lineJoin: .round)
            )
            graphics.stroke(
                path,
                with: .color(ribbon.color.opacity(0.45)),
                style: StrokeStyle(lineWidth: ribbon.thickness * 2, lineCap: .round, lineJoin: .round)
            )
            graphics.stroke(
                path,
                with: .color(ribbon.color.mix(with: .white, by: 0.65).opacity(0.95)),
                style: StrokeStyle(lineWidth: ribbon.thickness * 0.9, lineCap: .round, lineJoin: .round)
            )
        }
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
