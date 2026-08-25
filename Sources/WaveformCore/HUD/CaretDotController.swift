import AppKit
import SwiftUI

/// Apple's one great dictation idea, copied by nobody: feedback at the
/// insertion point. While recording, a small pulsing disco dot floats beside
/// the caret of the focused field, answering "where will my words land?"
/// without the user's eyes leaving their work.
///
/// Strictly best-effort: when the caret's bounds can't be read (non-native
/// apps, no focused field), the dot simply doesn't appear — it never guesses.
@MainActor
final class CaretDotController {
    private var panel: NSPanel?
    private var refreshTask: Task<Void, Never>?

    /// Start following the caret. `caretRect` is polled (Cocoa screen
    /// coordinates) so the dot tracks as the field scrolls or reflows.
    func show(caretRect: @escaping @MainActor () -> CGRect?) {
        hide()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let rect = caretRect() {
                    self.place(at: rect)
                } else {
                    self.panel?.orderOut(nil)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func hide() {
        refreshTask?.cancel()
        refreshTask = nil
        panel?.orderOut(nil)
    }

    private func place(at caret: CGRect) {
        let panel = ensurePanel()
        // Beside the caret, vertically centered on it.
        let origin = NSPoint(
            x: caret.maxX + 4,
            y: caret.midY - Self.dotPanelSize / 2
        )
        panel.setFrameOrigin(origin)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private static let dotPanelSize: CGFloat = 22

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let size = NSSize(width: Self.dotPanelSize, height: Self.dotPanelSize)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: CaretDotView())
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}

private struct CaretDotView: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(red: 0.72, green: 0.20, blue: 1.00).opacity(pulsing ? 0 : 0.55), lineWidth: 1.5)
                .frame(width: pulsing ? 20 : 7, height: pulsing ? 20 : 7)
            Circle()
                .fill(Color(red: 0.72, green: 0.20, blue: 1.00))
                .frame(width: 7, height: 7)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}
