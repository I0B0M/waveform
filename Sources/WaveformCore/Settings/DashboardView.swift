import SwiftUI

/// The main window: sidebar dashboard (Wispr-Flow-style structure, disco
/// identity). Home = stats, Dictionary, History, Settings.
public struct DashboardView: View {
    public enum Tab: String, CaseIterable, Identifiable {
        case home = "Home"
        case dictionary = "Dictionary"
        case prompts = "Prompts"
        case snippets = "Snippets"
        case scratchpad = "Scratchpad"
        case history = "History"
        case settings = "Settings"

        public var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: return "sparkles"
            case .dictionary: return "character.book.closed"
            case .prompts: return "wand.and.stars"
            case .snippets: return "text.badge.plus"
            case .scratchpad: return "square.and.pencil"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    /// The single accent: everything interactive or highlighted uses this,
    /// so the disco identity lives in the app mark instead of shouting from
    /// every card at once.
    static let accent = Color(red: 0.62, green: 0.44, blue: 1.00)
    static let cardStroke = Color.white.opacity(0.08)

    static let orange = Color(red: 1.00, green: 0.45, blue: 0.10)
    static let violet = Color(red: 0.72, green: 0.20, blue: 1.00)
    static let cyan = Color(red: 0.16, green: 0.85, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.18, blue: 0.57)
    static let space = Color(red: 0.04, green: 0.02, blue: 0.10)

    var onHotkeyChange: () -> Void
    /// Documentation mode: sample history and a neutral greeting, so nothing
    /// personal can leak into a screenshot.
    var demo: Bool

    @State private var tab: Tab = .home
    @ObservedObject private var history: HistoryStore

    public init(
        onHotkeyChange: @escaping () -> Void,
        demo: Bool = false,
        initialTab: Tab = .home
    ) {
        self.onHotkeyChange = onHotkeyChange
        self.demo = demo
        _tab = State(initialValue: initialTab)
        _history = ObservedObject(wrappedValue: demo ? HistoryStore.demo() : HistoryStore.shared)
    }

    public var body: some View {
        // Documentation renders compose the sidebar directly: a real
        // NavigationSplitView column draws a system material that does not
        // resolve offscreen (it comes out white), which would make every
        // screenshot wrong. The live app uses the real split view below.
        if demo {
            HStack(spacing: 0) {
                docsSidebar
                detail
            }
            .frame(minWidth: 780, minHeight: 540)
            .preferredColorScheme(.dark)
        } else {
            splitView
        }
    }

    private var docsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .font(.system(size: 13, weight: item == tab ? .semibold : .regular))
                    .foregroundStyle(item == tab ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(item == tab ? Color.white.opacity(0.10) : .clear)
                    )
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 180)
        .background(Color(red: 0.07, green: 0.04, blue: 0.15))
    }

    private var splitView: some View {
        NavigationSplitView {
            ZStack {
                // Painted behind the List so the whole column is dark — a
                // background on the List alone leaves the column's own
                // material showing (and it renders white offscreen).
                Color(red: 0.07, green: 0.04, blue: 0.15).ignoresSafeArea()
                List(Tab.allCases, selection: $tab) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .tag(item)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 540)
        .preferredColorScheme(.dark)
        .background(DashboardView.space)
    }

    private var detail: some View {
        ZStack {
            LinearGradient(
                colors: [Self.space, Color(red: 0.02, green: 0.01, blue: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            switch tab {
            case .home: HomeTab(history: history, demo: demo)
            case .dictionary: DictionaryTab()
            case .prompts: PromptsTab()
            case .snippets: SnippetsTab()
            case .scratchpad: ScratchpadTab()
            case .history: HistoryTab(history: history)
            case .settings: SettingsView(onHotkeyChange: onHotkeyChange)
            }
        }
    }
}

// MARK: - Home

private struct HomeTab: View {
    @ObservedObject var history: HistoryStore
    var demo: Bool = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = demo
            ? "there"
            : (NSFullUserName().components(separatedBy: " ").first ?? NSFullUserName())
        switch hour {
        case 5..<12: return "Good morning, \(name)"
        case 12..<17: return "Good afternoon, \(name)"
        default: return "Good evening, \(name)"
        }
    }

    private var topApps: [(name: String, words: Int)] {
        var counts: [String: Int] = [:]
        for record in history.records {
            counts[record.appName ?? "Unknown", default: 0] += record.wordCount
        }
        return counts.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    DiscoIconView(showsPlate: false)
                        .frame(width: 46, height: 46)
                    Text(greeting)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                Text("Speak anywhere. Clean text lands at your cursor. 100% on-device.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    statCard("Words dictated", "\(history.totalWords)")
                    statCard("Dictations", "\(history.totalDictations)")
                    statCard("This week", "\(history.wordsThisWeek) words")
                    statCard("Speed", history.averageWordsPerMinute > 0 ? "\(history.averageWordsPerMinute) wpm" : "—")
                }

                if !topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Top apps").font(.headline)
                        HStack(spacing: 10) {
                            ForEach(topApps, id: \.name) { app in
                                HStack(spacing: 6) {
                                    Text(app.name).font(.callout.weight(.medium))
                                    Text("\(app.words)w").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(.white.opacity(0.06)))
                                .overlay(Capsule().strokeBorder(DashboardView.cardStroke, lineWidth: 1))
                            }
                        }
                    }
                }

                if !history.records.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent").font(.headline)
                        ForEach(history.records.prefix(3)) { record in
                            HistoryRow(record: record)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try saying").font(.headline)
                    tip("Press ✨ on the HUD instead of ✓ to organize before inserting (⌥-click builds a prompt)")
                    tip("“Double slash prompt — I want an agent that reviews my PRs…” → a clean, organized prompt")
                    tip("“Double slash better — okay so basically we should move the deadline…” → a tidy message")
                    tip("Select text anywhere first, then just: “double slash better.”")
                    tip("Also works: “slash organize”, “slash professional”, “slash shorter”.")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.cardStroke, lineWidth: 1))
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(DashboardView.accent).font(.caption)
            Text(text).font(.callout).foregroundStyle(.primary.opacity(0.85))
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @State private var dictionaryText: String = AppSettings.shared.dictionaryText
    @State private var learned: [String] = AppSettings.shared.learnedTerms
    @State private var learnEnabled: Bool = AppSettings.shared.learnFromCorrections

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
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.cardStroke, lineWidth: 1))
                .onChange(of: dictionaryText) { _, newValue in
                    AppSettings.shared.dictionaryText = newValue
                }

            Text("\(AppSettings.shared.dictionaryTerms.count) terms")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Toggle("Learn from my corrections", isOn: $learnEnabled)
                .onChange(of: learnEnabled) { _, newValue in
                    AppSettings.shared.learnFromCorrections = newValue
                }
            Text("When you fix a word Waveform typed, it gets added here and biases the recognizer next time. Only the corrected word is stored — never what you were writing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if learned.isEmpty {
                Text("Nothing learned yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(learned, id: \.self) { term in
                            HStack(spacing: 6) {
                                Text(term).font(.callout)
                                Button {
                                    learned.removeAll { $0 == term }
                                    AppSettings.shared.learnedTerms = learned
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(DashboardView.cardStroke, lineWidth: 1))
                        }
                    }
                }
                .frame(height: 40)
            }
        }
        .padding(28)
    }
}

