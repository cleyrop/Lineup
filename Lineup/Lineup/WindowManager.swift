//
//  WindowManager.swift
//  Lineup
//
//  Created by river on 2025-07-26.
//

import Foundation
import AppKit
import CoreGraphics
import SwiftUI
import ApplicationServices

// Private SPI declarations live in PrivateApis.swift (_AXUIElementGetWindow,
// the SkyLight/CGS functions, etc.).

struct WindowInfo {
    let windowID: CGWindowID
    let title: String
    let projectName: String
    let appName: String
    let processID: pid_t
    let axWindowIndex: Int  // legacy CT2 coupling; ignored by the SkyLight DS2 focus path
    var isMinimized: Bool = false  // window is minimized to the Dock
    var isOnOtherSpace: Bool = false  // window lives on another Space / desktop

    // Populated by the SkyLight DS2 enumeration only:
    var cgWindowID: CGWindowID = 0    // real window-server id, used for focus
    var spaceID: CGSSpaceID = 0       // the Space the window lives on
    var spaceIndex: Int = 0           // 1-based desktop number (0 = current/unknown)
    var axElement: AXUIElement? = nil // resolved at enumeration time (covers off-Space windows)
    var thumbnail: NSImage? = nil     // window screenshot (when Screen Recording is granted)
}

// MARK: - App Info Data Structure
struct AppInfo {
    let bundleId: String
    let processID: pid_t
    let appName: String
    let windowCount: Int  // Total window count of this app (best-effort)
    let isActive: Bool    // Whether it's the currently active app
}

