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

    /// Returns the rewritten text, or nil when the caller should fall back to
    /// the raw payload.
    func rewrite(_ command: DictationCommand) async -> String? {
        guard Self.isAvailable else { return nil }

        let instructions = command.kind == .improve
            ? Self.improveInstructions
            : Self.promptInstructions

        do {
            let output: String = try await withThrowingTimeout(seconds: 10) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: command.payload)
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
    func transform(selection: String, instruction: String) async -> String? {
        guard Self.isAvailable else { return nil }
        do {
            let output: String = try await withThrowingTimeout(seconds: 12) {
                let session = LanguageModelSession(instructions: Self.transformInstructions)
                let response = try await session.respond(
                    to: "Instruction: \(instruction)\n\nText:\n\(selection)"
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

    // MARK: - Output guards

    private static func validated(_ output: String, against command: DictationCommand) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The model answered like an assistant instead of transforming.
        let lowered = text.lowercased()
        let preambles = ["here is", "here's", "sure,", "sure!", "certainly", "as an ai", "i can't", "i cannot"]
        if preambles.contains(where: { lowered.hasPrefix($0) }) {
            return nil
        }

        // Length sanity: an "improved" text shouldn't shrink to a stub or
        // balloon with invented content. Prompts get more slack upward
        // (structure adds headers) but must not collapse.
        let ratio = Double(text.count) / Double(max(command.payload.count, 1))
        switch command.kind {
        case .improve:
            guard ratio >= 0.35, ratio <= 2.0 else { return nil }
        case .createPrompt:
            guard ratio >= 0.3, ratio <= 4.0 else { return nil }
        }
        return text
    }
}
