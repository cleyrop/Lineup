//
//  LineupApp.swift
//  Lineup
//
//  Created by river on 2025-07-26.
//

import SwiftUI
import AppKit

@main
struct LineupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var windowManager: WindowManager?
    var hotkeyManager: HotkeyManager?
    var preferencesWindow: NSWindow?
    var accessibilityCheckTimer: Timer? // Timer reference for management
    
    deinit {
        // Clean up Timer resource
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        Logger.log("🗑️ AppDelegate deinitialized, Timer resource released")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosting unit tests, do nothing — no status item, hotkeys, or the
        // modal Accessibility prompt (which would hang a headless CI runner). The
        // tests use @testable import and drive types directly.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Diagnostic builds: make stdout unbuffered so logs flush live to a
        // redirected file (Swift print() block-buffers to a non-tty otherwise).
#if DEBUG
        setvbuf(stdout, nil, _IONBF, 0)
#endif
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: LocalizedStrings.statusItemTooltip)
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.toolTip = LocalizedStrings.statusItemTooltip
            
            // Set up the right-click menu
            setupStatusBarMenu()
        }
        
        // Initialize managers
        windowManager = WindowManager()
        hotkeyManager = HotkeyManager(windowManager: windowManager!)
        
        // Set up the bidirectional reference
        windowManager?.hotkeyManager = hotkeyManager
        
        // Request accessibility permissions
        requestAccessibilityPermission()
        
        // Register the hotkey
        hotkeyManager?.registerHotkey()

        // If we were relaunched from Preferences (e.g. the permissions
        // restart-to-apply button), reopen the configuration window.
        if ProcessInfo.processInfo.arguments.contains(reopenPreferencesLaunchArgument) {
            DispatchQueue.main.async { [weak self] in self?.showPreferences() }
        }
    }
    
    @objc func statusBarButtonClicked() {
        // Left-click now shows the menu instead of triggering the main logic
        if let menu = statusItem?.menu {
            statusItem?.popUpMenu(menu)
        }
    }
    
    private func setupStatusBarMenu() {
        let menu = NSMenu()
        
        // Preferences menu item
        let preferencesItem = NSMenuItem(title: LocalizedStrings.preferences, action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit App menu item
        let quitItem = NSMenuItem(title: LocalizedStrings.quitApp, action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc func showPreferences() {
        // If the preferences window already exists, bring it to the front
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activateCompat()
            return
        }
        
        // Create the preferences window
        let contentView = PreferencesView()
        let hostingView = NSHostingView(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = LocalizedStrings.preferencesTitle
        window.contentView = hostingView
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")
        window.isReleasedWhenClosed = false
        
        // Set up cleanup for when the window is closed
        window.delegate = self
        
        preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activateCompat()
    }
    
    @objc func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
    
    func requestAccessibilityPermission() {
        let accessibilityEnabled = AXIsProcessTrusted()
        
        if !accessibilityEnabled {
            Logger.log(LocalizedStrings.accessibilityPermissionRequired)
            
            // Show permission prompt dialog
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = LocalizedStrings.accessibilityPermissionTitle
                alert.informativeText = LocalizedStrings.accessibilityPermissionMessage
                alert.alertStyle = .informational
                alert.addButton(withTitle: LocalizedStrings.openSystemPreferencesButton)
                alert.addButton(withTitle: LocalizedStrings.setupLater)
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings — modern pane id (the pre-Ventura
                    // com.apple.preference.security no longer navigates on 13+).
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            
            // Periodically check the permission status
            accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    Logger.log(LocalizedStrings.accessibilityPermissionGranted)
                    timer.invalidate()
                    self?.accessibilityCheckTimer = nil
                    
                    // Show restart required dialog
                    DispatchQueue.main.async {
                        self?.showRestartRequiredDialog()
                    }
                    
                    // Re-register hotkey once permission is granted
                    self?.hotkeyManager?.registerHotkey()
                }
            }
        } else {
            Logger.log(LocalizedStrings.accessibilityPermissionGranted)
        }
    }
    
    // MARK: - Restart Required Dialog
    func showRestartRequiredDialog() {
        let alert = NSAlert()
        alert.messageText = LocalizedStrings.restartRequiredTitle
        alert.informativeText = LocalizedStrings.restartRequiredMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: LocalizedStrings.restartNow)
        alert.addButton(withTitle: LocalizedStrings.restartLater)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // User chose to restart now
            restartApplication()
        }
    }
    
    // MARK: - Application Restart
    func restartApplication() {
        relaunchApp()
    }
    
    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == preferencesWindow {
            preferencesWindow = nil
        }
    }
}

