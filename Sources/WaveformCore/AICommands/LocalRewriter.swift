import Foundation
import FoundationModels

/// On-device rewriting via Apple's Foundation Models (Apple Intelligence).
/// Free, private, no network. Guards borrowed from hard experience with
/// on-device LLMs (Murmur's formatter): timeout, preamble rejection, and a
/// length-ratio sanity check — on ANY failure the caller falls back to the
/// untouched dictated text, so this feature can only ever add value.
final class LocalRewriter {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    private static let improveInstructions = """
        You restructure raw dictated text. Improve the clarity, grammar, \
        structure, and flow. Keep the author's meaning, voice, and all of \
        their facts. Do not add new information, do not answer questions that \
        appear in the text, and do not comment on the text. Reply with ONLY \
        the rewritten text — no preamble, no quotes.
        """

    private static let promptInstructions = """
        You turn a rambling spoken description into a clear, well-structured \
        prompt the user can paste into an AI assistant. Preserve every \
        requirement they mention. Organize it with a short goal statement \
        followed by specifics. Reply with ONLY the prompt text — no preamble, \
        no quotes, no commentary.
        """

    /// Warm the model at app launch so the first command doesn't stall.
    static func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession(instructions: improveInstructions)
        session.prewarm()
    }

    /// Compose the shared context block injected into rewrite prompts:
    /// where the text is going, what surrounds the caret, the tone dial, and
    /// the learned style card. Everything here was read on-device.
    static func contextBlock(field: FieldContext?, tone: String?, styleCard: String) -> String {
        var lines: [String] = []
        if let field, !field.isSecure {
            if let app = field.appName { lines.append("Destination app: \(app)") }
            if let title = field.windowTitle { lines.append("Window: \(title)") }
            if !field.before.isEmpty {
                lines.append("Text immediately before the cursor:\n…\(field.before.suffix(280))")
            }
        }
        if let tone { lines.append("Requested tone: \(tone)") }
        if !styleCard.isEmpty { lines.append("The author's writing style:\n\(styleCard)") }
        guard !lines.isEmpty else { return "" }
        return "\n\n[Context — use it to match tone, continue naturally, and spell names "
            + "the way the surrounding text does. Never mention or repeat it.]\n"
            + lines.joined(separator: "\n")
    }

    /// Returns the rewritten text, or nil when the caller should fall back to
    /// the raw payload.
    func rewrite(_ command: DictationCommand, context: String = "") async -> String? {
        guard Self.isAvailable else {
            NSLog("Waveform: on-device model unavailable — cannot rewrite")
            return nil
        }

        let instructions = command.kind == .improve
            ? Self.improveInstructions
            : Self.promptInstructions

        do {
            let output: String = try await withThrowingTimeout(seconds: 10) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: command.payload + context)
                return response.content
            }
            return Self.validated(output, against: command)
        } catch {
            NSLog("Waveform: local rewrite failed (%@) — falling back to raw text", String(describing: error))
            return nil
        }
    }

    private static let transformInstructions = """
        You edit text. Apply the user's instruction to the provided text. \
        Keep everything the instruction doesn't cover unchanged — same facts, \
        same voice. Do not comment on the text or the instruction. Reply with \
        ONLY the edited text — no preamble, no quotes.
        """

    /// Selection mode: apply a spoken instruction to selected text.
    /// Returns nil when the caller should leave the selection untouched.
    func transform(selection: String, instruction: String, context: String = "") async -> String? {
        guard Self.isAvailable else { return nil }
        do {
            let output: String = try await withThrowingTimeout(seconds: 12) {
                let session = LanguageModelSession(instructions: Self.transformInstructions)
                let response = try await session.respond(
                    to: "Instruction: \(instruction)\n\nText:\n\(selection)" + context
                )
                return response.content
            }
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let lowered = text.lowercased()
            let preambles = ["here is", "here's", "sure,", "sure!", "certainly", "as an ai", "i can't", "i cannot"]
            guard !preambles.contains(where: { lowered.hasPrefix($0) }) else { return nil }
            let ratio = Double(text.count) / Double(max(selection.count, 1))
            guard ratio >= 0.1, ratio <= 5.0 else { return nil }
            return text
        } catch {
            NSLog("Waveform: selection transform failed (%@)", String(describing: error))
            return nil
        }
    }

    private static let correctionInstructions = """
        The text is a spoken transcript containing self-corrections (phrases \
        like "no wait", "scratch that", "I meant"). Apply the speaker's \
        corrections: keep what they corrected TO, remove what they corrected \
        AWAY FROM along with the correction phrases themselves. Change \
        absolutely nothing else — same words, same order, same punctuation. \
        Reply with ONLY the corrected text.
        """

    /// Resolve spoken self-corrections. Nil = use the text as dictated.
    func resolveCorrections(in text: String) async -> String? {
        guard Self.isAvailable else { return nil }
        do {
            let output: String = try await withThrowingTimeout(seconds: 8) {
                let session = LanguageModelSession(instructions: Self.correctionInstructions)
                let response = try await session.respond(to: text)
                return response.content
            }
            let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { return nil }
            let lowered = result.lowercased()
            let preambles = ["here is", "here's", "sure,", "sure!", "certainly", "as an ai", "i can't", "i cannot"]
            guard !preambles.contains(where: { lowered.hasPrefix($0) }) else { return nil }
            // Corrections remove words — the result must not grow, and must
            // not collapse to a stub.
            let ratio = Double(result.count) / Double(max(text.count, 1))
            guard ratio >= 0.3, ratio <= 1.05 else { return nil }
            return result
        } catch {
            NSLog("Waveform: correction resolve failed (%@)", String(describing: error))
            return nil
        }
    }

    /// Pour spoken input into one of the user's prompt templates.
    func build(from template: PromptTemplate, input: String, context: String = "") async -> String? {
        guard Self.isAvailable else {
            NSLog("Waveform: on-device model unavailable — cannot build prompt")
            return nil
        }
        do {
            let output: String = try await withThrowingTimeout(seconds: 14) {
                let session = LanguageModelSession(instructions: template.instruction)
                let response = try await session.respond(to: input + context)
                return response.content
            }
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let lowered = text.lowercased()
            let preambles = ["here is", "here's", "sure,", "sure!", "certainly", "as an ai", "i can't", "i cannot"]
            guard !preambles.contains(where: { lowered.hasPrefix($0) }) else {
                NSLog("Waveform: template rejected — model replied with a preamble")
                return nil
            }
            // A template legitimately expands a ramble a long way, but it must
            // not collapse to a stub.
            let ratio = Double(text.count) / Double(max(input.count, 1))
            guard ratio >= 0.3 else {
                NSLog("Waveform: template rejected — output collapsed (ratio %.2f)", ratio)
                return nil
            }
            return text
        } catch {
            NSLog("Waveform: template build failed (%@)", String(describing: error))
            return nil
        }
    }

    private static let composeInstructions = """
        You write text that will be inserted at the user's cursor. Follow \
        the user's spoken instruction to draft it. When source material is \
        provided (an email, a message, a selection), treat it as what the \
        user is responding to or drawing from — do not repeat it back. \
        Write in the user's voice, matching the tone the context implies. \
        Reply with ONLY the text to insert — no preamble, no quotes, no \
        commentary.
        """

    /// AI mode & reply-to-selection: generate NEW text from an instruction
    /// plus optional source material. Nil = the caller should explain rather
    /// than insert.
    func compose(instruction: String, material: String, context: String = "") async -> String? {
        guard Self.isAvailable else { return nil }
        let prompt = "Instruction: \(instruction)"
            + (material.isEmpty ? "" : "\n\nSource material:\n\(material)")
            + context
        do {
            let output: String = try await withThrowingTimeout(seconds: 15) {
                let session = LanguageModelSession(instructions: Self.composeInstructions)
                let response = try await session.respond(to: prompt)
                return response.content
            }
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count < 4000 else { return nil }
            let lowered = text.lowercased()
            let preambles = ["here is", "here's", "sure,", "sure!", "certainly", "as an ai", "i can't", "i cannot"]
            guard !preambles.contains(where: { lowered.hasPrefix($0) }) else { return nil }
            return text
        } catch {
            Log.app.error("compose failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Output guards

    private static func validated(_ output: String, against command: DictationCommand) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The model answered like an assistant instead of transforming.
        let lowered = text.lowercased()
        let preambles = ["here is", "here's", "sure,", "sure!", "certainly", "as an ai", "i can't", "i cannot"]
        if preambles.contains(where: { lowered.hasPrefix($0) }) {
            NSLog("Waveform: rewrite rejected — model replied with a preamble")
            return nil
        }

        // Length sanity: an "improved" text shouldn't shrink to a stub or
        // balloon with invented content. Prompts get more slack upward
        // (structure adds headers) but must not collapse.
        let ratio = Double(text.count) / Double(max(command.payload.count, 1))
        // A restructure can legitimately grow (headings, bullets); building a
        // prompt from a short ramble grows a lot more.
        switch command.kind {
        case .improve:
            guard ratio >= 0.3, ratio <= 3.5 else {
                NSLog("Waveform: rewrite rejected — length ratio %.2f", ratio)
                return nil
            }
        case .createPrompt:
            guard ratio >= 0.3, ratio <= 10.0 else {
                NSLog("Waveform: prompt rejected — length ratio %.2f", ratio)
                return nil
            }
        }
        return text
    }
}
