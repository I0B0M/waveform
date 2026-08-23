import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private var statusItem: NSStatusItem?
    private var coordinator: DictationCoordinator?
    private var settingsWindow: NSWindow?
    private let hotkeyManager = HotkeyManager()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = DictationCoordinator()
        self.coordinator = coordinator

        setUpStatusItem()
        registerHotkey()

        // Warm up: check/download the speech model assets once, off the critical path.
        Task {
            await coordinator.prepareEngine()
            self.refreshMenu()
        }
    }

    private func registerHotkey() {
        hotkeyManager.onHotkey = { [weak self] in
            self?.coordinator?.toggle()
        }
        let preset = AppSettings.shared.hotkeyPreset
        do {
            try hotkeyManager.register(preset: preset)
        } catch {
            NSLog("Discotype: hotkey registration failed: \(error)")
        }
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
                accessibilityDescription: "Discotype"
            )
        }
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

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

        if let engineStatus = coordinator?.engineStatusLine {
            let statusInfo = NSMenuItem(title: engineStatus, action: nil, keyEquivalent: "")
            statusInfo.isEnabled = false
            menu.addItem(statusInfo)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Discotype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
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
            window.title = "Discotype Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
