import Foundation
import FoundationModels

/// Distills the user's local dictation history into a compact "style card" —
/// greetings they use, formality, emoji habits, sentence length — that
/// conditions every rewrite. This is Wispr's "learns your voice", except the
/// corpus never leaves the machine: the profile improves BECAUSE it's local.
@MainActor
enum StyleProfiler {
    private static let staleAfter: TimeInterval = 24 * 3600
    private static let minimumHistory = 15

    nonisolated private static let instructions = """
        You will be shown recent short texts one person dictated. Write a \
        compact style profile of how this person writes: their typical \
        formality, greeting/sign-off habits, sentence length, and emoji or \
        punctuation quirks. Describe patterns in general terms — do NOT quote \
        or reproduce any of the texts. 3 to 5 short lines, third person, \
        factual. Reply with ONLY the profile.
        """

    /// Refresh the stored style card if it's stale and there's enough
    /// history to be worth distilling. Cheap no-op otherwise.
    static func refreshIfStale() async {
        guard AppSettings.shared.styleLearningEnabled,
              LocalRewriter.isAvailable else { return }
        let age = Date().timeIntervalSince1970 - AppSettings.shared.styleCardUpdatedAt
        guard age > staleAfter else { return }

        let records = HistoryStore.shared.records
        guard records.count >= minimumHistory else { return }

        // Recent, medium-length texts carry the most voice; tiny fragments
        // and huge rambles both dilute the profile.
        let samples = records.lazy
            .map(\.text)
            .filter { $0.count > 20 && $0.count < 600 }
            .prefix(30)
        guard samples.count >= 10 else { return }

        let corpus = samples.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        do {
            let card: String = try await withThrowingTimeout(seconds: 30) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: corpus)
                return response.content
            }
            let trimmed = card.trimmingCharacters(in: .whitespacesAndNewlines)
            // A usable card is a few lines, not an essay and not an apology.
            guard trimmed.count > 40, trimmed.count < 800,
                  !trimmed.lowercased().hasPrefix("i can") else { return }
            AppSettings.shared.styleCard = trimmed
            AppSettings.shared.styleCardUpdatedAt = Date().timeIntervalSince1970
            Log.app.notice("style card refreshed (\(trimmed.count, privacy: .public) chars)")
        } catch {
            Log.app.error("style card refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}
