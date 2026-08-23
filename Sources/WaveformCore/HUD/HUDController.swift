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
final class HUDController: NSObject, NSWindowDelegate {
    let state = HUDState()
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    private var panel: HUDPanel?
    private static let positionKey = "hudOriginV2"

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
            onCancel: { [weak self] in self?.onCancel?() }
        ))
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
        // Clickable (✓/✕) and draggable, but still never key/main — clicks
        // land on the buttons without stealing focus from the target app.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        // A dragged position is remembered (Wispr-style) as long as it is
        // still on a visible screen; otherwise bottom-center above the Dock.
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }

        let size = panel.frame.size
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    nonisolated public func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            UserDefaults.standard.set(
                NSStringFromPoint(panel.frame.origin),
                forKey: Self.positionKey
            )
        }
    }
}
