import AppKit
import WaveformCore

// CLI modes used for headless verification (no HUD, no hotkey):
//   waveform --selftest ["text"]   synthesize speech with `say`, transcribe it, print pipeline output
//   waveform --render-hud <path>   render the HUD view to a PNG for design review
let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    if let index = arguments.firstIndex(of: "--selftest") {
        let text = arguments.indices.contains(index + 1)
            ? arguments[(index + 1)...].joined(separator: " ")
            : "Um okay so basically I wanted to explain that we should probably move this to next week"
        SelfTest.runAndExit(text: text)
    } else if let index = arguments.firstIndex(of: "--render-hud"), arguments.indices.contains(index + 1) {
        HUDSnapshot.renderAndExit(to: arguments[index + 1])
    } else if let index = arguments.firstIndex(of: "--render-settings"), arguments.indices.contains(index + 1) {
        HUDSnapshot.renderSettingsAndExit(to: arguments[index + 1])
    } else if let index = arguments.firstIndex(of: "--render-hud-compact"), arguments.indices.contains(index + 1) {
        HUDSnapshot.renderCompactAndExit(to: arguments[index + 1])
    } else if let index = arguments.firstIndex(of: "--export-iconset"), arguments.indices.contains(index + 1) {
        IconExporter.exportIconsetAndExit(to: arguments[index + 1])
    } else if let index = arguments.firstIndex(of: "--render-icon"), arguments.indices.contains(index + 1) {
        let pixels = arguments.indices.contains(index + 2) ? Int(arguments[index + 2]) ?? 512 : 512
        IconExporter.exportPreviewAndExit(to: arguments[index + 1], pixels: pixels)
    } else if arguments.contains("--diagnose") {
        Diagnostics.runAndExit()
    } else if arguments.contains("--fm-check") {
        FoundationModelCheck.runAndExit()
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
