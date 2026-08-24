import Foundation

/// What a finished dictation should become.
///
/// Pure data. The decision used to live inline in `DictationCoordinator.stop()`
/// as a six-branch ladder interleaved with HUD updates and `await`s, which made
/// it impossible to test and easy to leak state through — the ✨ button's armed
/// flag survived two early returns and silently rewrote the *next* dictation.
/// Separating the decision from its execution makes the ordering rules
/// verifiable without a microphone or a model.
enum DictationPlan: Equatable {
    /// Insert this text unchanged.
    case insert(String)
    /// Insert it, but tell the user why it wasn't transformed.
    case insertWithNotice(String, notice: String)
    /// A snippet trigger matched; insert its expansion.
    case snippet(String)
    /// Run the on-device model over `subject`; on failure insert `fallback`.
    case rewrite(kind: DictationCommand.Kind, subject: String, fallback: String)
    /// Pour `input` into a saved prompt shape.
    case template(id: UUID, input: String, fallback: String)
    /// Apply a spoken instruction to the text the user had selected.
    case transformSelection(selection: String, instruction: String)
    /// Resolve spoken self-corrections ("…at 5, no wait, 6").
    case resolveCorrections(String)
    /// A command with nothing to act on — insert nothing, explain instead.
    case abort(notice: String)
}

struct DictationContext {
    var text: String
    /// Set when the ✨ button was pressed. Passed in rather than read from
    /// coordinator state so it cannot outlive one dictation.
    var forced: DictationCommand.Kind?
    var selection: String?
    var snippets: [Snippet] = []
    var templates: [PromptTemplate] = []
    var aiEnabled: Bool = true
    var modelAvailable: Bool = true
}

enum DictationPlanner {
    private static let modelOffNotice = "Apple Intelligence is off — inserted as spoken"

    /// Most explicit intent wins. Each branch is mutually exclusive: a snippet
    /// is not a command, a command is not ordinary speech.
    static func plan(for context: DictationContext) -> DictationPlan {
        let text = context.text

        // 0. The ✨ button — an unmistakable request, so it outranks anything
        //    the words might look like.
        if let kind = context.forced {
            guard context.modelAvailable else {
                return .insertWithNotice(text, notice: modelOffNotice)
            }
            return .rewrite(kind: kind, subject: context.selection ?? text, fallback: text)
        }

        // 1. Voice snippet ("insert my calendar link").
        if let expansion = SnippetMatcher.expansion(for: text, in: context.snippets) {
            return .snippet(expansion)
        }

        guard context.aiEnabled else { return .insert(text) }

        // 2. One of the user's own prompt shapes ("//plan …").
        if let hit = CommandDetector.templateCommand(
            in: text,
            triggers: context.templates.map(\.trigger)
        ), let template = context.templates.first(where: {
            $0.trigger.caseInsensitiveCompare(hit.trigger) == .orderedSame
        }) {
            let input = hit.payload.isEmpty ? (context.selection ?? "") : hit.payload
            guard !input.isEmpty else {
                return .abort(notice: "Nothing to work on — say the details after the command")
            }
            guard context.modelAvailable else {
                return .insertWithNotice(input, notice: modelOffNotice)
            }
            return .template(id: template.id, input: input, fallback: input)
        }

        // 3. Built-in explicit command ("//prompt …", "//better …").
        if let command = CommandDetector.detect(in: text), command.wasExplicit {
            let payload = command.payload.isEmpty ? (context.selection ?? "") : command.payload
            guard !payload.isEmpty else {
                return .abort(notice: "Nothing to work on — say the text after the command")
            }
            guard context.modelAvailable else {
                return .insertWithNotice(payload, notice: modelOffNotice)
            }
            // "//better — make it shorter" with text selected: the payload is
            // the instruction and the selection is the subject.
            if let selection = context.selection,
               !command.payload.isEmpty,
               CommandDetector.selectionInstruction(in: command.payload) != nil {
                return .transformSelection(selection: selection, instruction: command.payload)
            }
            return .rewrite(kind: command.kind, subject: payload, fallback: payload)
        }

        // Everything below needs the model; without it, insert what was said.
        guard context.modelAvailable else { return .insert(text) }

        // 4. A spoken instruction with a selection to apply it to.
        if let selection = context.selection,
           let instruction = CommandDetector.selectionInstruction(in: text) {
            return .transformSelection(selection: selection, instruction: instruction)
        }

        // 5. Natural-language command ("make this message better, …").
        if let command = CommandDetector.detect(in: text) {
            return .rewrite(kind: command.kind, subject: command.payload, fallback: command.payload)
        }

        // 6. Spoken self-corrections.
        if SelfCorrection.hasMarkers(text) {
            return .resolveCorrections(text)
        }

        return .insert(text)
    }
}
