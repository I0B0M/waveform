import AVFoundation
import SwiftUI

/// The main window. Wispr-style bones — grouped sidebar, greeting, stats,
/// recent — restyled to the approved concept: quiet, hairline-ruled, one
/// display face doing the talking, and the disco identity reduced to
/// jewelry (the spectrum rail on the window's edge, four small dots on the
/// stat labels, the mark in the sidebar).
public struct DashboardView: View {
    public enum Tab: String, CaseIterable, Identifiable {
        case home = "Home"
        case history = "History"
        case scratchpad = "Scratchpad"
        case dictionary = "Dictionary"
        case prompts = "Prompts"
        case snippets = "Snippets"
        case settings = "Settings"

        public var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: return "waveform"
            case .dictionary: return "character.book.closed"
            case .prompts: return "wand.and.stars"
            case .snippets: return "text.badge.plus"
            case .scratchpad: return "square.and.pencil"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    // Accents — used sparingly, as jewelry.
    static let orange = Color(red: 1.00, green: 0.45, blue: 0.10)
    static let pink = Color(red: 1.00, green: 0.18, blue: 0.57)
    static let violet = Color(red: 0.72, green: 0.20, blue: 1.00)
    static let cyan = Color(red: 0.16, green: 0.85, blue: 1.00)

    // The quiet system everything sits on.
    static let ground = Color(red: 0.031, green: 0.016, blue: 0.059)     // #08040F
    static let pane = Color(red: 0.047, green: 0.027, blue: 0.094)       // #0C0718
    static let card = Color(red: 0.067, green: 0.039, blue: 0.122)       // #110A1F
    static let line = Color(red: 0.141, green: 0.098, blue: 0.251)       // #241940
    static let lineSoft = Color(red: 0.102, green: 0.063, blue: 0.188)   // #1A1030
    static let ink = Color(red: 0.93, green: 0.91, blue: 0.965)          // #EDE9F6
    static let ink2 = Color(red: 0.663, green: 0.616, blue: 0.761)       // #A99DC2
    static let ink3 = Color(red: 0.435, green: 0.388, blue: 0.537)       // #6F6389

    /// Legacy alias kept for the branding renders.
    static let space = ground

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

    // One hand-rolled layout for the live app AND the docs renders — no
    // NavigationSplitView, so no system material to fight (it rendered white
    // offscreen) and the concept's sidebar is exactly what ships.
    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
            LinearGradient(
                colors: [Self.orange, Self.pink, Self.violet, Self.cyan],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: 3)
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(Self.ground)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar

    private func navGroup(_ label: String, _ tabs: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(Self.ink3)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 5)
            ForEach(tabs) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(item == tab ? Self.violet : Self.ink3)
                            .frame(width: 16)
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(item == tab ? Self.ink : Self.ink2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(item == tab ? Self.violet.opacity(0.10) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var permissionsLine: String {
        if demo { return "mic ✓ · access ✓" }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "✓" : "✗"
        let ax = TextInjector.isTrusted(promptIfNeeded: false) ? "✓" : "✗"
        return "mic \(mic) · access \(ax)"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                DiscoIconView(showsPlate: false)
                    .frame(width: 22, height: 22)
                Text("Waveform")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.ink)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            navGroup("SPEAK", [.home, .history, .scratchpad])
            navGroup("TEACH IT", [.dictionary, .prompts, .snippets])
            navGroup("TUNE", [.settings])

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text(permissionsLine)
                Text("100% on-device")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Self.ink3)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .padding(12)
        .frame(width: 208)
        .background(Self.pane)
        .overlay(alignment: .trailing) {
            Self.lineSoft.frame(width: 1)
        }
    }

    private var detail: some View {
        ZStack {
            Self.ground.ignoresSafeArea()
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
        case 5..<12: return "Good morning, \(name)."
        case 12..<17: return "Good afternoon, \(name)."
        default: return "Good evening, \(name)."
        }
    }

