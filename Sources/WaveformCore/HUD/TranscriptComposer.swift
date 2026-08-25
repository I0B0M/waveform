import SwiftUI

/// One word of the live transcript. `id` is the word's position, which keeps
/// identity stable as the tail changes — SwiftUI then animates only opacity,
/// never position.
struct TranscriptWord: Identifiable, Equatable {
    let id: Int
    var text: String
    /// Settled words are bright; volatile ones are dim.
    var settled: Bool
    /// Position within the batch of words that settled together, for the
    /// staggered "ink drying" opacity ramp (batch × 40ms).
    var settleBatchIndex: Int
}

/// Pure transcript → words pipeline, extracted so the settle-stagger rules
/// are unit-testable without a HUD.
enum TranscriptComposer {
    static func compose(
        finalized: String,
        volatile: String,
        previous: [TranscriptWord]
    ) -> [TranscriptWord] {
        let settledWords = split(finalized)
        let volatileWords = split(volatile)
        let previouslySettled = previous.lazy.filter(\.settled).count

        var words: [TranscriptWord] = []
        words.reserveCapacity(settledWords.count + volatileWords.count)
        for (index, text) in settledWords.enumerated() {
            // Words settling in this update get consecutive batch indices so
            // their opacity ramps cascade; long-settled words get 0 (no delay
            // should they ever re-render).
            let batch = index >= previouslySettled ? index - previouslySettled : 0
            words.append(TranscriptWord(id: index, text: text, settled: true, settleBatchIndex: batch))
        }
        for (offset, text) in volatileWords.enumerated() {
            words.append(TranscriptWord(
                id: settledWords.count + offset,
                text: text,
                settled: false,
                settleBatchIndex: 0
            ))
        }
        return words
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Leading-aligned wrapping layout for the transcript words. Positions are
/// computed, not animated — the strip is clipped to a fixed height and
/// bottom-anchored, so growth pushes old lines up into the fade instead of
/// reflowing what the eye is reading.
struct FlowLayout: Layout {
    var spacing: CGFloat = 3.5
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        return arrange(subviews: subviews, in: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews: subviews, in: bounds.width).placements
        for (subview, point) in zip(subviews, placements) {
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> (size: CGSize, placements: [CGPoint]) {
        var placements: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            placements.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), placements)
    }
}
