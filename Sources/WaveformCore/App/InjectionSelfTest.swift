import AppKit
import ApplicationServices

/// End-to-end injection harness that runs INSIDE the granted, live app: it
/// opens a scratch window with a real NSTextView and pushes text through the
/// full `TextInjector.inject` pipeline — anchored AX write, verification,
/// continuation fitting territory — then checks what actually landed.
///
/// Triggered by a local distributed notification so the pipeline can be
/// exercised on demand without dictating:
///
///   notification name: com.ibrahim.waveform.debug.injection-selftest
///
/// Results go to the public unified log (category "selftest"), one PASS/FAIL
/// line per case. The harness only ever types into its own scratch window.
@MainActor
final class InjectionSelfTestRunner {
    static let shared = InjectionSelfTestRunner()

    private let injector = TextInjector()
    private let streamer = StreamingInserter()
    private var window: NSWindow?
    private var running = false

    func register() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ibrahim.waveform.debug.injection-selftest"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await InjectionSelfTestRunner.shared.run()
            }
        }
    }

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        Log.selftest.notice("injection self-test starting")

        guard TextInjector.isTrusted(promptIfNeeded: false) else {
            Log.selftest.error("SKIP — Accessibility not granted to this process")
            return
        }

        let textView = makeScratchWindow()
        // The whole harness depends on OUR window holding focus. Activation
        // is cooperative on modern macOS and can silently lose the race —
        // wait for frontmost to actually be us, retrying the activation.
        var frontmost = false
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier {
                frontmost = true
                break
            }
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard frontmost else {
            Log.selftest.error("SKIP — could not become the frontmost app (activation denied)")
            window?.orderOut(nil)
            window = nil
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let cases: [(name: String, text: String)] = [
            ("short", "Hello there."),
            ("punctuation", "It's \"quoted\" — with dashes; and (parens)!"),
            ("multiline", "Line one.\nLine two.\n• bullet three"),
            ("emoji", "Ship it 🙏 with 🎉 emoji 🚀"),
            ("long", String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)),
        ]

        var passed = 0
        for testCase in cases {
            let anchor = await verifiedAnchor(for: textView)
            let outcome = await injector.inject(
                testCase.text,
                method: .typeDirectly,
                targetBundleId: Bundle.main.bundleIdentifier,
                anchor: anchor
            )
            // The AX write is synchronous; typed events need a beat to land.
            try? await Task.sleep(nanoseconds: 300_000_000)
            let landed = textView.string
            let onClipboard = NSPasteboard.general.string(forType: .string) == testCase.text
            if landed == testCase.text, onClipboard {
                passed += 1
                Log.selftest.notice("PASS \(testCase.name, privacy: .public) via \(String(describing: outcome), privacy: .public) (clipboard ✓)")
            } else {
                Log.selftest.error("FAIL \(testCase.name, privacy: .public) via \(String(describing: outcome), privacy: .public) — landed \(landed.count, privacy: .public)/\(testCase.text.count, privacy: .public) chars, clipboard \(onClipboard, privacy: .public)")
            }
        }

        // Rapid-fire: three back-to-back injections must append in order.
        let anchor = await verifiedAnchor(for: textView)
        for index in 1...3 {
            _ = await injector.inject("part\(index) ", method: .typeDirectly, anchor: anchor)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if textView.string == "part1 part2 part3 " {
            passed += 1
            Log.selftest.notice("PASS rapid-fire ordering")
        } else {
            Log.selftest.error("FAIL rapid-fire — landed \(textView.string, privacy: .public)")
        }

        // Start-anchor fallback: focus sits on a window with NO text field
        // (the bare-Safari-page shape) — the words must fall back to the
        // element the dictation started at, never vanish.
        let anchorForBackground = await verifiedAnchor(for: textView)
        let decoy = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        decoy.title = "Decoy"
        decoy.isReleasedWhenClosed = false
        decoy.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let outcome = await injector.inject(
            "anchored while unfocused",
            method: .typeDirectly,
            targetBundleId: Bundle.main.bundleIdentifier,
            anchor: anchorForBackground
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        decoy.orderOut(nil)
        if textView.string == "anchored while unfocused" {
            passed += 1
            Log.selftest.notice("PASS anchored write with focus elsewhere via \(String(describing: outcome), privacy: .public)")
        } else {
            Log.selftest.error("FAIL anchored-unfocused via \(String(describing: outcome), privacy: .public) — landed \(textView.string.count, privacy: .public) chars")
        }

        // Live streaming, happy path: provisional text replaced in place,
        // then the final text wins with one last replace.
        if let streamAnchor = await verifiedAnchor(for: textView), streamer.begin(element: streamAnchor) {
            streamer.update("Hello wor")
            try? await Task.sleep(nanoseconds: 200_000_000)
            streamer.update("Hello world we are")
            try? await Task.sleep(nanoseconds: 200_000_000)
            let finished = streamer.finish(with: "Hello world, we are streaming.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            if finished, textView.string == "Hello world, we are streaming." {
                passed += 1
                Log.selftest.notice("PASS streaming happy path")
            } else {
                Log.selftest.error("FAIL streaming — finished \(finished, privacy: .public), landed \(textView.string, privacy: .public)")
            }
        } else {
            Log.selftest.error("FAIL streaming — begin() refused an NSTextView")
        }

        // Streaming freeze: the user edits mid-stream — the stream must stop
        // touching the field and finish() must refuse (no duplicate insert).
        if let streamAnchor = await verifiedAnchor(for: textView), streamer.begin(element: streamAnchor) {
            streamer.update("first words")
            try? await Task.sleep(nanoseconds: 200_000_000)
            textView.string = "USER EDITED THIS"   // simulated manual edit
            streamer.update("first words and more")
            try? await Task.sleep(nanoseconds: 200_000_000)
            let finished = streamer.finish(with: "final text")
            if !finished, textView.string == "USER EDITED THIS" {
                passed += 1
                Log.selftest.notice("PASS streaming freeze on user edit")
            } else {
                Log.selftest.error("FAIL streaming freeze — finished \(finished, privacy: .public), field \(textView.string, privacy: .public)")
            }
        } else {
            Log.selftest.error("FAIL streaming freeze — begin() refused")
        }

        Log.selftest.notice("injection self-test finished: \(passed, privacy: .public)/9 passed")
        window?.orderOut(nil)
        window = nil
    }

    /// Within our own process, the per-app AX focus can lag the real first
    /// responder (we caught streamed writes "verifying" into the dashboard).
    /// So every case anchors through this: assert first responder, plant a
    /// marker, and only accept an element whose value IS the marker.
    private func verifiedAnchor(for textView: NSTextView) async -> AXUIElement? {
        for _ in 0..<8 {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
            textView.string = "⟪WFMARK⟫"
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let element = injector.captureFocusedElement() {
                var valueRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                   let value = valueRef as? String, value == "⟪WFMARK⟫" {
                    textView.string = ""
                    return element
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        textView.string = ""
        return nil
    }

    private func makeScratchWindow() -> NSTextView {
        window?.orderOut(nil)
        // Competing windows (the dashboard) are what the AX focus query laggs
        // onto — take them out of the equation for the duration.
        for other in NSApp.windows where other.isVisible {
            other.orderOut(nil)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 460, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Waveform Injection Self-Test"
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
        self.window = window
        return textView
    }
}
