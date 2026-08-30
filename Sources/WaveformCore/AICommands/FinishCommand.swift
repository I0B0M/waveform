import Foundation

/// Hands-free finish commands: the last thing you say can BE the action.
///
///   "… and that's the plan. Send it."   → insert, then press the app's send key
///   "… actually. Scratch that."         → discard the whole dictation
///
/// The safety rule that makes this shippable: the phrase only counts when it
/// stands as its own sentence at the very end — preceded by sentence
/// punctuation (the recognizer reliably adds it after a pause) or being the
/// entire utterance. "…please send it" mid-flow is content, not a command.
enum FinishCommand: Equatable {
    case send
    case scratch

    private static let phrases: [(FinishCommand, [String])] = [
        (.send, ["send it", "send that", "and send it", "send message"]),
        (.scratch, ["scratch that", "cancel that", "discard that", "never mind"]),
    ]

    /// Recognition bias so the command words are heard as themselves.
    static let vocabularyHints = ["send it", "scratch that"]

    /// Detects a trailing finish command. Returns the text with the command
    /// removed, and the command — or (unchanged, nil).
    static func strip(from text: String) -> (text: String, command: FinishCommand?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (text, nil) }

        // Work on a tail with trailing punctuation removed: "Send it." / "send it!"
        var tailEnd = trimmed.endIndex
        while tailEnd > trimmed.startIndex {
            let previous = trimmed.index(before: tailEnd)
            let character = trimmed[previous]
            if character.isPunctuation || character.isWhitespace {
                tailEnd = previous
            } else {
                break
            }
        }
        let body = trimmed[..<tailEnd]

        for (command, variants) in phrases {
            for phrase in variants {
                guard body.count >= phrase.count else { continue }
                let start = body.index(body.endIndex, offsetBy: -phrase.count)
                guard body[start...].lowercased() == phrase else { continue }

                // Own-sentence rule: what precedes must be a sentence break
                // (or nothing at all).
                // Deliberately strict: only sentence punctuation counts. A
                // comma is NOT a boundary — "when you're done, send it" is a
                // sentence someone actually dictates as content, while a real
                // command pause reliably earns a period from the recognizer.
                var cursor = start
                var boundaryOK = false
                while cursor > body.startIndex {
                    cursor = body.index(before: cursor)
                    let character = body[cursor]
                    if character.isWhitespace { continue }
                    boundaryOK = ".!?…\n".contains(character)
                    break
                }
                if cursor == body.startIndex, start == body.startIndex {
                    boundaryOK = true                  // the command IS the utterance
                }
                guard boundaryOK else { continue }

                var remainder = String(body[..<start])
                remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                // Drop a dangling comma the pause left behind.
                while let last = remainder.last, last == "," || last == " " {
                    remainder = String(remainder.dropLast())
                }
                return (remainder, command)
            }
        }
        return (text, nil)
    }
}
