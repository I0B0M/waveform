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
final class HUDController: NSObject {
    let state = HUDState()
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPolish: ((Bool) -> Void)?
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

        let hosting = NSHostingView(rootView: HUDView(
            state: state,
            onFinish: { [weak self] in self?.onFinish?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onPolish: { [weak self] promptMode in self?.onPolish?(promptMode) }
        ))
        // Fixed stage big enough for the expanded pill; the SwiftUI content
        // animates between compact and expanded inside it.
        hosting.setFrameSize(NSSize(width: 560, height: 150))

        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 560, height: 150)),
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
        // Clickable (✓/✕) and draggable, but still never key/main — clicks
        // land on the buttons without stealing focus from the target app.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        // The pill appears where the attention already is: at the pointer,
        // slightly below it, clamped to the pointer's screen. (The panel is a
        // larger stage than the visible pill, which sits bottom-center of it —
        // offsets account for that.) Drag still works for the session; the
        // next show returns to the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let size = panel.frame.size
        let visible = screen.visibleFrame
        // The visible pill is ~42pt tall at the stage's bottom edge; put it
        // just under the pointer.
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height + 8
        x = min(max(x, visible.minX - size.width / 2 + 130), visible.maxX - size.width / 2 - 130)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

}
