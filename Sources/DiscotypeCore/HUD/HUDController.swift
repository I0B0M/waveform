import AppKit
import SwiftUI

/// Panel that can never become key or main — it must not steal focus from the
/// app receiving the dictated text.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating HUD window. Shown above everything (status-bar level),
/// on every Space including full-screen apps, click-through, never key.
@MainActor
final class HUDController {
    let state = HUDState()
    private var panel: HUDPanel?

    /// Build the panel and SwiftUI hosting tree ahead of time (app launch)
    /// so the first hotkey press doesn't pay the construction cost.
    func preload() {
        _ = ensurePanel()
    }

    func show() {
        state.reset()
        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: HUDView(state: state))
        hosting.setFrameSize(hosting.fittingSize)

        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        // Bottom-center of the screen the mouse is on (that's where the user
        // is working), floating above the Dock.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let size = panel.frame.size
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
