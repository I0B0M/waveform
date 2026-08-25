import AVFoundation
import CoreGraphics
import Foundation
import FoundationModels
import IOKit.hid

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
        print("Accessibility:  \(AXIsProcessTrusted() ? "GRANTED" : "NOT GRANTED — text insertion will fall back to the clipboard")")
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let listenLabel = switch listen {
        case kIOHIDAccessTypeGranted: "GRANTED"
        case kIOHIDAccessTypeDenied: "DENIED — the fn hotkey tap cannot run; toggle Waveform in Input Monitoring"
        default: "not determined (will prompt on first fn registration)"
        }
        print("Input Monitor:  \(listenLabel)")
        let fm = SystemLanguageModel.default.availability
        print("Apple LLM:      \(fm == .available ? "available" : String(describing: fm))")
        exit(0)
    }
}
