import Foundation

/// Token-level diff used to spot the words a person corrected by hand after
/// Waveform typed them.
///
/// Only 1:1 substitutions are reported. A correction that adds, removes, or
/// rewrites a whole clause tells us nothing about how a *word* should have been
/// heard, and treating it as vocabulary would poison the dictionary.
enum WordDiff {
    struct Substitution: Equatable {
        let from: String
        let to: String
    }

    /// Guard against pathological input: the alignment is O(n·m), and a diff
    /// over an entire document is neither useful nor cheap.
    private static let maxTokens = 400

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"'()[]{}.,;:!?…")) }
            .filter { !$0.isEmpty }
    }

    static func substitutions(from old: [String], to new: [String]) -> [Substitution] {
        guard !old.isEmpty, !new.isEmpty,
              old.count <= maxTokens, new.count <= maxTokens else { return [] }

        // Longest common subsequence table over tokens, compared case- and
        // punctuation-insensitively so "Okay" -> "okay" isn't an edit.
        let a = old.map { $0.lowercased() }
        let b = new.map { $0.lowercased() }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        // Walk the alignment, collecting runs of removed and added tokens.
        var result: [Substitution] = []
        var i = 0, j = 0
        var removed: [String] = []
        var added: [String] = []

        func flush() {
            // A single word swapped for a single word is the only signal we
            // trust as a mishearing.
            if removed.count == 1, added.count == 1, removed[0].lowercased() != added[0].lowercased() {
                result.append(Substitution(from: removed[0], to: added[0]))
            }
            removed.removeAll()
            added.removeAll()
        }

        while i < a.count && j < b.count {
            if a[i] == b[j] {
                flush()
                // Same word, written differently ("nestjs" -> "NestJS"). The
                // alignment matches these as equal (it compares case-folded),
                // so capitalization fixes must be picked up here or they are
                // invisible — and those are exactly the ones worth learning.
                if old[i] != new[j] {
                    result.append(Substitution(from: old[i], to: new[j]))
                }
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(old[i])
                i += 1
            } else {
                added.append(new[j])
                j += 1
            }
        }
        while i < a.count { removed.append(old[i]); i += 1 }
        while j < b.count { added.append(new[j]); j += 1 }
        flush()
        return result
    }

    /// Levenshtein distance — how far the recognizer's guess was from what the
    /// person actually wanted.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.lowercased()), b = Array(rhs.lowercased())
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
