import AVFoundation
import QuartzCore

/// Captures microphone audio with AVAudioEngine, converts each buffer to the
/// format the transcription engine asked for, and reports a smoothed input
/// level for the waveform.
///
/// The engine only exists while dictation is active — `stop()` tears the whole
/// thing down, so an idle Waveform holds no audio hardware, timers, or taps
/// (zero background CPU / battery cost).
final class AudioCaptureService {
    /// Called on the audio thread with a buffer already in the target format.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called on the main queue, throttled, with a 0…1 input level.
    var onLevel: (@Sendable (Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var targetFormat: AVAudioFormat?

    /// Called when the audio graph could not be rebuilt after a device change,
    /// so the UI can say so instead of showing a listening pill that is deaf.
    var onCaptureLost: (@Sendable () -> Void)?

    // Level updates are throttled to ~30/s instead of one main-queue hop per
    // audio buffer (an improvement over Murmur, which enqueues per buffer).
    private let levelThrottle: TimeInterval = 1.0 / 30.0
    private var lastLevelPost: TimeInterval = 0

    enum CaptureError: Error {
        case converterCreationFailed
        case inputUnavailable
    }

    func start(targetFormat: AVAudioFormat?) throws {
        stop()
        self.targetFormat = targetFormat
        try startEngine()

        // Plugging in AirPods mid-sentence tears the graph out from under the
        // tap: buffers simply stop arriving, and without this the HUD keeps
        // animating at level zero while you talk into nothing.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard engine != nil else { return }
        Log.app.notice("audio configuration changed — rebuilding capture")
        do {
            try startEngine()
        } catch {
            Log.app.error("capture rebuild failed: \(String(describing: error), privacy: .public)")
            teardownEngine()
            onCaptureLost?()
        }
    }

    private func startEngine() throws {
        teardownEngine()
        let targetFormat = self.targetFormat

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.inputUnavailable
        }

        var converter: AVAudioConverter?
        if let targetFormat, targetFormat != tapFormat {
            guard let created = AVAudioConverter(from: tapFormat, to: targetFormat) else {
                throw CaptureError.converterCreationFailed
            }
            // No priming: keeps buffer timestamps aligned so the analyzer's
            // audio timeline doesn't drift (Apple's sample does the same).
            created.primeMethod = .none
            converter = created
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.publishLevel(from: buffer)

            if let converter, let targetFormat {
                if let converted = Self.convert(buffer: buffer, with: converter, to: targetFormat) {
                    self.onBuffer?(converted)
                }
            } else {
                self.onBuffer?(buffer)
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        targetFormat = nil
        teardownEngine()
    }

    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    // MARK: - Conversion

    static func convert(
        buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    // MARK: - Level metering

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastLevelPost >= levelThrottle else { return }
        lastLevelPost = now

        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        // Map -50 dBFS…0 dBFS to 0…1 so quiet rooms sit near zero.
        let db = 20 * log10(max(rms, .leastNonzeroMagnitude))
        let level = max(0, min(1, (db + 50) / 50))
        onLevel?(level)
    }
}