// MARK: - Prompts

private struct PromptsTab: View {
    @State private var templates: [PromptTemplate] = AppSettings.shared.promptTemplates
    @State private var selection: PromptTemplate.ID?

    private var selected: PromptTemplate? {
        templates.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prompt Library")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Say “double slash” + a trigger, then ramble. Your words get poured into that shape by the on-device model and inserted — the talk-to-Claude loop without the round trip.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(templates) { template in
                        Button {
                            selection = template.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("//\(template.trigger)")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(DashboardView.accent)
                                Text(template.title)
                                    .font(.callout)
                                    .foregroundStyle(.primary.opacity(0.9))
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(template.id == selection ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        let new = PromptTemplate(
                            trigger: "new",
                            title: "Untitled shape",
                            instruction: "Turn the user's spoken description into … Reply with only the result."
                        )
                        templates.append(new)
                        AppSettings.shared.promptTemplates = templates
                        selection = new.id
                    } label: {
                        Label("Add shape", systemImage: "plus")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .frame(width: 210)

                if let current = selected, let index = templates.firstIndex(where: { $0.id == current.id }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TextField("Trigger", text: Binding(
                                get: { templates[index].trigger },
                                set: { templates[index].trigger = $0; AppSettings.shared.promptTemplates = templates }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            TextField("Title", text: Binding(
                                get: { templates[index].title },
                                set: { templates[index].title = $0; AppSettings.shared.promptTemplates = templates }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Spacer()
                            Button(role: .destructive) {
                                templates.remove(at: index)
                                AppSettings.shared.promptTemplates = templates
                                selection = templates.first?.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }

                        Text("Instructions given to the local model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { templates[index].instruction },
                            set: { templates[index].instruction = $0; AppSettings.shared.promptTemplates = templates }
                        ))
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.cardStroke, lineWidth: 1))
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("Pick a shape to edit it.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(28)
        .onAppear { if selection == nil { selection = templates.first?.id } }
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
                        Text("→ \(app)").font(.caption).foregroundStyle(DashboardView.accent.opacity(0.9))
                    }
                    Spacer()
                    Text(copied ? "Copied ✓" : "\(record.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(copied ? DashboardView.accent : .secondary)
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


// MARK: - Snippets

private struct SnippetsTab: View {
    @State private var snippets: [Snippet] = AppSettings.shared.snippets
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voice Snippets")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Say the trigger phrase (or “insert ” + trigger) while dictating and the expansion is typed instead. Saved automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                TextField("Trigger — e.g. my calendar link", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                TextField("Expansion — the text to insert", text: $newExpansion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button("Add") {
                    let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
                    let expansion = newExpansion.trimmingCharacters(in: .whitespaces)
                    guard !trigger.isEmpty, !expansion.isEmpty else { return }
                    snippets.append(Snippet(trigger: trigger, expansion: expansion))
                    AppSettings.shared.snippets = snippets
                    newTrigger = ""
                    newExpansion = ""
                }
                .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                    || newExpansion.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if snippets.isEmpty {
                Spacer()
                Text("No snippets yet — add your address, calendar link, or a canned reply.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(snippets) { snippet in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("“\(snippet.trigger)”")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(DashboardView.accent)
                                    Text(snippet.expansion)
                                        .font(.callout)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary.opacity(0.85))
                                }
                                Spacer()
                                Button {
                                    snippets.removeAll { $0.id == snippet.id }
                                    AppSettings.shared.snippets = snippets
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                        }
                    }
                }
            }
        }
        .padding(28)
    }
}

// MARK: - Scratchpad

private struct ScratchpadTab: View {
    @ObservedObject private var pad = ScratchpadStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scratchpad")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("A local drafting space — click in, dictate long rambles here, shape them, then copy where they belong. Autosaved on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $pad.text)
                .font(.system(size: 14, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.cardStroke, lineWidth: 1))
        }
        .padding(28)
    }
}
