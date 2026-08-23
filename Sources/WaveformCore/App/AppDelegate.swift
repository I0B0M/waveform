import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
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

        // Opening the app should show something. Without this, double-clicking
        // Waveform.app looks like nothing happened — it's a menu-bar app, so
        // there is no window and no Dock bounce to explain itself.
        //
        // Only for a user-initiated launch: when macOS starts us as a login
        // item this key is false, and popping a window into someone's face at
        // every login is not what "launch at login" should mean.
        let userLaunched = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        Log.app.notice("launched (userLaunched: \(userLaunched, privacy: .public))")
        if userLaunched {
            openSettings()
        }
    }

    /// Double-clicking the app (or Spotlight-opening it) while it is already
    /// running lands here instead of starting a second copy.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Log.app.notice("reopen requested (hasVisibleWindows: \(flag, privacy: .public))")
        openSettings()
        return true
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
            button.image = MenuBarIcon.image() ?? NSImage(
                systemSymbolName: "waveform.and.mic",
                accessibilityDescription: "Waveform"
            )
            button.image?.accessibilityDescription = "Waveform"
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

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        let settingsItem = NSMenuItem(title: "Open Waveform…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Waveform", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Waveform: launch-at-login toggle failed: %@", String(describing: error))
        }
        refreshMenu()
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
            let view = DashboardView(onHotkeyChange: { [weak self] in
                self?.hotkeyPresetChanged()
            })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waveform"
            window.setContentSize(NSSize(width: 840, height: 580))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        // Become a normal app while a window is up: that gives the Dock icon
        // and ⌘Tab, which people expect from a window they can see. We drop
        // back to accessory on close so the app stays out of the way.
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.app.notice("dashboard shown (visible: \(self.settingsWindow?.isVisible ?? false, privacy: .public))")
    }

    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
