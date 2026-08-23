import AppKit
import SwiftUI

/// Renders the HUD to a PNG for design review without showing any window.
public enum HUDSnapshot {
    @MainActor
    public static func renderAndExit(to path: String) {
        _ = NSApplication.shared

        let state = HUDState()
        state.transcript = "Okay, so basically, I wanted to explain that we should move this to next week."
        state.level = 0.75

        // A desktop-like backdrop so the review image shows the HUD in context.
        let scene = ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.08, blue: 0.20),
                    Color(red: 0.03, green: 0.02, blue: 0.08),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            HUDView(state: state, frozenTime: 1.85)
                .padding(40)
        }
        .frame(width: 560, height: 260)

        let hosting = NSHostingView(rootView: scene)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 260)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // Give SwiftUI a runloop turn to commit the render tree, then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("FAIL: no bitmap rep")
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                print("FAIL: no png data")
                exit(1)
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("Wrote \(path)")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