    private var dateLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
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
            VStack(alignment: .leading, spacing: 0) {
                // Eyebrow → greeting → sub: one confident type stack, no
                // gradients — the identity lives on the window's edge.
                HStack(spacing: 0) {
                    Text(dateLine.uppercased())
                    Text("  ·  ").foregroundStyle(DashboardView.ink3)
                    Text("EVERYTHING STAYS ON THIS MAC").foregroundStyle(DashboardView.cyan)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(DashboardView.ink3)
                .padding(.bottom, 12)

                Text(greeting)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(DashboardView.ink)
                    .padding(.bottom, 4)
                Text("Tap fn and talk — the words land where your cursor is.")
                    .font(.system(size: 13))
                    .foregroundStyle(DashboardView.ink3)
                    .padding(.bottom, 34)

                statStrip
                    .padding(.bottom, 40)

                if !topApps.isEmpty {
                    sectionLabel("TOP APPS")
                    HStack(alignment: .top, spacing: 28) {
                        let leader = max(topApps.first?.words ?? 1, 1)
                        ForEach(topApps, id: \.name) { app in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DashboardView.ink)
                                Text("\(app.words) words")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(DashboardView.ink3)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(DashboardView.line)
                                    Capsule().fill(DashboardView.violet)
                                        .frame(width: 120 * CGFloat(app.words) / CGFloat(leader))
                                }
                                .frame(width: 120, height: 2)
                                .padding(.top, 5)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }

                if !history.records.isEmpty {
                    sectionLabel("RECENT")
                    VStack(spacing: 0) {
                        ForEach(history.records.prefix(4)) { record in
                            HistoryRow(record: record)
                        }
                    }
                    .overlay(alignment: .bottom) { DashboardView.lineSoft.frame(height: 1) }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(DashboardView.ink3)
            .padding(.bottom, 14)
    }

    /// The mock's hairline-ruled strip: one bordered container, four cells
    /// separated by 1px rules, a small accent dot per label — the only color
    /// in the block.
    private var statStrip: some View {
        HStack(spacing: 0) {
            statCell("WORDS DICTATED", "\(history.totalWords.formatted())", DashboardView.orange)
            DashboardView.lineSoft.frame(width: 1)
            statCell("DICTATIONS", "\(history.totalDictations)", DashboardView.pink)
            DashboardView.lineSoft.frame(width: 1)
            statCell("THIS WEEK", "\(history.wordsThisWeek.formatted())", DashboardView.violet, unit: "words")
            DashboardView.lineSoft.frame(width: 1)
            statCell(
                "SPEED",
                history.averageWordsPerMinute > 0 ? "\(history.averageWordsPerMinute)" : "—",
                DashboardView.cyan,
                unit: history.averageWordsPerMinute > 0 ? "wpm" : nil
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(DashboardView.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.lineSoft, lineWidth: 1))
    }

    private func statCell(_ label: String, _ value: String, _ dot: Color, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(DashboardView.ink3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DashboardView.ink)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardView.ink3)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DashboardView.ink)
            Text("One term per line — names, jargon, acronyms. The recognizer is biased toward these from your next dictation. Saved automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $dictionaryText)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(DashboardView.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.lineSoft, lineWidth: 1))
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
                            .background(Capsule().fill(DashboardView.card))
                            .overlay(Capsule().strokeBorder(DashboardView.lineSoft, lineWidth: 1))
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DashboardView.ink)
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
                                    .foregroundStyle(DashboardView.cyan)
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
                            .foregroundStyle(DashboardView.pink.opacity(0.85))
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
                        .background(RoundedRectangle(cornerRadius: 12).fill(DashboardView.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.lineSoft, lineWidth: 1))
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
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DashboardView.ink)
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
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(record.date, format: .dateTime.hour().minute())
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(DashboardView.ink3)
                    .frame(width: 52, alignment: .leading)
                Text(record.text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DashboardView.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(copied ? "copied ✓" : (record.appName ?? "\(record.wordCount)w"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(copied ? DashboardView.cyan : DashboardView.violet)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { DashboardView.lineSoft.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy")
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DashboardView.ink)
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
                                        .foregroundStyle(DashboardView.cyan)
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
                                        .foregroundStyle(DashboardView.pink.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(DashboardView.card))
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DashboardView.ink)
            Text("A local drafting space — click in, dictate long rambles here, shape them, then copy where they belong. Autosaved on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $pad.text)
                .font(.system(size: 14, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(DashboardView.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardView.lineSoft, lineWidth: 1))
        }
        .padding(28)
    }
}
