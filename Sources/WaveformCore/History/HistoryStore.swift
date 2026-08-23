import Foundation

/// Local dictation history: a small JSON file in Application Support.
/// Never leaves the Mac; capped so it can't grow unbounded.
struct DictationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let wordCount: Int
    let text: String
    let appName: String?
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [DictationRecord] = []

    private static let cap = 500
    /// nil for the in-memory demo store used to render documentation — real
    /// dictation history must never end up in a screenshot.
    private let fileURL: URL?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waveform", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    private init(sample: [DictationRecord]) {
        fileURL = nil
        records = sample
    }

    /// Stand-in content for docs and previews.
    static func demo() -> HistoryStore {
        HistoryStore(sample: [
            DictationRecord(
                id: UUID(), date: Date().addingTimeInterval(-1_800),
                durationSeconds: 14, wordCount: 24,
                text: "Okay, so basically I wanted to explain that we should move the launch to next week and tell the client first.",
                appName: "Slack"
            ),
            DictationRecord(
                id: UUID(), date: Date().addingTimeInterval(-9_000),
                durationSeconds: 9, wordCount: 17,
                text: "Plan:\n• Ship the build\n• Update the changelog\n• Tell the team on Monday",
                appName: "Notes"
            ),
            DictationRecord(
                id: UUID(), date: Date().addingTimeInterval(-26_000),
                durationSeconds: 11, wordCount: 21,
                text: "Write a prompt for an agent that reviews pull requests and checks naming conventions against our style guide.",
                appName: "Claude"
            ),
        ])
    }

    func add(text: String, duration: Double, appName: String?) {
        let record = DictationRecord(
            id: UUID(),
            date: Date(),
            durationSeconds: duration,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            text: text,
            appName: appName
        )
        records.insert(record, at: 0)
        if records.count > Self.cap {
            records.removeLast(records.count - Self.cap)
        }
        save()
    }

    func clear() {
        records = []
        save()
    }

    // MARK: - Stats

    var totalWords: Int { records.reduce(0) { $0 + $1.wordCount } }
    var totalDictations: Int { records.count }
    var wordsThisWeek: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return records.filter { $0.date > cutoff }.reduce(0) { $0 + $1.wordCount }
    }
    var averageWordsPerMinute: Int {
        let totalSeconds = records.reduce(0.0) { $0 + $1.durationSeconds }
        guard totalSeconds > 5 else { return 0 }
        return Int(Double(totalWords) / (totalSeconds / 60.0))
    }

    // MARK: - Persistence

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
