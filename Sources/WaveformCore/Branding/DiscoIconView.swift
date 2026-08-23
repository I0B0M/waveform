import SwiftUI

/// The app mark: an audio waveform built out of disco-ball mirror facets.
///
/// Drawn as vectors (no bitmap assets) so one definition serves the 16pt menu
/// glyph and the 1024pt App Store size. Every facet's brightness comes from a
/// deterministic hash of its grid position, so the sparkle pattern is stable
/// across renders — an icon that shimmered differently each build would look
/// broken in caches and diffs.
public struct DiscoIconView: View {
    /// Bar heights as a fraction of the drawable height, center-anchored.
    private static let barHeights: [Double] = [0.34, 0.62, 1.00, 0.72, 0.44]

    private static let palette: [SIMD3<Double>] = [
        SIMD3(1.00, 0.45, 0.10),   // sunset orange
        SIMD3(1.00, 0.18, 0.57),   // hot pink
        SIMD3(0.72, 0.20, 1.00),   // ultraviolet
        SIMD3(0.16, 0.85, 1.00),   // electric cyan
    ]

    /// Draw the rounded-rect plate behind the mark (off for a bare glyph).
    public var showsPlate: Bool

    public init(showsPlate: Bool = true) {
        self.showsPlate = showsPlate
    }

    public var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if showsPlate {
                    plate(side: side)
                }
                // Colored bloom behind the bars — what makes the mirrors read
                // as *lit* rather than printed.
                Canvas { graphics, size in
                    drawBars(in: &graphics, size: size, facets: false)
                }
                .blur(radius: side * 0.055)
                .opacity(0.9)

                Canvas { graphics, size in
                    drawBars(in: &graphics, size: size, facets: true)
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func plate(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.12, green: 0.06, blue: 0.24),
                        Color(red: 0.02, green: 0.01, blue: 0.06),
                    ],
                    center: .init(x: 0.35, y: 0.28),
                    startRadius: 0,
                    endRadius: side * 0.85
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: side * 0.006)
            )
    }

    // MARK: - Bars

    private func drawBars(in graphics: inout GraphicsContext, size: CGSize, facets: Bool) {
        let side = min(size.width, size.height)
        // The plateless glyph (menu bar) fills more of its frame.
        let inset = side * (showsPlate ? 0.135 : 0.07)
        let field = CGRect(
            x: (size.width - side) / 2 + inset,
            y: (size.height - side) / 2 + inset,
            width: side - inset * 2,
            height: side - inset * 2
        )

        let count = Self.barHeights.count
        let gapRatio = 0.30
        let barWidth = field.width / (Double(count) + gapRatio * Double(count - 1))
        let gap = barWidth * gapRatio
        let facetSize = side / 44

        for (index, heightFraction) in Self.barHeights.enumerated() {
            let barHeight = field.height * heightFraction
            let rect = CGRect(
                x: field.minX + Double(index) * (barWidth + gap),
                y: field.midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            let shape = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)
            // Span the whole palette end to end so every bar owns a hue.
            let baseColor = color(atFraction: Double(index) / Double(count - 1))

            guard facets else {
                graphics.fill(shape, with: .color(rgb(baseColor)))
                continue
            }

            // Below a few pixels per mirror the facet grid is sub-pixel noise;
            // a lit gradient reads far better at menu-bar sizes.
            if facetSize < 2.5 {
                graphics.fill(
                    shape,
                    with: .linearGradient(
                        Gradient(colors: [rgb(baseColor * 1.45), rgb(baseColor * 0.70)]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                    )
                )
                graphics.stroke(
                    shape,
                    with: .color(.white.opacity(0.35)),
                    lineWidth: max(0.5, side * 0.008)
                )
                continue
            }

            graphics.drawLayer { layer in
                layer.clip(to: shape)
                // Dark grout so the facets read as separate mirrors.
                layer.fill(shape, with: .color(rgb(baseColor * 0.22)))
                drawFacets(in: &layer, bar: rect, facetSize: facetSize, base: baseColor, index: index)
            }

            // Glass rim.
            graphics.stroke(
                shape,
                with: .color(rgb(baseColor * 1.35).opacity(0.55)),
                lineWidth: side * 0.004
            )
        }
    }

    private func drawFacets(
        in graphics: inout GraphicsContext,
        bar: CGRect,
        facetSize: CGFloat,
        base: SIMD3<Double>,
        index: Int
    ) {
        // Light source up and to the left, as in the reference art.
        let light = CGPoint(x: bar.minX + bar.width * 0.28, y: bar.minY + bar.height * 0.18)
        let falloff = max(bar.width, bar.height) * 0.95
        let gap = facetSize * 0.10

        let columns = Int(ceil(bar.width / facetSize)) + 1
        let rows = Int(ceil(bar.height / facetSize)) + 1

        for row in 0..<rows {
            for column in 0..<columns {
                let origin = CGPoint(
                    x: bar.minX + Double(column) * facetSize,
                    y: bar.minY + Double(row) * facetSize
                )
                let center = CGPoint(x: origin.x + facetSize / 2, y: origin.y + facetSize / 2)

                let distance = hypot(center.x - light.x, center.y - light.y) / falloff
                let shade = max(0.46, 1.52 - distance * 0.88)
                let jitter = 0.86 + 0.42 * Self.hash(column, row, index)
                let facetColor = base * 1.12 * shade * jitter

                let tile = Path(
                    roundedRect: CGRect(
                        x: origin.x + gap,
                        y: origin.y + gap,
                        width: facetSize - gap * 2,
                        height: facetSize - gap * 2
                    ),
                    cornerRadius: facetSize * 0.16,
                    style: .continuous
                )
                graphics.fill(tile, with: .color(rgb(facetColor)))

                // A few mirrors catch the light dead-on.
                if shade > 1.06, Self.hash(column + 31, row + 17, index) > 0.80 {
                    graphics.fill(tile, with: .color(.white.opacity(0.85)))
                }
            }
        }

        // Broad specular sheen across the upper-left face.
        graphics.fill(
            Path(ellipseIn: CGRect(
                x: light.x - bar.width * 0.75,
                y: light.y - bar.height * 0.30,
                width: bar.width * 1.5,
                height: bar.height * 0.60
            )),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.42), .white.opacity(0)]),
                center: light,
                startRadius: 0,
                endRadius: max(bar.width, bar.height) * 0.45
            )
        )
    }

    // MARK: - Helpers

    private func color(atFraction fraction: Double) -> SIMD3<Double> {
        let clamped = min(max(fraction, 0), 1)
        let scaled = clamped * Double(Self.palette.count - 1)
        let lower = Int(scaled)
        let upper = min(lower + 1, Self.palette.count - 1)
        let t = scaled - Double(lower)
        return Self.palette[lower] * (1 - t) + Self.palette[upper] * t
    }

    private func rgb(_ value: SIMD3<Double>) -> Color {
        Color(
            red: min(max(value.x, 0), 1),
            green: min(max(value.y, 0), 1),
            blue: min(max(value.z, 0), 1)
        )
    }

    /// Classic fract(sin(dot)) hash — stable, cheap, no state.
    private static func hash(_ x: Int, _ y: Int, _ salt: Int) -> Double {
        let value = sin(Double(x) * 12.9898 + Double(y) * 78.233 + Double(salt) * 37.719) * 43758.5453
        return value - floor(value)
    }
}
