import SwiftUI

/// The main window: sidebar dashboard (Wispr-Flow-style structure, disco
/// identity). Home = stats, Dictionary, History, Settings.
public struct DashboardView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home"
        case dictionary = "Dictionary"
        case history = "History"
        case settings = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: return "sparkles"
            case .dictionary: return "character.book.closed"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    static let orange = Color(red: 1.00, green: 0.45, blue: 0.10)
    static let violet = Color(red: 0.72, green: 0.20, blue: 1.00)
    static let cyan = Color(red: 0.16, green: 0.85, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.18, blue: 0.57)
    static let space = Color(red: 0.04, green: 0.02, blue: 0.10)

    var onHotkeyChange: () -> Void

    @State private var tab: Tab = .home
    @ObservedObject private var history = HistoryStore.shared

    public var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.06, green: 0.03, blue: 0.13))
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [Self.space, Color(red: 0.02, green: 0.01, blue: 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                switch tab {
                case .home: HomeTab(history: history)
                case .dictionary: DictionaryTab()
                case .history: HistoryTab(history: history)
                case .settings: SettingsView(onHotkeyChange: onHotkeyChange)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 540)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Home

private struct HomeTab: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Waveform")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [DashboardView.orange, DashboardView.pink, DashboardView.violet, DashboardView.cyan],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                Text("Speak anywhere. Clean text lands at your cursor. 100% on-device.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    statCard("Words dictated", "\(history.totalWords)", DashboardView.orange)
                    statCard("Dictations", "\(history.totalDictations)", DashboardView.violet)
                    statCard("This week", "\(history.wordsThisWeek) words", DashboardView.cyan)
                    statCard("Speed", history.averageWordsPerMinute > 0 ? "\(history.averageWordsPerMinute) wpm" : "—", DashboardView.pink)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try saying").font(.headline)
                    tip("“Make this message better and more structured, …then just ramble.”")
                    tip("“Create a quick prompt for me, I want an agent that…”")
                    tip("Select text anywhere first, then: “make this more organized.”")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statCard(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.6), radius: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(DashboardView.cyan).font(.caption)
            Text(text).font(.callout).foregroundStyle(.primary.opacity(0.85))
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @State private var dictionaryText: String = AppSettings.shared.dictionaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personal Dictionary")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("One term per line — names, jargon, acronyms. The recognizer is biased toward these from your next dictation. Saved automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $dictionaryText)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.violet.opacity(0.3), lineWidth: 1))
                .onChange(of: dictionaryText) { _, newValue in
                    AppSettings.shared.dictionaryText = newValue
                }

            Text("\(AppSettings.shared.dictionaryTerms.count) terms")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("History")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                if !history.records.isEmpty {
                    Button("Clear all", role: .destructive) { history.clear() }
                }
            }
            Text("Stored only on this Mac (last \(500) dictations). Click any entry to copy it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if history.records.isEmpty {
                Spacer()
                Text("Nothing yet — dictate something!")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history.records) { record in
                            HistoryRow(record: record)
                        }
                    }
                }
            }
        }
        .padding(28)
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.date, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let app = record.appName {
                        Text("→ \(app)").font(.caption).foregroundStyle(DashboardView.cyan.opacity(0.8))
                    }
                    Spacer()
                    Text(copied ? "Copied ✓" : "\(record.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(copied ? DashboardView.cyan : .secondary)
                }
                Text(record.text)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}