// MARK: - Switcher Panel
/// A borderless, non-activating panel that can still become key, so the switcher
/// receives and swallows keyboard input instead of leaking it to the frontmost app.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var isShowingSwitcher = false
    @Published var currentWindowIndex = 0
    
    // CT2 related properties
    @Published var apps: [AppInfo] = []
    @Published var isShowingAppSwitcher = false
    @Published var currentAppIndex = 0
    
    private var switcherWindow: NSWindow?
    private var eventMonitor: Any?
    private var globalEventMonitor: Any?
    private var numberKeyEventTap: CFMachPort?
    
    // Current view type tracking
    private var currentViewType: SwitcherType = .ds2
    
    // Event handling state management
    private var isProcessingKeyEvent = false
    private var lastModifierEventTime = Date()

    // Double-tap-to-hold (peek) mode: when the trigger is double-tapped quickly,
    // the switcher stays open after the modifier is released until the user
    // commits (Enter/click) or cancels (Esc).
    private var switcherOpenTime = Date()
    private var switcherHeld = false
    
    // Modifier key watchdog mechanism
    private var modifierKeyWatchdog: Timer?
    private let watchdogInterval: TimeInterval = 0.016 // 16ms ≈ 60Hz
    private var watchdogCallCount = 0
    private var watchdogPhase = 0
    private var lastSwitchTime = Date()
    
    // AX element cache item structure
    private struct AXCacheItem {
        let element: AXUIElement
        let processID: pid_t
        var lastAccessTime: Date
        
        init(element: AXUIElement, processID: pid_t) {
            self.element = element
            self.processID = processID
            self.lastAccessTime = Date()
        }
        
        mutating func updateAccessTime() {
            self.lastAccessTime = Date()
        }
    }
    
    // Improved AX element cache with more metadata
    private var axElementCache: [CGWindowID: AXCacheItem] = [:]
    private let maxAXCacheSize = 100  // Maximum cache of 100 AX elements
    private let axCacheCleanupThreshold = 120  // Start cleanup when reaching 120
    
    // Weak reference to HotkeyManager to avoid circular reference
    weak var hotkeyManager: HotkeyManager?
    
    // Settings manager
    private let settingsManager = SettingsManager.shared
    
    // MARK: - Steam Application Support
    //
    // Steam applications (including Steam games) often create windows with non-zero layer values,
    // which causes them to be filtered out by standard window detection logic that only accepts layer 0.
    // This implementation provides special handling for Steam applications by:
    // 1. Detecting Steam apps by bundle ID patterns
    // 2. Allowing non-zero layers (typically 1-10) for Steam applications
    // 3. Providing enhanced logging for Steam window detection
    //
    // Based on research from the alt-tab-macos project and community reports of Steam window issues.
    
    /// Check if an application is Steam or a Steam game
    /// Steam games often have non-zero window layers which cause them to be filtered out
    private func isSteamApplication(_ bundleId: String?) -> Bool {
        guard let bundleId = bundleId else { return false }
        
        // Steam client itself
        if bundleId == "com.valvesoftware.steam" {
            return true
        }
        
        // Steam games - common patterns based on alt-tab-macos implementation
        // Steam games typically have bundle IDs starting with "com.valvesoftware."
        // or contain "steamapps" in their bundle ID
        if bundleId.hasPrefix("com.valvesoftware.") || 
           bundleId.contains("steamapps") ||
           bundleId.contains("steam") {
            return true
        }
        
        return false
    }
    
    /// Check if a window layer should be considered valid, with special handling for Steam apps
    private func isValidWindowLayer(_ layer: Int, forBundleId bundleId: String?) -> Bool {
        // Standard case: layer 0 (normal windows)
        if layer == 0 {
            return true
        }
        
        // Special case for Steam applications: allow certain non-zero layers
        if isSteamApplication(bundleId) {
            // Allow layers typically used by Steam games (based on community research)
            // Steam games and the Steam client may place windows on higher layers
            return layer >= 0 && layer <= 100
        }
        
        return false
    }

    /// Resolve the primary app (with regular activation policy) that should own a window
    private func resolvePrimaryApp(
        for windowProcessID: pid_t,
        ownerName: String?,
        runningAppMap: [pid_t: NSRunningApplication],
        bundlePrimaryApp: [String: NSRunningApplication]
    ) -> NSRunningApplication? {
        var windowRunningApp: NSRunningApplication?
        if let cachedApp = runningAppMap[windowProcessID] {
            windowRunningApp = cachedApp
        } else {
            windowRunningApp = NSRunningApplication(processIdentifier: windowProcessID)
        }
        
        if let app = windowRunningApp {
            if app.activationPolicy == .regular {
                return app
            }
            if let bundleId = app.bundleIdentifier, let primaryApp = bundlePrimaryApp[bundleId] {
                return primaryApp
            }
        }
        
        if let bundleId = windowRunningApp?.bundleIdentifier, let primaryApp = bundlePrimaryApp[bundleId] {
            return primaryApp
        }
        
        if let ownerName = ownerName?.lowercased(), ownerName.contains("steam"),
           let steamApp = bundlePrimaryApp.first(where: { isSteamApplication($0.key) })?.value {
            return steamApp
        }
        
        return nil
    }
    
    /// Determine whether a window belongs to the specified target application
    private func windowBelongsToApp(
        windowProcessID: pid_t,
        ownerName: String?,
        targetApp: NSRunningApplication,
        runningAppMap: [pid_t: NSRunningApplication],
        bundlePrimaryApp: [String: NSRunningApplication]
    ) -> Bool {
        if windowProcessID == targetApp.processIdentifier {
            return true
        }
        
        if let targetBundle = targetApp.bundleIdentifier,
           let windowApp = runningAppMap[windowProcessID],
           windowApp.bundleIdentifier == targetBundle {
            return true
        }
        
        if let resolvedApp = resolvePrimaryApp(
            for: windowProcessID,
            ownerName: ownerName,
            runningAppMap: runningAppMap,
            bundlePrimaryApp: bundlePrimaryApp
        ) {
            if resolvedApp.processIdentifier == targetApp.processIdentifier {
                return true
            }
            if let targetBundle = targetApp.bundleIdentifier,
               let resolvedBundle = resolvedApp.bundleIdentifier,
               resolvedBundle == targetBundle {
                return true
            }
        }
        
        if isSteamApplication(targetApp.bundleIdentifier) {
            if let ownerName = ownerName?.lowercased(), ownerName.contains("steam") {
                return true
            }
        }
        
        return false
    }
    
    init() {
        setupSwitcherWindow()
    }
    
    deinit {
        // Ensure event listeners are cleaned up
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let globalMonitor = globalEventMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        
        // Clean up watchdog timer
        stopModifierKeyWatchdog()
        
        // Clean up number key event tap
        stopNumberKeyGlobalIntercept()
        
        // Clean up AX cache
        Logger.log("🗑️ WindowManager cleanup, releasing \(axElementCache.count) AX elements")
        axElementCache.removeAll()
    }
    
    // MARK: - AX Cache Management Methods
    
    // Smart AX cache cleanup
    private func cleanupAXCache() {
        guard axElementCache.count >= axCacheCleanupThreshold else { return }
        
        Logger.log("🧹 Starting AX cache LRU cleanup, current size: \(axElementCache.count)")
        
        // Get set of currently running application process IDs
        let runningProcesses = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        
        // First remove cache items for terminated processes
        var itemsToRemove: [CGWindowID] = []
        for (windowID, cacheItem) in axElementCache {
            if !runningProcesses.contains(cacheItem.processID) {
                itemsToRemove.append(windowID)
            }
        }
        
        for windowID in itemsToRemove {
            axElementCache.removeValue(forKey: windowID)
        }
        
        Logger.log("🗑️ Removing AX elements for terminated processes: \(itemsToRemove.count) items")
        
        // If still over limit, perform LRU cleanup
        if axElementCache.count > maxAXCacheSize {
            let sortedEntries = axElementCache.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
            let itemsToKeep = Array(sortedEntries.suffix(maxAXCacheSize))
            var newCache: [CGWindowID: AXCacheItem] = [:]
            for (key, value) in itemsToKeep {
                newCache[key] = value
            }
            
            let lruRemovedCount = axElementCache.count - newCache.count
            axElementCache = newCache
            
            Logger.log("🧹 LRU cleanup completed, removed \(lruRemovedCount) AX elements, current size: \(axElementCache.count)")
        }
    }
    
    // Get or cache AX element
    private func getCachedAXElement(windowID: CGWindowID, processID: pid_t, windowIndex: Int) -> AXUIElement? {
        // Check if exists in cache and update access time
        if var cachedItem = axElementCache[windowID] {
            cachedItem.updateAccessTime()
            axElementCache[windowID] = cachedItem
            return cachedItem.element
        }
        
        // Not in cache, get new AX element
        let (_, axElement, _) = getAXWindowInfo(windowID: windowID, processID: processID, windowIndex: windowIndex)
        
        if let element = axElement {
            // Check if cleanup is needed before adding to cache
            cleanupAXCache()
            
            // Add to cache
            axElementCache[windowID] = AXCacheItem(element: element, processID: processID)
            Logger.log("📦 Caching AX element: WindowID \(windowID), current cache size: \(axElementCache.count)")
        }
        
        return axElement
    }
    
    // MARK: - Memory Optimized View Creation Methods
    
    // Create DS2 view
    private func createDS2HostingView() -> NSHostingView<DS2SwitcherView> {
        Logger.log("🆕 Creating DS2 HostingView")
        let contentView = DS2SwitcherView(windowManager: self)
        return NSHostingView(rootView: contentView)
    }
    
    // Create CT2 view
    private func createCT2HostingView() -> NSHostingView<CT2SwitcherView> {
        Logger.log("🆕 Creating CT2 HostingView")
        let contentView = CT2SwitcherView(windowManager: self)
        return NSHostingView(rootView: contentView)
    }
    
    private func setupSwitcherWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 400)
        // A non-activating panel that CAN become key: this lets the local event
        // monitor receive AND consume keystrokes (arrows/Enter/Esc), so they no
        // longer leak into the frontmost app the way they did with a borderless
        // NSWindow that could never be key.
        switcherWindow = SwitcherPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        switcherWindow?.isReleasedWhenClosed = false
        switcherWindow?.level = .floating
        switcherWindow?.backgroundColor = NSColor.clear
        switcherWindow?.hasShadow = true
        switcherWindow?.isOpaque = false
        (switcherWindow as? NSPanel)?.hidesOnDeactivate = false
        // Appear on every Space and over full-screen apps, and stay put during a
        // Space slide — so the switcher remains visible (and can animate) while
        // macOS transitions to another desktop, instead of vanishing.
        switcherWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        switcherWindow?.animationBehavior = .none

        // Initial content view will be set on first display
        switcherWindow?.contentView = NSView() // Temporary empty view

        // In hold (peek) mode, clicking outside the panel cancels it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(switcherResignedKey),
            name: NSWindow.didResignKeyNotification, object: switcherWindow
        )

        // Position will be set when displaying
    }

    @objc private func switcherResignedKey() {
        guard switcherHeld, isShowingSwitcher else { return }
        DispatchQueue.main.async { [weak self] in
            self?.hideSwitcherAsync(activate: false)
        }
    }

    /// Fade the switcher in.
    private func presentSwitcherWindow() {
        guard let w = switcherWindow else { return }
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activateCompat()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1.0
        }
    }

    /// Dismiss the switcher. When `rideTransition` is true the panel (which spans
    /// all Spaces) stays up and fades out over the Space slide, so it visibly
    /// rides the transition to the new desktop instead of vanishing first.
    private func dismissSwitcherWindow(rideTransition: Bool) {
        guard let w = switcherWindow else { return }
        let finish = {
            w.orderOut(nil)
            w.alphaValue = 1.0
            w.contentView = NSView()
        }
        if rideTransition {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().alphaValue = 0.0
            }, completionHandler: finish)
        } else {
            finish()
        }
    }
    
    // MARK: - Switcher Window Positioning
    private func positionSwitcherWindow() {
        guard let window = switcherWindow else { return }
        
        let targetScreen: NSScreen?
        
        if settingsManager.settings.switcherFollowActiveWindow {
            targetScreen = getActiveWindowScreen()
        } else {
            targetScreen = getPrimaryScreen()
        }
        
        let finalScreen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        
        if let screen = finalScreen {
            let screenFrame = screen.visibleFrame
            let windowSize = window.frame.size
            
            let x = screenFrame.midX - windowSize.width / 2
            
            let verticalRatio = settingsManager.settings.switcherVerticalPosition
            let y = screenFrame.maxY - (screenFrame.height * verticalRatio) - windowSize.height / 2
            
            window.setFrameOrigin(NSPoint(x: x, y: y))
            
            Logger.log("🖥️ Positioned switcher on screen: \(getDisplayName(for: screen)) at vertical ratio: \(String(format: "%.2f", verticalRatio))")
        }
    }
    
    private func getActiveWindowScreen() -> NSScreen? {
        if let focusedWindowScreen = getFocusedWindowScreen() {
            return focusedWindowScreen
        }
        
        if !windows.isEmpty {
            let firstWindow = windows[0]
            return getWindowScreen(windowID: firstWindow.windowID)
        }
        
        return nil
    }
    
    private func getFocusedWindowScreen() -> NSScreen? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedWindow: AnyObject?
        
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        if result == .success, let windowElement = focusedWindow {
            var positionValue: AnyObject?
            let posResult = AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXPositionAttribute as CFString, &positionValue)
            
            if posResult == .success, let position = positionValue {
                var point = CGPoint.zero
                if AXValueGetValue(position as! AXValue, .cgPoint, &point) {
                    return screenContaining(cgPoint: point)
                }
            }
        }

        return nil
    }

    private func getWindowScreen(windowID: CGWindowID) -> NSScreen? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let windowInfo = windowList.first,
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat else {
            return nil
        }
        return screenContaining(cgPoint: CGPoint(x: x, y: y))
    }

    /// The screen containing a top-left-origin (CG/AX) global point. CG/AX use a
    /// top-left origin on the primary display while NSScreen.frame is bottom-left,
    /// so the Y must be flipped before testing — otherwise multi-display (and any
    /// vertical arrangement) resolves to the wrong screen.
    private func screenContaining(cgPoint: CGPoint) -> NSScreen? {
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        let cocoaPoint = CGPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        return NSScreen.screens.first { $0.frame.contains(cocoaPoint) }
    }
    
    private func getPrimaryScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                if CGDisplayIsMain(displayID) != 0 {
                    return screen
                }
            }
        }
        return NSScreen.main
    }
    
    private func getDisplayName(for screen: NSScreen?) -> String {
        guard let screen = screen else { return "Unknown" }
        
        if #available(macOS 10.15, *) {
            return screen.localizedName
        } else {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                if CGDisplayIsBuiltin(displayID) != 0 {
                    return "Built-in Display"
                } else {
                    return "External Display (\(displayID))"
                }
            }
            return "Unknown Display"
        }
    }
    
    func showWindowSwitcher() {
        guard !isShowingSwitcher else { return }
        
        AppIconCache.shared.clearCache()
        
        getCurrentAppWindows()
        
        if windows.isEmpty {
            Logger.log(LocalizedStrings.noWindowsFound)
            return
        }
        
        isShowingSwitcher = true
        currentWindowIndex = windows.count > 1 ? 1 : 0
        switcherOpenTime = Date()
        switcherHeld = false

        hotkeyManager?.temporarilyDisableHotkey()
        
        currentViewType = .ds2
        switcherWindow?.contentView = createDS2HostingView()
        
        positionSwitcherWindow()

        presentSwitcherWindow()
        
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        //     guard let self = self, self.isShowingSwitcher else { return }
        //     let cacheInfo = AppIconCache.shared.getCacheInfo()
        //     let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(cacheInfo.dataSize), countStyle: .memory)
        //     Logger.log("📊 DS2 icon cache status (after rendering): \(cacheInfo.count) / \(cacheInfo.maxSize), total size: \(formattedSize)")
        // }
        
        setupUnifiedEventHandling()
        
        startNumberKeyGlobalIntercept()
        
        startModifierKeyWatchdog(for: .ds2)
    }
    
    func hideSwitcher() {
        hideSwitcherAsync()
    }
    
    // MARK: - CT2 Functionality: App Switcher Display and Hide
    func showAppSwitcher() {
        guard !isShowingAppSwitcher else { return }
        
        AppIconCache.shared.clearCache()
        
        getAllAppsWithWindows()
        
        if apps.isEmpty {
            Logger.log("No applications with windows found")
            return
        }
        
        isShowingAppSwitcher = true
        currentAppIndex = apps.count > 1 ? 1 : 0
        
        hotkeyManager?.temporarilyDisableHotkey()
        
        currentViewType = .ct2
        switcherWindow?.contentView = createCT2HostingView()
        
        positionSwitcherWindow()

        presentSwitcherWindow()
        
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        //     guard let self = self, self.isShowingAppSwitcher else { return }
        //     let cacheInfo = AppIconCache.shared.getCacheInfo()
        //     let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(cacheInfo.dataSize), countStyle: .memory)
        //     Logger.log("📊 CT2 icon cache status (after rendering): \(cacheInfo.count) / \(cacheInfo.maxSize), total size: \(formattedSize)")
        // }
        
        setupUnifiedEventHandling()
        
        startNumberKeyGlobalIntercept()
        
        startModifierKeyWatchdog(for: .ct2)
    }
    
    func hideAppSwitcher() {
        hideAppSwitcherAsync()
    }
    
    
    
    func moveToNextWindow() {
        guard !windows.isEmpty else { return }
        let oldIndex = currentWindowIndex
        currentWindowIndex = (currentWindowIndex + 1) % windows.count
        Logger.log("🔄 moveToNextWindow: \(oldIndex) -> \(currentWindowIndex) (total: \(windows.count))")
    }
    
    func moveToPreviousWindow() {
        guard !windows.isEmpty else { return }
        currentWindowIndex = currentWindowIndex > 0 ? currentWindowIndex - 1 : windows.count - 1
    }
    
    func selectWindow(at index: Int) {
        guard index < windows.count else { return }
        currentWindowIndex = index
        hideSwitcher()
    }
    
    func selectWindowByNumberKey(_ numberKey: Int) {
        let index = numberKey - 1 // Convert 1-9 to 0-8
        guard index >= 0 && index < windows.count && index < 9 else { return }
        selectWindow(at: index)
    }
    
    // MARK: - CT2 Functionality: App Switching Related Methods
    func moveToNextApp() {
        guard !apps.isEmpty else { return }
        let oldIndex = currentAppIndex
        currentAppIndex = (currentAppIndex + 1) % apps.count
        Logger.log("🔄 moveToNextApp: \(oldIndex) -> \(currentAppIndex) (total: \(apps.count))")
    }
    
    func moveToPreviousApp() {
        guard !apps.isEmpty else { return }
        currentAppIndex = currentAppIndex > 0 ? currentAppIndex - 1 : apps.count - 1
    }
    
    func selectApp(at index: Int) {
        guard index < apps.count else { return }
        currentAppIndex = index
        hideAppSwitcher()
    }
    
    func selectAppByNumberKey(_ numberKey: Int) {
        let index = numberKey - 1 // Convert 1-9 to 0-8
        guard index >= 0 && index < apps.count && index < 9 else { return }
        selectApp(at: index)
    }
    
    // MARK: - EventTap Support Methods
    func selectNextApp() {
        moveToNextApp()
    }
    
    func selectPreviousApp() {
        moveToPreviousApp()
    }
    
    func activateSelectedApp() {
        hideAppSwitcher()
    }
    
    private func getCurrentAppWindows() {
        windows.removeAll()
        
        Logger.log("\n=== Debug Information Start ===")
        let allApps = NSWorkspace.shared.runningApplications
        let runningAppMap = Dictionary(uniqueKeysWithValues: allApps.map { ($0.processIdentifier, $0) })
        let bundlePrimaryApp = allApps.reduce(into: [String: NSRunningApplication]()) { partialResult, app in
            guard app.activationPolicy == .regular, let bundleId = app.bundleIdentifier else { return }
            if partialResult[bundleId] == nil {
                partialResult[bundleId] = app
            }
        }
        // Logger.log("All running applications:")
        // for app in allApps {
        //     let isActive = app.isActive ? " [ACTIVE]" : ""
        //     let bundleId = app.bundleIdentifier ?? "Unknown"
        //     Logger.log("  - \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier), Bundle: \(bundleId))\(isActive)")
        // }
        
        let frontmostApp = allApps.first { app in
            app.isActive && app.bundleIdentifier != Bundle.main.bundleIdentifier
        }

        // When showWindowsFromAllSpaces is on, drop the on-screen restriction so windows
        // living on other Spaces / desktops are enumerated too (issue #7).
        let windowListOptions: CGWindowListOption = settingsManager.settings.showWindowsFromAllSpaces
            ? [.excludeDesktopElements]
            : .optionOnScreenOnly
        let windowList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]] ?? []

        let targetApp: NSRunningApplication
        if let frontApp = frontmostApp {
            targetApp = frontApp
            Logger.log("✅ Using frontmost application as target app")
        } else {
            Logger.log("⚠️ Cannot get frontmost application, trying to use application of the frontmost window")
            
            var topWindowApp: NSRunningApplication?
            for windowInfo in windowList {
                guard let processID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                      let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool,
                      let layer = windowInfo[kCGWindowLayer as String] as? Int else { continue }
                let ownerName = windowInfo[kCGWindowOwnerName as String] as? String

                if !isOnScreen {
                    continue
                }

                guard let resolvedApp = resolvePrimaryApp(
                    for: processID,
                    ownerName: ownerName,
                    runningAppMap: runningAppMap,
                    bundlePrimaryApp: bundlePrimaryApp
                ),
                resolvedApp.bundleIdentifier != Bundle.main.bundleIdentifier,
                isValidWindowLayer(layer, forBundleId: resolvedApp.bundleIdentifier) else {
                    continue
                }

                topWindowApp = resolvedApp
                Logger.log("🔍 Found application of frontmost window: \(resolvedApp.localizedName ?? "Unknown") (PID: \(resolvedApp.processIdentifier), Layer: \(layer))")
                if isSteamApplication(resolvedApp.bundleIdentifier) {
                    Logger.log("🎮 Detected Steam application with layer \(layer)")
                }
                break
            }
            
            guard let foundApp = topWindowApp else {
                Logger.log("❌ Cannot get any valid target application")
                return
            }
            
            targetApp = foundApp
        }
        
        Logger.log("\n🎯 Target application: \(targetApp.localizedName ?? "Unknown") (PID: \(targetApp.processIdentifier))")
        Logger.log("   Bundle ID: \(targetApp.bundleIdentifier ?? "Unknown")")
        Logger.log("\n📋 System found \(windowList.count) windows in total")
        
        enumerateAppWindowsViaAX(targetApp: targetApp)
        captureThumbnailsAsync()

        Logger.log("📊 Final added windows: \(windows.count)")
        Logger.log("=== Debug Information End ===\n")
    }

    /// Enumerate the target app's windows across ALL Spaces + the Dock.
    ///
    /// kAXWindowsAttribute alone omits windows on other Spaces (confirmed in
    /// AltTab's source and our own logs), so we union it with a remote-token
    /// brute-force that reaches off-Space windows, then read each window's real
    /// id, title, minimized state and Space from its AX element. Current-Space
    /// windows are ordered by their window-server z-order; off-Space windows and
    /// minimized ones follow.
    private func enumerateAppWindowsViaAX(targetApp: NSRunningApplication) {
        windows.append(contentsOf: appWindows(of: targetApp))
    }

    /// Compute the target app's windows across all Spaces + the Dock. Pure with
    /// respect to `self` (reads only the Accessibility/WindowServer state), so it
    /// is the testable entry point for the enumeration logic.
    func appWindows(of targetApp: NSRunningApplication) -> [WindowInfo] {
        var windows = [WindowInfo]()
        let pid = targetApp.processIdentifier

        let visibleSpaces = visibleSpaceIDs()
        let spaceIndexes = spaceIndexMap()  // Space id -> 1-based desktop number
        let axWindows = allAppWindows(pid)

        // z-order of windows on the visible Space(s), topmost first.
        let zOrder = visibleSpaces.isEmpty ? [] : windowsInSpaces(Array(visibleSpaces), includeInvisible: true)
        var zIndex = [CGWindowID: Int]()
        for (i, wid) in zOrder.enumerated() { zIndex[wid] = i }

        let syntheticIDBase: CGWindowID = 0xF000_0000
        var seen = Set<CGWindowID>()
        // Stable sort key (group, secondary, id): group 0=current Space (z-order),
        // 1=other Space (by desktop number), 2=minimized. Ties break on the window
        // id, which is stable across opens — so a window keeps its position.
        var built = [(key: (Int, Int, Int), info: WindowInfo)]()

        for axWindow in axWindows {
            guard isStandardWindow(axWindow) else { continue }

            var cgID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWindow, &cgID)
            if cgID != 0 {
                if seen.contains(cgID) { continue }
                seen.insert(cgID)
            }

            let minimized = isWindowMinimized(axWindow)
            let spaces = cgID != 0 ? spacesForWindow(cgID) : []
            let spaceID = spaces.first ?? 0
            let spaceIndex = spaceIndexes[spaceID] ?? 0
            // Unknown Space (empty) is treated as current, so a window is only
            // "other Space" when we positively know its Space isn't visible.
            let onCurrent = spaces.isEmpty || spaces.contains { visibleSpaces.contains($0) }
            let onOtherSpace = !minimized && !onCurrent

            let axTitle = windowTitle(axWindow)
            let displayTitle: String
            let projectName: String
            if !axTitle.isEmpty {
                displayTitle = axTitle
                projectName = settingsManager.extractProjectName(
                    from: axTitle,
                    bundleId: targetApp.bundleIdentifier ?? "",
                    appName: targetApp.localizedName ?? ""
                )
            } else {
                displayTitle = targetApp.localizedName ?? "Window"
                projectName = displayTitle
            }

            let cacheID = cgID != 0 ? cgID : syntheticIDBase + CGWindowID(built.count)

            let key: (Int, Int, Int)
            if let z = zIndex[cgID] { key = (0, z, Int(cgID)) }
            else if minimized { key = (2, spaceIndex, Int(cgID)) }
            else { key = (1, spaceIndex, Int(cgID)) }

            let window = WindowInfo(
                windowID: cacheID,
                title: displayTitle,
                projectName: projectName,
                appName: targetApp.localizedName ?? "",
                processID: pid,
                axWindowIndex: 0,
                isMinimized: minimized,
                isOnOtherSpace: onOtherSpace,
                cgWindowID: cgID,
                spaceID: spaceID,
                spaceIndex: spaceIndex,
                axElement: axWindow
            )
            built.append((key, window))
        }

        built.sort { $0.key < $1.key }
        for (_, w) in built {
            windows.append(w)
            Logger.log("   ✅ '\(w.projectName)' wid=\(w.cgWindowID) desktop=\(w.spaceIndex) min=\(w.isMinimized) other=\(w.isOnOtherSpace)")
        }
        return windows
    }

    /// Union of the app's on-current-Space AX windows (kAXWindowsAttribute, which
    /// also catches freshly-launched windows brute-force misses) and the
    /// remote-token brute-force (which reaches windows on other Spaces).
    private func allAppWindows(_ pid: pid_t) -> [AXUIElement] {
        var result = [AXUIElement]()

        let axApp = AXUIElementCreateApplication(pid)
        // Cap how long we'll block on a (possibly beachballing) target app so it
        // can never freeze the hotkey — degrade to fewer windows instead.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            result.append(contentsOf: axWindows)
        }
        // The remote-token brute-force is the only thing that reaches windows on
        // OTHER Spaces, and it is the expensive step (~100 ms). kAXWindowsAttribute
        // already covers the current Space + the Dock, so skip the brute-force
        // entirely when the user isn't asking for other-Space windows.
        if settingsManager.settings.showWindowsFromAllSpaces {
            result.append(contentsOf: windowsByBruteForce(pid))
        }
        return result
    }

    /// Brute-force the app's windows by probing AXUIElementIDs through remote
    /// tokens. Ported from AltTab — this is what surfaces windows on other Spaces,
    /// which kAXWindowsAttribute does not return.
    private func windowsByBruteForce(_ pid: pid_t) -> [AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

        var axWindows = [AXUIElement]()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1  // 100 ms cap
        for axId: AXUIElementID in 0..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: axId) { Data($0) })
            if let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() {
                AXUIElementSetMessagingTimeout(element, 0.1)
                var subroleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String,
                   subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String) {
                    axWindows.append(element)
                }
            }
            if ProcessInfo.processInfo.systemUptime > deadline { break }
        }
        return axWindows
    }

    /// Visible (current) Space ids across all displays.
    private func visibleSpaceIDs() -> Set<CGSSpaceID> {
        var visible = Set<CGSSpaceID>()
        let displays = CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as? [NSDictionary] ?? []
        for display in displays {
            if let current = display["Current Space"] as? NSDictionary,
               let id = current["id64"] as? CGSSpaceID {
                visible.insert(id)
            }
        }
        return visible
    }

    /// Map each Space id to its 1-based desktop number, in display + Space order
    /// (Desktop 1, Desktop 2, …) — matches Mission Control's numbering.
    private func spaceIndexMap() -> [CGSSpaceID: Int] {
        var map = [CGSSpaceID: Int]()
        var index = 1
        let displays = CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as? [NSDictionary] ?? []
        for display in displays {
            if let spaces = display["Spaces"] as? [NSDictionary] {
                for space in spaces {
                    if let id = space["id64"] as? CGSSpaceID {
                        map[id] = index
                        index += 1
                    }
                }
            }
        }
        return map
    }

    /// Screenshot a window for its thumbnail. Returns nil without Screen Recording
    /// permission. Uses nominal (≈¼) resolution — plenty for a small preview, fast.
    static func captureThumbnail(_ wid: CGWindowID) -> NSImage? {
        var w = wid
        guard let images = CGSHWCaptureWindowList(
            CGS_CONNECTION, &w, 1, [.ignoreGlobalClipShape, .nominalResolution]
        )?.takeRetainedValue() as? [CGImage], let cg = images.first else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Capture window thumbnails in the background and fill them in once the
    /// switcher is already on screen. Opt-in (showWindowPreviews) and only when
    /// Screen Recording is granted; otherwise rows keep their app icon.
    private func captureThumbnailsAsync() {
        guard settingsManager.settings.windowDisplayStyle == .preview,
              CGPreflightScreenCaptureAccess() else { return }
        let snapshot = windows
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (index, window) in snapshot.enumerated() where window.cgWindowID != 0 {
                guard let image = WindowManager.captureThumbnail(window.cgWindowID) else { continue }
                DispatchQueue.main.async {
                    guard let self = self, index < self.windows.count,
                          self.windows[index].cgWindowID == window.cgWindowID else { return }
                    self.windows[index].thumbnail = image
                }
            }
        }
    }

    /// Window ids for the given Spaces, z-ordered (topmost first). includeInvisible
    /// also returns minimized / off-screen windows.
    private func windowsInSpaces(_ spaceIds: [CGSSpaceID], includeInvisible: Bool) -> [CGWindowID] {
        var setTags = 0
        var clearTags = 0
        var options: CGSCopyWindowsOptions = [.screenSaverLevel1000]
        if includeInvisible { options = [.screenSaverLevel1000, .invisible1, .invisible2] }
        return CGSCopyWindowsWithOptionsAndTags(
            CGS_CONNECTION, 0, spaceIds as CFArray, options.rawValue, &setTags, &clearTags
        ) as? [CGWindowID] ?? []
    }

    /// The Space(s) a window belongs to.
    private func spacesForWindow(_ wid: CGWindowID) -> [CGSSpaceID] {
        return CGSCopySpacesForWindows(CGS_CONNECTION, CGSSpaceMask.all.rawValue,
                                       [wid] as CFArray) as? [CGSSpaceID] ?? []
    }

    /// Keep real top-level windows. Accepts AXStandardWindow and AXDialog —
    /// Safari (and some others) report minimized windows as AXDialog, so
    /// excluding dialogs dropped every Dock window. Windows with no subrole are
    /// kept too (some apps don't set one on their main window).
    private func isStandardWindow(_ axWindow: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String {
            return subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String)
        }
        return true
    }

    private func windowTitle(_ axWindow: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            return title
        }
        return ""
    }
     
     // MARK: - CT2 Functionality: list all running apps (like native Command+Tab)
     private func getAllAppsWithWindows() {
        apps = runningRegularApps()
        Logger.log("📊 CT2: listed \(apps.count) running apps")
     }

     /// Every regular (Dock-visible) running app except Lineup itself, ordered so
     /// apps with a window on the current Space come first (front-to-back), then
     /// the rest by name. Testable entry point for the CT2 app list.
     func runningRegularApps() -> [AppInfo] {
        let allApps = NSWorkspace.shared.runningApplications

        // Order hint: apps with a window on the current Space first, by z-order.
        let onscreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var pidZOrder: [pid_t: Int] = [:]
        for (i, info) in onscreen.enumerated() {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pidZOrder[pid] == nil {
                pidZOrder[pid] = i
            }
        }

        var built: [(order: Int, name: String, app: AppInfo)] = []
        for app in allApps {
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  let bundleId = app.bundleIdentifier else {
                continue
            }
            let pid = app.processIdentifier
            let name = app.localizedName ?? "App"
            let info = AppInfo(
                bundleId: bundleId,
                processID: pid,
                appName: name,
                windowCount: axWindowCount(pid),
                isActive: app.isActive
            )
            built.append((order: pidZOrder[pid] ?? Int.max, name: name, app: info))
        }

        built.sort {
            $0.order != $1.order
                ? $0.order < $1.order
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return built.map { $0.app }
     }

     /// Best-effort count of an app's real windows (fast: one AX call, no
     /// brute-force). Includes minimized windows; may undercount windows that
     /// live only on another Space.
     private func axWindowCount(_ pid: pid_t) -> Int {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else {
            return 0
        }
        return axWindows.filter { isStandardWindow($0) }.count
     }
     
     private func getAXWindowInfo(windowID: CGWindowID, processID: pid_t, windowIndex: Int) -> (title: String, axElement: AXUIElement?, isMinimized: Bool) {
         let app = AXUIElementCreateApplication(processID)

         var windowsRef: CFTypeRef?
         guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let axWindows = windowsRef as? [AXUIElement] else {
             Logger.log("   ❌ Cannot get AX window list")
             return ("", nil, false)
         }

         Logger.log("   🔍 Total AX windows: \(axWindows.count), target index: \(windowIndex)")

         guard windowIndex < axWindows.count else {
             Logger.log("   ❌ Window index \(windowIndex) out of range (total: \(axWindows.count))")
             return ("", nil, false)
         }

         let axWindow = axWindows[windowIndex]
         let isMinimized = isWindowMinimized(axWindow)

         var titleRef: CFTypeRef?
         if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String {
             Logger.log("   ✅ Window ID \(windowID) matched successfully through index[\(windowIndex)], title: '\(title)', minimized: \(isMinimized)")
             return (title, axWindow, isMinimized)
         } else {
             Logger.log("   ⚠️ Window ID \(windowID) matched successfully through index[\(windowIndex)], but no title")
             return ("", axWindow, isMinimized)
         }
     }

     /// Read the AX minimized (in-Dock) state of a window element.
     private func isWindowMinimized(_ axWindow: AXUIElement) -> Bool {
         var minimizedRef: CFTypeRef?
         if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
            let minimized = minimizedRef as? Bool {
             return minimized
         }
         return false
     }

     /// Restore a minimized window from the Dock via its AX element.
     private func unminimizeWindow(_ axWindow: AXUIElement) {
         AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
     }
    
    
    private func activateWindow(_ window: WindowInfo) {
        Logger.log("\n🎯 Attempting to activate window ID: \(window.windowID), title: '\(window.title)'")
        
        if activateWindowWithAXEnhanced(window) {
            Logger.log("   ✅ AX enhanced activation successful")
            return
        }
        
        Logger.log("   ⚠️ AX enhanced method failed, trying fallback solution")
        
        let windowBounds = getWindowBounds(windowID: window.windowID)
        
        if let cachedElement = getCachedAXElement(windowID: window.windowID, processID: window.processID, windowIndex: window.axWindowIndex) {
            Logger.log("   ✅ Got AX element (cached or new)")
            
            if activateWindowWithFocusTransfer(axElement: cachedElement, windowBounds: windowBounds, window: window) {
                Logger.log("   ✅ Window activation successful")
                return
            } else {
                Logger.log("   ⚠️ AX element activation failed")
            }
        }
        
        Logger.log("   ❌ Cannot get AX element for window ID \(window.windowID)")
        
        Logger.log("   🔄 Trying final fallback solution")
        fallbackActivateWindowWithFocusTransfer(window.windowID, processID: window.processID, windowBounds: windowBounds)
    }
    
    // MARK: - AX Enhanced Multi-Display Focus Transfer Support
    
    struct DisplayInfo {
        let screen: NSScreen
        let windowRect: CGRect
        let displayID: CGDirectDisplayID
    }
    
    private func activateWindowWithAXEnhanced(_ window: WindowInfo) -> Bool {
        guard let axElement = getCachedAXElement(windowID: window.windowID, processID: window.processID, windowIndex: window.axWindowIndex) else {
            Logger.log("   ❌ AX enhanced activation failed: cannot get AX element")
            return false
        }
        
        Logger.log("   🔄 Using AX enhanced method to activate window")
        
        guard let displayInfo = getWindowDisplayInfo(axElement: axElement) else {
            Logger.log("   ❌ AX enhanced activation failed: cannot get display information")
            return false
        }
        
        let currentScreen = getCurrentFocusedScreen()
        let needsCrossDisplayActivation = (displayInfo.screen != currentScreen)
        
        Logger.log("   📍 Window position: \(displayInfo.windowRect)")
        Logger.log("   🖥️ Target display: \(displayInfo.screen.localizedName)")
        Logger.log("   🔄 Cross-display activation needed: \(needsCrossDisplayActivation)")
        
        if needsCrossDisplayActivation {
            return performCrossDisplayAXActivation(axElement: axElement, displayInfo: displayInfo, window: window)
        } else {
            return performSameDisplayAXActivation(axElement: axElement, window: window)
        }
    }
    
    private func getWindowDisplayInfo(axElement: AXUIElement) -> DisplayInfo? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef else {
            Logger.log("   ⚠️ Cannot get window position")
            return nil
        }
        
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef else {
            Logger.log("   ⚠️ Cannot get window size")
            return nil
        }
        
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) == true,
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &cgSize) == true else {
            Logger.log("   ⚠️ AX value conversion failed")
            return nil
        }
        
        let windowRect = CGRect(origin: point, size: cgSize)
        
        guard let targetScreen = findScreenContaining(rect: windowRect) else {
            Logger.log("   ⚠️ Cannot find display containing window")
            return nil
        }
        
        let displayID = getDisplayID(for: targetScreen)
        
        return DisplayInfo(screen: targetScreen, windowRect: windowRect, displayID: displayID)
    }
    
    private func findScreenContaining(rect: CGRect) -> NSScreen? {
        let windowCenter = CGPoint(x: rect.midX, y: rect.midY)
        
        for screen in NSScreen.screens {
            if screen.frame.contains(windowCenter) {
                return screen
            }
        }
        
        return NSScreen.main
    }
    
    private func getDisplayID(for screen: NSScreen) -> CGDirectDisplayID {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return CGMainDisplayID()
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
    
    private func getCurrentFocusedScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        
        return NSScreen.main
    }
    
    private func performCrossDisplayAXActivation(axElement: AXUIElement, displayInfo: DisplayInfo, window: WindowInfo) -> Bool {
        Logger.log("   🚀 Executing cross-display AX activation")
        
        if !transferFocusToDisplay(displayInfo: displayInfo) {
            Logger.log("   ⚠️ Focus transfer failed, but continuing to try activation")
        }
        
        guard let app = NSRunningApplication(processIdentifier: window.processID) else {
            Logger.log("   ❌ Cannot get application process")
            return false
        }
        
        let appActivated = app.activate()
        Logger.log("   🎯 Application activation result: \(appActivated ? "successful" : "failed")")
        
        let raiseResult = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        Logger.log("   ⬆️ AX window raise result: \(raiseResult == .success ? "successful" : "failed")")
        
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        
        let success = verifyWindowActivation(axElement: axElement, displayInfo: displayInfo)
        Logger.log("   ✅ Cross-display activation \(success ? "successful" : "failed")")
        
        return success
    }
    
    private func performSameDisplayAXActivation(axElement: AXUIElement, window: WindowInfo) -> Bool {
        Logger.log("   🎯 Executing same-display AX activation")
        
        guard let app = NSRunningApplication(processIdentifier: window.processID) else {
            Logger.log("   ❌ Cannot get application process")
            return false
        }
        
        let appActivated = app.activate()
        Logger.log("   🎯 Application activation result: \(appActivated ? "successful" : "failed")")
        
        let raiseResult = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        Logger.log("   ⬆️ AX window raise result: \(raiseResult == .success ? "successful" : "failed")")
        
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        
        return raiseResult == .success
    }
    
    private func transferFocusToDisplay(displayInfo: DisplayInfo) -> Bool {
        Logger.log("   🔄 Transferring focus to display: \(displayInfo.screen.localizedName)")
        
        let targetPoint = CGPoint(
            x: displayInfo.windowRect.midX,
            y: displayInfo.windowRect.midY
        )
        
        guard let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        ) else {
            Logger.log("   ❌ Cannot create mouse movement event")
            return false
        }
        
        moveEvent.post(tap: .cghidEventTap)
        
        usleep(30000) // 30ms
        
        Logger.log("   🖱️ Mouse moved to target window position: (\(targetPoint.x), \(targetPoint.y))")
        return true
    }
    
    private func verifyWindowActivation(axElement: AXUIElement, displayInfo: DisplayInfo) -> Bool {
        var isMainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXMainAttribute as CFString, &isMainRef) == .success,
           let isMain = isMainRef as? Bool, isMain {
            Logger.log("   ✅ Window has become main window")
            return true
        }
        
        var isFocusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXFocusedAttribute as CFString, &isFocusedRef) == .success,
           let isFocused = isFocusedRef as? Bool, isFocused {
            Logger.log("   ✅ Window has gained focus")
            return true
        }
        
        Logger.log("   ⚠️ Window activation verification failed, but may still be successful")
        return false
    }
    
    private func getWindowBounds(windowID: CGWindowID) -> CGRect? {
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, windowID) as? [[String: Any]] ?? []
        
        for windowInfo in windowList {
            if let id = windowInfo[kCGWindowNumber as String] as? CGWindowID, id == windowID {
                if let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
                   let x = bounds["X"] as? NSNumber,
                   let y = bounds["Y"] as? NSNumber,
                   let width = bounds["Width"] as? NSNumber,
                   let height = bounds["Height"] as? NSNumber {
                    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
                }
            }
        }
        
        return nil
    }
    
    private func activateWindowWithFocusTransfer(axElement: AXUIElement, windowBounds: CGRect?, window: WindowInfo) -> Bool {
        if let bounds = windowBounds {
            moveCursorToWindowDisplay(windowBounds: bounds)
        }
        
        usleep(50000) // 50ms
        
        let raiseResult = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        Logger.log("   AXRaiseAction result: \(raiseResult == .success ? "successful" : "failed")")
        
        if let app = NSRunningApplication(processIdentifier: window.processID) {
            let activateResult = app.activate()
            Logger.log("   Application activation result: \(activateResult ? "successful" : "failed")")
        }
        
        if raiseResult == .success {
            AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            
            AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            
            return true
        }
        
        return false
    }
    
    private func moveCursorToWindowDisplay(windowBounds: CGRect) {
        let currentCursorLocation = NSEvent.mouseLocation
        let windowCenter = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        
        let screens = NSScreen.screens
        var totalHeight: CGFloat = 0
        for screen in screens {
            totalHeight = max(totalHeight, screen.frame.maxY)
        }
        let flippedWindowCenter = CGPoint(x: windowCenter.x, y: totalHeight - windowCenter.y)
        
        var targetScreen: NSScreen?
        for screen in screens {
            if screen.frame.contains(flippedWindowCenter) {
                targetScreen = screen
                break
            }
        }
        
        var currentScreen: NSScreen?
        for screen in screens {
            if screen.frame.contains(currentCursorLocation) {
                currentScreen = screen
                break
            }
        }
        
        if let target = targetScreen, target != currentScreen {
            Logger.log("   🖱️ Moving mouse from display \(currentScreen?.localizedName ?? "unknown") to \(target.localizedName)")
            
            let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: windowCenter, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)
            
            Logger.log("   🖱️ Mouse moved to window center: (\(windowCenter.x), \(windowCenter.y))")
        } else {
            Logger.log("   🖱️ Mouse is already on target display, no need to move")
        }
    }
    
    private func fallbackActivateWindowWithFocusTransfer(_ windowID: CGWindowID, processID: pid_t, windowBounds: CGRect?) {
        if let bounds = windowBounds {
            moveCursorToWindowDisplay(windowBounds: bounds)
        }
        
        usleep(50000) // 50ms
        
        if let app = NSRunningApplication(processIdentifier: processID) {
            let activateResult = app.activate()
            Logger.log("   Fallback solution - Application activation result: \(activateResult ? "successful" : "failed")")
        }
        
        Logger.log("   ⚠️ Using fallback solution, can only activate application, cannot precisely control window")
        Logger.log("   🖱️ Mouse moved to target window's display to improve focus transfer")
    }
    
    private func fallbackActivateWindow(_ windowID: CGWindowID, processID: pid_t) {
        if let app = NSRunningApplication(processIdentifier: processID) {
            let activateResult = app.activate()
            Logger.log("   Fallback solution - Application activation result: \(activateResult ? "successful" : "failed")")
        }
        
        Logger.log("   ⚠️ Using fallback solution, can only activate application, cannot precisely control window")
    }
    
    // MARK: - Enhanced Event Handling Mechanism (Solution 3)
    
    private func setupUnifiedEventHandling() {
        cleanupEventMonitors()
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            return self?.handleUnifiedKeyEvent(event, isGlobal: false)
        }
        
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            // Global monitors are observe-only; the return value can't consume
            // the event, so it is intentionally discarded.
            _ = self?.handleUnifiedKeyEvent(event, isGlobal: true)
        }
        
        Logger.log("🔧 Unified event handling mechanism has been set up")
    }
    
    private func handleUnifiedKeyEvent(_ event: NSEvent, isGlobal: Bool) -> NSEvent? {
        guard !isProcessingKeyEvent else {
            return isGlobal ? nil : event
        }
        
        isProcessingKeyEvent = true
        defer { isProcessingKeyEvent = false }
        
        let eventSource = isGlobal ? "global" : "local"
        
        if isShowingSwitcher {
            return handleDS2UnifiedEvent(event, source: eventSource)
        } else if isShowingAppSwitcher {
            return handleCT2UnifiedEvent(event, source: eventSource)
        }
        
        return isGlobal ? nil : event
    }
    
    private func handleDS2UnifiedEvent(_ event: NSEvent, source: String) -> NSEvent? {
        let settings = settingsManager.settings
        
        switch event.type {
        case .keyUp:
            if event.keyCode == 53 { // ESC key
                Logger.log("🔴 [\(source)] ESC — cancelling DS2 switcher")
                hideSwitcherAsync(activate: false)
                return nil
            }
            
        case .keyDown:
            // Arrow up/down to move through the list, Enter to confirm (issue #6)
            switch event.keyCode {
            case 125: // Down arrow
                Logger.log("⬇️ [\(source)] DS2 arrow down")
                moveToNextWindow()
                return nil
            case 126: // Up arrow
                Logger.log("⬆️ [\(source)] DS2 arrow up")
                moveToPreviousWindow()
                return nil
            case 36, 76: // Return / keypad Enter
                Logger.log("↩️ [\(source)] DS2 Enter, activating selected window")
                hideSwitcherAsync()
                return nil
            default:
                break
            }

            if let numberKey = keyCodeToNumberKey(event.keyCode) {
                Logger.log("🔢 [\(source)] DS2 number key \(numberKey) pressed")
                selectWindowByNumberKey(numberKey)
                return nil
            }

            if event.keyCode == UInt16(settings.triggerKey.keyCode) {
                if event.modifierFlags.contains(settings.modifierKey.eventModifier) {
                    // A quick second trigger tap (within 350 ms of opening) engages
                    // peek/hold mode: the switcher stays open after the modifier is
                    // released, so you can browse across desktops hands-free.
                    if settings.doubleTapToHold && !switcherHeld
                        && Date().timeIntervalSince(switcherOpenTime) < 0.35 {
                        switcherHeld = true
                        Logger.log("📌 [\(source)] DS2 double-tap → hold mode engaged")
                    }

                    let isShiftPressed = event.modifierFlags.contains(.shift)
                    if isShiftPressed {
                        moveToPreviousWindow()
                    } else {
                        moveToNextWindow()
                    }
                    return nil
                }
            }

        case .flagsChanged:
            let now = Date()
            let timeSinceLastModifier = now.timeIntervalSince(lastModifierEventTime)

            if timeSinceLastModifier < 0.05 {
                return source == "global" ? nil : event
            }

            lastModifierEventTime = now

            if !event.modifierFlags.contains(settings.modifierKey.eventModifier) {
                // In hold mode the switcher stays open after the modifier is
                // released (dismissed later via Enter/click/Esc).
                if switcherHeld {
                    Logger.log("📌 [\(source)] modifier released but switcher is held open")
                    return source == "global" ? nil : event
                }
                Logger.log("🔴 [\(source)] \(settings.modifierKey.displayName) key release detected, closing DS2 switcher")
                hideSwitcherAsync()
                return nil
            }

        default:
            break
        }

        return source == "global" ? nil : event
    }

    private func handleCT2UnifiedEvent(_ event: NSEvent, source: String) -> NSEvent? {
        let settings = settingsManager.settings
        
        switch event.type {
        case .keyUp:
            if event.keyCode == 53 { // ESC key
                Logger.log("🔴 [\(source)] ESC — cancelling CT2 switcher")
                hideAppSwitcherAsync(activate: false)
                return nil
            }
            
        case .keyDown:
            // Arrow up/down to move through the list, Enter to confirm (issue #6)
            switch event.keyCode {
            case 125: // Down arrow
                Logger.log("⬇️ [\(source)] CT2 arrow down")
                moveToNextApp()
                return nil
            case 126: // Up arrow
                Logger.log("⬆️ [\(source)] CT2 arrow up")
                moveToPreviousApp()
                return nil
            case 36, 76: // Return / keypad Enter
                Logger.log("↩️ [\(source)] CT2 Enter, activating selected app")
                hideAppSwitcherAsync()
                return nil
            default:
                break
            }

            if let numberKey = keyCodeToNumberKey(event.keyCode) {
                Logger.log("🔢 [\(source)] CT2 number key \(numberKey) pressed")
                selectAppByNumberKey(numberKey)
                return nil
            }

            if event.keyCode == UInt16(settings.ct2TriggerKey.keyCode) {
                if event.modifierFlags.contains(settings.ct2ModifierKey.eventModifier) {
                    let isShiftPressed = event.modifierFlags.contains(.shift)
                    
                    if isShiftPressed {
                        Logger.log("🟢 [\(source)] CT2 reverse switch: \(currentAppIndex) -> ", terminator: "")
                        moveToPreviousApp()
                    } else {
                        Logger.log("🟢 [\(source)] CT2 forward switch: \(currentAppIndex) -> ", terminator: "")
                        moveToNextApp()
                    }	
                    return nil
                }
            }
            
        case .flagsChanged:
            let now = Date()
            let timeSinceLastModifier = now.timeIntervalSince(lastModifierEventTime)
            
            if timeSinceLastModifier < 0.05 {
                return source == "global" ? nil : event
            }
            
            lastModifierEventTime = now
            
            if !event.modifierFlags.contains(settings.ct2ModifierKey.eventModifier) {
                Logger.log("🔴 [\(source)] \(settings.ct2ModifierKey.displayName) key release detected, closing CT2 switcher")
                hideAppSwitcherAsync()
                return nil
            }
            
        default:
            break
        }
        
        return source == "global" ? nil : event
    }
    
    private func cleanupEventMonitors() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let globalMonitor = globalEventMonitor {
            NSEvent.removeMonitor(globalMonitor)
            globalEventMonitor = nil
        }
    }
    
    // MARK: - Async Window Activation Optimization (Solution 2)
    
    /// Hide the DS2 switcher. `activate: false` cancels without switching windows
    /// (used by Esc), so the switcher is a true preview you can back out of.
    private func hideSwitcherAsync(activate: Bool = true) {
        guard isShowingSwitcher else { return }

        isShowingSwitcher = false
        switcherHeld = false

        stopModifierKeyWatchdog()
        stopNumberKeyGlobalIntercept()
        cleanupEventMonitors()
        hotkeyManager?.reEnableHotkey()

        let targetWindow = activate && currentWindowIndex < windows.count ? windows[currentWindowIndex] : nil
        // Ride the Space slide only when actually crossing desktops, so same-desktop
        // selection stays instant.
        let rideTransition = settingsManager.settings.followAcrossDesktops
            && (targetWindow?.isOnOtherSpace ?? false)

        // Activate first (this triggers the Space switch), then fade the panel out
        // over the transition.
        if let targetWindow = targetWindow {
            Logger.log("🎯 Activating window: \(targetWindow.title)")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.activateWindowAsync(targetWindow)
            }
        }

        dismissSwitcherWindow(rideTransition: rideTransition)

        // Free the (potentially multi-MB thumbnail / AX-element) window list now.
        windows.removeAll()
        DispatchQueue.global(qos: .utility).async {
            AppIconCache.shared.clearCache()
        }
    }
    
    private func hideAppSwitcherAsync(activate: Bool = true) {
        guard isShowingAppSwitcher else { return }

        isShowingAppSwitcher = false

        stopModifierKeyWatchdog()
        stopNumberKeyGlobalIntercept()
        cleanupEventMonitors()
        hotkeyManager?.reEnableHotkey()
        hotkeyManager?.resetCT2SwitcherState()

        // An app switch often crosses desktops; ride the slide when enabled.
        let rideTransition = activate && settingsManager.settings.followAcrossDesktops

        if activate, currentAppIndex < apps.count {
            let target = apps[currentAppIndex]
            Logger.log("🎯 Activating application: \(target.appName)")
            // Activate the whole app — brings it to front and switches to the
            // Space holding its windows (incl. minimized / other-desktop apps).
            NSRunningApplication(processIdentifier: target.processID)?
                .activate(options: [.activateAllWindows])
        }

        dismissSwitcherWindow(rideTransition: rideTransition)

        apps.removeAll()
        DispatchQueue.global(qos: .utility).async {
            AppIconCache.shared.clearCache()
        }
    }
    
    private func activateWindowAsync(_ window: WindowInfo) {
        Logger.log("🚀 Async window activation started: \(window.title)")
        
        guard let app = NSRunningApplication(processIdentifier: window.processID) else {
            Logger.log("❌ Cannot find application corresponding to process ID \(window.processID)")
            return
        }
        
        DispatchQueue.main.async {
            let activated = app.activate()
            Logger.log("   📱 Application activation result: \(activated ? "successful" : "failed")")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.activateSpecificWindowFast(window)
        }
    }
    
    private func activateSpecificWindowFast(_ window: WindowInfo) {
        Logger.log("⚡ Fast activation of specific window: \(window.title)")

        // SkyLight path (DS2): the enumerator gives us the real window id + element.
        // _SLPSSetFrontProcessWithOptions scoped to the window switches Spaces as a
        // side-effect (there is no public Set-current-space API); makeKeyWindow +
        // AXRaise then bring the exact window forward. Un-minimize first if needed.
        // If the SkyLight SPI didn't resolve (future macOS), fall through to AX.
        if window.cgWindowID != 0 && slpsAvailable {
            let axElement = window.axElement
            if window.isMinimized, let el = axElement {
                Logger.log("   📤 Restoring minimized window from the Dock")
                unminimizeWindow(el)
            }

            var psn = ProcessSerialNumber()
            GetProcessForPID(window.processID, &psn)
            _SLPSSetFrontProcessWithOptions(&psn, window.cgWindowID, SLPSMode.userGenerated.rawValue)
            makeKeyWindow(&psn, window.cgWindowID)
            if let el = axElement {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
            // Note: deliberately NOT calling NSRunningApplication.activate() here.
            // The SLPS front-process call already switches Spaces and focuses the
            // window; an extra activate() re-triggers the Space transition and
            // makes it visibly stutter (AltTab omits it for the same reason).
            Logger.log("   ✅ SkyLight activation completed (otherSpace=\(window.isOnOtherSpace), minimized=\(window.isMinimized))")
            return
        }

        // Legacy AX path (CT2 firstWindow, or DS2 windows with no real id). Prefer
        // the element resolved at enumeration time; only fall back to the
        // index-based cache lookup when we don't have one (avoids raising the
        // wrong window via a hardcoded index 0).
        if let axElement = window.axElement ?? getCachedAXElement(
            windowID: window.windowID,
            processID: window.processID,
            windowIndex: window.axWindowIndex
        ) {
            if window.isMinimized || isWindowMinimized(axElement) {
                unminimizeWindow(axElement)
            }
            AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            let raiseResult = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: window.processID)?.activate()
            if raiseResult == .success {
                return
            }
        }

        Logger.log("   ⚠️ AX method failed, using fallback solution")
        fallbackActivateAsync(window)
    }

    /// Make the given window the key window by posting a synthesized WindowServer
    /// event pair. Ported from AltTab / Hammerspoon issue #370.
    private func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowId: CGWindowID) {
        var wid = windowId
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }
    
    private func fallbackActivateAsync(_ window: WindowInfo) {
        if let app = NSRunningApplication(processIdentifier: window.processID) {
            app.activate()
            Logger.log("   📱 Fallback solution: application activated")
        }
        
    }
    
    // MARK: - Modifier Key Watchdog Mechanism
    
    private func startModifierKeyWatchdog(for switcherType: SwitcherType) {
        stopModifierKeyWatchdog()
        
        watchdogCallCount = 0
        watchdogPhase = 0
        lastSwitchTime = Date()
        
        let timeSinceLastSwitch = Date().timeIntervalSince(lastSwitchTime)
        let shouldUseWatchdog = timeSinceLastSwitch < 2.0
        
        if !shouldUseWatchdog {
            Logger.log("🐕 Watchdog: not a fast switching scenario, skipping startup")
            return
        }
        
        Logger.log("🐕 Starting modifier key watchdog, type: \(switcherType == .ds2 ? "DS2" : "CT2"), interval: \(Int(watchdogInterval * 1000))ms")
        
        modifierKeyWatchdog = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkModifierKeyState(for: switcherType)
        }
    }
    
    private func stopModifierKeyWatchdog() {
        guard let watchdog = modifierKeyWatchdog else { return }
        
        Logger.log("🐕 Stopping modifier key watchdog, runtime: \(String(format: "%.1f", Double(watchdogCallCount) * watchdogInterval))s, detection count: \(watchdogCallCount)")
        
        watchdog.invalidate()
        modifierKeyWatchdog = nil
        watchdogCallCount = 0
        watchdogPhase = 0
    }
    
    private func checkModifierKeyState(for switcherType: SwitcherType) {
        watchdogCallCount += 1
        watchdogPhase += 1
        
        if watchdogCallCount > 1000 {
            Logger.log("🐕⚠️ Watchdog timeout auto-stop (1000 detections)")
            stopModifierKeyWatchdog()
            return
        }
        
        let currentModifiers = NSEvent.modifierFlags
        let settings = settingsManager.settings
        
        let requiredModifier: NSEvent.ModifierFlags
        let modifierName: String
        let isActive: Bool
        
        switch switcherType {
        case .ds2:
            requiredModifier = settings.modifierKey.eventModifier
            modifierName = settings.modifierKey.displayName
            isActive = isShowingSwitcher
        case .ct2:
            requiredModifier = settings.ct2ModifierKey.eventModifier
            modifierName = settings.ct2ModifierKey.displayName
            isActive = isShowingAppSwitcher
        }
        
        if !isActive {
            Logger.log("🐕 Watchdog detected switcher closed, auto-stopping")
            stopModifierKeyWatchdog()
            return
        }
        
        if !currentModifiers.contains(requiredModifier) {
            // In hold mode (DS2 peek), don't auto-close on modifier release; the
            // user dismisses explicitly. Stop the watchdog so it doesn't keep firing.
            if switcherType == .ds2 && switcherHeld {
                Logger.log("🐕📌 Watchdog: modifier released but switcher is held; standing down")
                stopModifierKeyWatchdog()
                return
            }
            Logger.log("🐕🚨 [Watchdog Detection] \(modifierName) key released, immediately closing \(switcherType == .ds2 ? "DS2" : "CT2") switcher")
            stopModifierKeyWatchdog()

            DispatchQueue.main.async { [weak self] in
                switch switcherType {
                case .ds2:
                    self?.hideSwitcherAsync()
                case .ct2:
                    self?.hideAppSwitcherAsync()
                }
            }
            return
        }
        
        if watchdogPhase == 10 {
            Logger.log("🐕 Watchdog entering low frequency mode")
            stopModifierKeyWatchdog()
            
            modifierKeyWatchdog = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
                self?.checkModifierKeyState(for: switcherType)
            }
        }
        
        if watchdogCallCount % 100 == 0 {
            Logger.log("🐕 Watchdog running normally, detected \(watchdogCallCount) times, \(modifierName) key status: pressed")
        }
    }
    
    // MARK: - Preview Support Methods

    func getWindowTitlesForPreview(_ bundleId: String) -> [String] {
        Logger.log("🔍 [Preview] Getting all window titles for bundle ID: \(bundleId)")
        
        let allApps = NSWorkspace.shared.runningApplications
        let runningAppMap = Dictionary(uniqueKeysWithValues: allApps.map { ($0.processIdentifier, $0) })
        var bundlePrimaryApp: [String: NSRunningApplication] = [:]

        for app in allApps where app.activationPolicy == .regular {
            guard let appBundleId = app.bundleIdentifier else { continue }
            if bundlePrimaryApp[appBundleId] == nil {
                bundlePrimaryApp[appBundleId] = app
            }
        }

        guard let targetApp = bundlePrimaryApp[bundleId] ?? allApps.first(where: { $0.bundleIdentifier == bundleId }) else {
            Logger.log("❌ [Preview] No running application found with bundle ID: \(bundleId)")
            return []
        }
        
        Logger.log("✅ [Preview] Found application: \(targetApp.localizedName ?? "Unknown") (PID: \(targetApp.processIdentifier))")
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        Logger.log("🔍 [Preview] Inspecting \(windowList.count) CG windows")

        var windowTitles: Set<String> = []
        var windowIndexByProcess: [pid_t: Int] = [:]

        for windowInfo in windowList {
            guard let processID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String

            if !windowBelongsToApp(
                windowProcessID: processID,
                ownerName: ownerName,
                targetApp: targetApp,
                runningAppMap: runningAppMap,
                bundlePrimaryApp: bundlePrimaryApp
            ) {
                continue
            }

            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else {
                continue
            }

            let hasValidID = windowID > 0
            let hasValidLayer = isValidWindowLayer(layer, forBundleId: targetApp.bundleIdentifier)
            let hasReasonableSize = width.intValue > 100 && height.intValue > 100

            if !(hasValidID && hasValidLayer && hasReasonableSize && isOnScreen) {
                continue
            }

            let currentIndex = windowIndexByProcess[processID] ?? 0
            windowIndexByProcess[processID] = currentIndex + 1

            let cgTitle = windowInfo[kCGWindowName as String] as? String ?? ""
            let (axTitle, _, _) = getAXWindowInfo(windowID: windowID, processID: processID, windowIndex: currentIndex)

            let finalTitle: String
            if !axTitle.isEmpty {
                finalTitle = axTitle
            } else if !cgTitle.isEmpty {
                finalTitle = cgTitle
            } else {
                finalTitle = "\(targetApp.localizedName ?? "App") window \(windowIndexByProcess[processID] ?? 1)"
            }

            if !finalTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                windowTitles.insert(finalTitle)
                Logger.log("   ✅ [Preview] Window found: '\(finalTitle)' (Owner: \(ownerName ?? "Unknown"), PID: \(processID), Layer: \(layer))")
            }
        }

        let sortedTitles = windowTitles.sorted()
        Logger.log("📋 [Preview] Total unique window titles found: \(sortedTitles.count)")
        for (index, title) in sortedTitles.enumerated() {
            Logger.log("   \(index + 1). '\(title)'")
        }

        return sortedTitles
    }
    
    // MARK: - Number Key Mapping Helper
    
    private func keyCodeToNumberKey(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1  // kVK_ANSI_1
        case 19: return 2  // kVK_ANSI_2
        case 20: return 3  // kVK_ANSI_3
        case 21: return 4  // kVK_ANSI_4
        case 23: return 5  // kVK_ANSI_5
        case 22: return 6  // kVK_ANSI_6
        case 26: return 7  // kVK_ANSI_7
        case 28: return 8  // kVK_ANSI_8
        case 25: return 9  // kVK_ANSI_9
        default: return nil
        }
    }
    
    // MARK: - Number Key Global Intercept
    
    private func startNumberKeyGlobalIntercept() {
        stopNumberKeyGlobalIntercept()
        
        let eventCallback: CGEventTapCallBack = { (_, type, event, refcon) in
            let windowManager = Unmanaged<WindowManager>.fromOpaque(refcon!).takeUnretainedValue()

            // macOS disables a tap after a slow callback or user input; re-enable
            // it so the number-key intercept doesn't die silently.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = windowManager.numberKeyEventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            // Only swallow digits while a switcher is actually visible — otherwise
            // they would be eaten in every app.
            guard type == .keyDown,
                  windowManager.isShowingSwitcher || windowManager.isShowingAppSwitcher else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let numberKey = windowManager.keyCodeToNumberKey(UInt16(keyCode)) {
                DispatchQueue.main.async {
                    if windowManager.isShowingSwitcher {
                        windowManager.selectWindowByNumberKey(numberKey)
                    } else if windowManager.isShowingAppSwitcher {
                        windowManager.selectAppByNumberKey(numberKey)
                    }
                }
                return nil
            }

            return Unmanaged.passUnretained(event)
        }
        
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        numberKeyEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventCallback,
            userInfo: selfPtr
        )
        
        if let eventTap = numberKeyEventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            
            CGEvent.tapEnable(tap: eventTap, enable: true)
            
            Logger.log("🎯 Number key global intercept started")
        } else {
            Logger.log("❌ Failed to create number key event tap")
        }
    }
    
    private func stopNumberKeyGlobalIntercept() {
        if let eventTap = numberKeyEventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            numberKeyEventTap = nil
            Logger.log("🛑 Number key global intercept stopped")
        }
    }
} 
