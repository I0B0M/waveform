import AVFoundation
import Foundation
import QuartzCore

/// Headless end-to-end check of the real pipeline (minus microphone and
/// injection): synthesize speech with `say`, push the audio through the same
/// engine/feed/finish path the live app uses, then run the cleaner.
///
/// Runs TWO sessions and prints per-stage timings — session 2 shows the warm
/// path a user actually feels on every dictation after the first.
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
        let prepareStart = CACurrentMediaTime()
        do {
            try await engine.prepare()
        } catch {
            print("FAIL: engine prepare: \(error)")
            return 1
        }
        print("  prepare: \(ms(since: prepareStart))")

        var lastCleaned = ""
        for sessionIndex in 1...2 {
            print("[3/4] Session \(sessionIndex): streaming audio through the live-session path…")
            do {
                lastCleaned = try await runSession(engine: engine, audioURL: audioURL)
            } catch {
                print("FAIL[session \(sessionIndex)]: \(error)")
                return 1
            }
        }

        guard !lastCleaned.isEmpty else {
            print("FAIL: empty transcript")
            return 1
        }
        print("SELFTEST PASS")
        return 0
    }

    private static func runSession(
        engine: AppleSpeechEngine,
        audioURL: URL
    ) async throws -> String {
        let sessionStart = CACurrentMediaTime()
        let firstResultAt = LockedBox<Double?>(nil)

        try await engine.startSession(contextualStrings: []) { update in
            if firstResultAt.value == nil {
                firstResultAt.value = CACurrentMediaTime()
            }
        }
        let startedAt = CACurrentMediaTime()
        print("  startSession: \(ms(from: sessionStart, to: startedAt))")

        guard let format = await engine.preferredAudioFormat else {
            throw NSError(domain: "SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "no preferred audio format"])
        }
        let file = try AVAudioFile(forReading: audioURL)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw NSError(domain: "SelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot build converter"])
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
        let fedAt = CACurrentMediaTime()

        if let first = firstResultAt.value {
            print("  first result: \(ms(from: startedAt, to: first)) after start")
        }

        print("[4/4] Finalizing…")
        let raw = try await engine.finishSession()
        print("  finalize: \(ms(since: fedAt))")

        let cleaned = TextCleaner().clean(raw)
        print("  RAW:     \(raw)")
        print("  CLEANED: \(cleaned)")
        return cleaned
    }

    private static func ms(since start: Double) -> String {
        ms(from: start, to: CACurrentMediaTime())
    }

    private static func ms(from start: Double, to end: Double) -> String {
        String(format: "%.0f ms", (end - start) * 1000)
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

/// Tiny thread-safe box (also used for the audio-thread fast path in
/// AppleSpeechEngine).
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        stored = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
