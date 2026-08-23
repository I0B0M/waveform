import AVFoundation
import Foundation
import FoundationModels

/// `Waveform.app/Contents/MacOS/Waveform --diagnose` — reports the grants and
/// capabilities THIS bundle identity actually holds, for debugging "text
/// doesn't insert" style issues from the command line.
public enum Diagnostics {
    public static func runAndExit() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micLabel: String
        switch mic {
        case .authorized: micLabel = "GRANTED"
        case .notDetermined: micLabel = "not determined (will prompt)"
        case .denied: micLabel = "DENIED"
        case .restricted: micLabel = "restricted"
        @unknown default: micLabel = "unknown"
        }
        print("Microphone:     \(micLabel)")
        print("Accessibility:  \(AXIsProcessTrusted() ? "GRANTED" : "NOT GRANTED — insertion and double-tap ⌃ will not work")")
        let fm = SystemLanguageModel.default.availability
        print("Apple LLM:      \(fm == .available ? "available" : String(describing: fm))")
        exit(0)
    }
}
