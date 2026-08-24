import Foundation

/// A saved prompt shape. You ramble, Waveform pours it into the template's
/// structure with the on-device model, and the finished prompt lands at your
/// cursor — the "talk to Claude" loop without the round trip through a chat box.
struct PromptTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Spoken after the slash marker: "double slash plan, we need to …"
    var trigger: String
    var title: String
    /// System instructions handed to the local model with your words as input.
    var instruction: String
}

enum PromptLibrary {
    /// Shipped defaults — the four shapes that come up most when dictating at
    /// an AI assistant. All editable, all deletable.
    static let defaults: [PromptTemplate] = [
        PromptTemplate(
            trigger: "plan",
            title: "Implementation plan",
            instruction: """
                Turn the user's spoken description into a clear implementation-plan \
                prompt for an AI coding assistant. State the goal in one line, then \
                list the concrete requirements and constraints they mentioned, then \
                note what should be verified when it's done. Preserve every \
                requirement; invent none. Reply with only the prompt.
                """
        ),
        PromptTemplate(
            trigger: "bug",
            title: "Bug report",
            instruction: """
                Turn the user's spoken description into a bug report: what they \
                expected, what actually happened, and the steps or context they \
                gave. Keep their facts exactly; do not speculate about causes they \
                did not mention. Reply with only the report.
                """
        ),
        PromptTemplate(
            trigger: "review",
            title: "PR description",
            instruction: """
                Turn the user's spoken description into a pull-request description: \
                a one-line summary, what changed and why, and anything a reviewer \
                should look at closely. Use only what they said. Reply with only \
                the description.
                """
        ),
        PromptTemplate(
            trigger: "ticket",
            title: "Ticket",
            instruction: """
                Turn the user's spoken description into a work ticket: a short \
                imperative title, a context paragraph, and acceptance criteria as \
                a checklist. Use only the details they gave. Reply with only the \
                ticket.
                """
        ),
    ]
}
