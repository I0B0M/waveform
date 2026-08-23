import Foundation

/// Detects spoken self-corrections worth resolving ("meet at 5, no wait, 6").
/// Deliberately conservative: only unambiguous correction phrases gate the
/// (on-device) LLM pass — a lone "actually" or "I mean" appears constantly in
/// normal speech and must not trigger a rewrite.
enum SelfCorrection {
    private static let pattern =
        #"(?i)\b(?:no,?\s+wait|wait,?\s+no|scratch\s+that|correction[,:]|"#
        + #"(?:sorry|no)[,.]?\s+i\s+meant?|actually[,.]?\s+(?:no|make\s+(?:that|it))|"#
        + #"not\s+that[,.]?\s+i\s+mean)\b"#

    static func hasMarkers(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
