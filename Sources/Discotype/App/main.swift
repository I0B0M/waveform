import AppKit
import DiscotypeCore

// CLI modes used for headless verification (no HUD, no hotkey):
//   discotype --selftest ["text"]   synthesize speech with `say`, transcribe it, print pipeline output
//   discotype --render-hud <path>   render the HUD view to a PNG for design review
let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    if let index = arguments.firstIndex(of: "--selftest") {
        let text = arguments.indices.contains(index + 1)
            ? arguments[(index + 1)...].joined(separator: " ")
            : "Um okay so basically I wanted to explain that we should probably move this to next week"
        SelfTest.runAndExit(text: text)
    } else if let index = arguments.firstIndex(of: "--render-hud"), arguments.indices.contains(index + 1) {
        HUDSnapshot.renderAndExit(to: arguments[index + 1])
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
