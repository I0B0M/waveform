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
        // Let the window become key and the text view take first-responder.
        try? await Task.sleep(nanoseconds: 400_000_000)

        let cases: [(name: String, text: String)] = [
            ("short", "Hello there."),
            ("punctuation", "It's \"quoted\" — with dashes; and (parens)!"),
            ("multiline", "Line one.\nLine two.\n• bullet three"),
            ("emoji", "Ship it 🙏 with 🎉 emoji 🚀"),
            ("long", String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)),
        ]

        var passed = 0
        for testCase in cases {
            textView.string = ""
            let anchor = injector.captureFocusedElement()
            let outcome = await injector.inject(
                testCase.text,
                method: .typeDirectly,
                targetBundleId: Bundle.main.bundleIdentifier,
                anchor: anchor
            )
            // The AX write is synchronous; typed events need a beat to land.
            try? await Task.sleep(nanoseconds: 300_000_000)
            let landed = textView.string
            if landed == testCase.text {
                passed += 1
                Log.selftest.notice("PASS \(testCase.name, privacy: .public) via \(String(describing: outcome), privacy: .public)")
            } else {
                Log.selftest.error("FAIL \(testCase.name, privacy: .public) via \(String(describing: outcome), privacy: .public) — landed \(landed.count, privacy: .public)/\(testCase.text.count, privacy: .public) chars")
            }
        }

        // Rapid-fire: three back-to-back injections must append in order.
        textView.string = ""
        let anchor = injector.captureFocusedElement()
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

        // Anchored write while ANOTHER window is key: the core of the "text
        // follows the caret I started at, not where I'm looking" guarantee.
        textView.string = ""
        let anchorForBackground = injector.captureFocusedElement()
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

        Log.selftest.notice("injection self-test finished: \(passed, privacy: .public)/7 passed")
        window?.orderOut(nil)
        window = nil
    }

    private func makeScratchWindow() -> NSTextView {
        window?.orderOut(nil)
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
