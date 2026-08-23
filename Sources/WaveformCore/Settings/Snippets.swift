import Foundation

/// Voice snippets: say the trigger phrase (optionally prefixed with
/// "insert …"), get the stored expansion at your cursor.
struct Snippet: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: String
    var expansion: String
}

enum SnippetMatcher {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func expansion(for spoken: String, in snippets: [Snippet]) -> String? {
        let normalized = normalize(spoken)
        guard !normalized.isEmpty else { return nil }
        for snippet in snippets {
            let trigger = normalize(snippet.trigger)
            guard !trigger.isEmpty else { continue }
            if normalized == trigger || normalized == "insert " + trigger {
                return snippet.expansion
            }
        }
        return nil
    }
}
