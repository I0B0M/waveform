import Foundation
import FoundationModels

/// CLI probe: is Apple's on-device LLM usable on this Mac right now?
/// (Requires Apple Intelligence to be enabled in System Settings.)
public enum FoundationModelCheck {
    public static func runAndExit() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            print("FoundationModels: AVAILABLE — on-device LLM ready")
            exit(0)
        case .unavailable(let reason):
            print("FoundationModels: UNAVAILABLE — \(String(describing: reason))")
            exit(2)
        @unknown default:
            print("FoundationModels: unknown availability state")
            exit(2)
        }
    }
}
