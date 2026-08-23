import AppKit
import AVFoundation
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public override init() { super.init() }

    private var statusItem: NSStatusItem?
    private var coordinator: DictationCoordinator?
    private var settingsWindow: NSWindow?
    private let hotkeyManager = HotkeyManager()
    private var hotkeyRetryTask: Task<Void, Never>?
    private var hotkeyWarning: String?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = DictationCoordinator()
        self.coordinator = coordinator

        setUpStatusItem()
        registerHotkey()

        // Warm up: speech model assets + the on-device LLM, off the critical path.
        Task {
            await coordinator.prepareEngine()
            self.refreshMenu()
        }
        Task.detached(priority: .utility) {
            LocalRewriter.prewarm()
        }
    }

    private func registerHotkey() {
        hotkeyRetryTask?.cancel()
        hotkeyRetryTask = nil
        hotkeyManager.onHotkey = { [weak self] in
            self?.coordinator?.toggle()
        }
        let preset = AppSettings.shared.hotkeyPreset
        do {
            try hotkeyManager.register(preset: preset)
            hotkeyWarning = nil
        } catch HotkeyManager.HotkeyError.accessibilityRequired {
            // The tap can't exist until Accessibility is granted. Say so
            // out loud and re-register automatically once the grant lands.
            hotkeyWarning = "⚠️ \(preset.label) needs Accessibility — waiting for the grant"
            NSLog("Waveform: event tap unavailable; prompting for Accessibility")
            _ = TextInjector.isTrusted(promptIfNeeded: true)
            hotkeyRetryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self else { return }
                    if TextInjector.isTrusted(promptIfNeeded: false) {
                        self.registerHotkey()
                        self.refreshMenu()
                        return
                    }
                }
            }
        } catch {
            hotkeyWarning = "⚠️ Hotkey failed: \(error.localizedDescription)"
            NSLog("Waveform: hotkey registration failed: \(error)")
        }
        refreshMenu()
    }

    func hotkeyPresetChanged() {
        registerHotkey()
        refreshMenu()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "waveform.and.mic",
                accessibilityDescription: "Waveform"
            )
        }
        statusItem = item
        refreshMenu()
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self

        let preset = AppSettings.shared.hotkeyPreset
        let toggleItem = NSMenuItem(
            title: "Start Dictation",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let hotkeyInfo = NSMenuItem(title: "Hotkey: \(preset.label)", action: nil, keyEquivalent: "")
        hotkeyInfo.isEnabled = false
        menu.addItem(hotkeyInfo)

        if let hotkeyWarning {
            let warning = NSMenuItem(title: hotkeyWarning, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        if let engineStatus = coordinator?.engineStatusLine {
            let statusInfo = NSMenuItem(title: engineStatus, action: nil, keyEquivalent: "")
            statusInfo.isEnabled = false
            menu.addItem(statusInfo)
        }

        menu.addItem(.separator())

        // Live permission status — the two things that silently break
        // dictation when missing. Click either to open its settings pane.
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = TextInjector.isTrusted(promptIfNeeded: false)
        let micItem = NSMenuItem(
            title: micOK ? "Microphone: ✓ granted" : "Microphone: ✗ not granted — click to fix",
            action: micOK ? nil : #selector(openMicSettings),
            keyEquivalent: ""
        )
        micItem.target = self
        menu.addItem(micItem)
        let axItem = NSMenuItem(
            title: axOK ? "Accessibility: ✓ granted" : "Accessibility: ✗ not granted — click to fix",
            action: axOK ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        axItem.target = self
        menu.addItem(axItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Waveform", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        )
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func toggleDictation() {
        coordinator?.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(onHotkeyChange: { [weak self] in
                self?.hotkeyPresetChanged()
            })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waveform Settings"
            window.setContentSize(NSSize(width: 460, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
