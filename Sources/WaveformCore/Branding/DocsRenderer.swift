import AppKit
import SwiftUI

/// Renders every image the README uses, in one pass, so the docs can be
/// regenerated after any UI change instead of drifting out of date.
///
/// Everything renders with demo data — real dictation history must never end
/// up in a committed screenshot.
///
/// Uses `NSHostingView.cacheDisplay` rather than `ImageRenderer`: SwiftUI's
/// system materials (sidebar backing, grouped-Form rows) don't resolve in an
/// ImageRenderer pass and come out white. cacheDisplay needs a real window and
/// a runloop turn to commit layout, hence the sequential chain below.
public enum DocsRenderer {
    private struct Job {
        let view: AnyView
        let size: NSSize
        let url: URL
    }

    @MainActor
    public static func renderAllAndExit(to directory: String) {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }

        var jobs: [Job] = [
            Job(
                view: AnyView(DiscoIconView()),
                size: NSSize(width: 256, height: 256),
                url: base.appendingPathComponent("app-icon.png")
            ),
            Job(
                view: AnyView(hudScene(transcript: false)),
                size: NSSize(width: 560, height: 150),
                url: base.appendingPathComponent("hud-compact.png")
            ),
            Job(
                view: AnyView(hudScene(transcript: true)),
                size: NSSize(width: 600, height: 170),
                url: base.appendingPathComponent("hud-listening.png")
            ),
        ]
        for (tab, name) in [
            (DashboardView.Tab.home, "dashboard-home"),
            (DashboardView.Tab.settings, "dashboard-settings"),
            (DashboardView.Tab.prompts, "dashboard-prompts"),
            (DashboardView.Tab.snippets, "dashboard-snippets"),
        ] {
            jobs.append(Job(
                view: AnyView(DashboardView(onHotkeyChange: {}, demo: true, initialTab: tab)),
                size: NSSize(width: 900, height: 620),
                url: base.appendingPathComponent("\(name).png")
            ))
        }

        render(jobs: jobs, index: 0, directory: directory)
        RunLoop.main.run()
    }

    @MainActor
    private static func render(jobs: [Job], index: Int, directory: String) {
        guard index < jobs.count else {
            print("Wrote \(jobs.count) README images to \(directory)")
            exit(0)
        }
        let job = jobs[index]

        let hosting = NSHostingView(rootView: job.view)
        hosting.frame = NSRect(origin: .zero, size: job.size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            // `window` is captured so it outlives the layout pass.
            _ = window
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("FAIL: no bitmap for \(job.url.lastPathComponent)")
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                print("FAIL: no PNG data for \(job.url.lastPathComponent)")
                exit(1)
            }
            do {
                try data.write(to: job.url)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
            render(jobs: jobs, index: index + 1, directory: directory)
        }
    }

    @MainActor
    private static func hudScene(transcript: Bool) -> some View {
        let state = HUDState()
        state.level = 0.72
        if transcript {
            state.applyTranscript(
                finalized: "Okay, so basically I wanted to explain that we should",
                volatile: "move the launch to next week")
        }
        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.08, blue: 0.20),
                    Color(red: 0.03, green: 0.02, blue: 0.08),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            HUDView(state: state, frozenTime: 1.85, previewHovered: transcript)
                .padding(30)
        }
    }
}
