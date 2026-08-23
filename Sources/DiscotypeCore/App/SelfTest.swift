import AVFoundation
import Foundation

/// Headless end-to-end check of the real pipeline (minus microphone and
/// injection): synthesize speech with `say`, push the audio through the same
/// engine/feed/finish path the live app uses, then run the cleaner.
/// Exits 0 when a non-empty cleaned transcript is produced.
public enum SelfTest {
    public static func runAndExit(text: String) {
        Task {
            let code = await run(text: text)
            exit(code)
        }
        dispatchMain()
    }

    private static func run(text: String) async -> Int32 {
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("discotype-selftest.aiff")

        print("[1/4] Synthesizing speech with `say`: \"\(text)\"")
        do {
            try synthesize(text: text, to: audioURL)
        } catch {
            print("FAIL: say failed: \(error)")
            return 1
        }

        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"))

        print("[2/4] Preparing engine (checks/downloads the on-device model)…")
        do {
            try await engine.prepare()
        } catch {
            print("FAIL: engine prepare: \(error)")
            return 1
        }

        print("[3/4] Streaming audio through the live-session path…")
        do {
            do {
                try await engine.startSession { update in
                    if !update.volatile.isEmpty {
                        print("  volatile: \(update.display)")
                    }
                }
            } catch {
                print("FAIL[startSession]: \(error)")
                return 1
            }

            guard let format = await engine.preferredAudioFormat else {
                print("FAIL: no preferred audio format")
                return 1
            }
            print("  analyzer format: \(format)")
            let file = try AVAudioFile(forReading: audioURL)
            print("  file format: \(file.processingFormat), frames: \(file.length)")
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
                print("FAIL: cannot build converter \(file.processingFormat) → \(format)")
                return 1
            }
            converter.primeMethod = .none

            let chunkFrames: AVAudioFrameCount = 4096
            while file.framePosition < file.length {
                guard let chunk = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: chunkFrames
                ) else { break }
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                try file.read(into: chunk, frameCount: min(chunkFrames, remaining))
                if chunk.frameLength == 0 { break }
                if let converted = AudioCaptureService.convert(buffer: chunk, with: converter, to: format) {
                    engine.feed(converted)
                }
            }
            // Trailing silence so the model has a clean utterance boundary.
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                silence.frameLength = silence.frameCapacity
                engine.feed(silence)
            }

            print("[4/4] Finalizing…")
            let raw: String
            do {
                raw = try await engine.finishSession()
            } catch {
                print("FAIL[finishSession]: \(error)")
                return 1
            }
            let cleaned = TextCleaner().clean(raw)

            print("")
            print("RAW:     \(raw)")
            print("CLEANED: \(cleaned)")

            guard !cleaned.isEmpty else {
                print("FAIL: empty transcript")
                return 1
            }
            print("SELFTEST PASS")
            return 0
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }

    private static func synthesize(text: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SelfTest", code: Int(process.terminationStatus))
        }
    }
}
