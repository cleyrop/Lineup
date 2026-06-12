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

struct WindowInfo {
    let windowID: CGWindowID
    let title: String
    let projectName: String
    let appName: String
    let processID: pid_t
    let axWindowIndex: Int  // AX window index
}

// MARK: - App Info Data Structure
struct AppInfo {
    let bundleId: String
    let processID: pid_t
    let appName: String
    let firstWindow: WindowInfo?  // First window of this app
    let windowCount: Int         // Total window count of this app
    let isActive: Bool           // Whether it's the currently active app
    let lastUsedTime: Date?      // Last used time
    
    init(bundleId: String, processID: pid_t, appName: String, windows: [WindowInfo], isActive: Bool = false, lastUsedTime: Date? = nil) {
        self.bundleId = bundleId
        self.processID = processID
        self.appName = appName
        self.firstWindow = windows.first
        self.windowCount = windows.count
        self.isActive = isActive
        self.lastUsedTime = lastUsedTime
    }
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
        
        let afterProcessCleanup = axElementCache.count
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
        let (_, axElement) = getAXWindowInfo(windowID: windowID, processID: processID, windowIndex: windowIndex)
        
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
        switcherWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        switcherWindow?.isReleasedWhenClosed = false
        switcherWindow?.level = .floating
        switcherWindow?.backgroundColor = NSColor.clear
        switcherWindow?.hasShadow = true
        switcherWindow?.isOpaque = false
        
        // Initial content view will be set on first display
        switcherWindow?.contentView = NSView() // Temporary empty view
        
        // Position will be set when displaying
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
                    for screen in NSScreen.screens {
                        if screen.frame.contains(point) {
                            return screen
                        }
                    }
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
        
        let windowPoint = CGPoint(x: x, y: y)
        
        for screen in NSScreen.screens {
            if screen.frame.contains(windowPoint) {
                return screen
            }
        }
        
        return nil
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
        
        hotkeyManager?.temporarilyDisableHotkey()
        
        currentViewType = .ds2
        switcherWindow?.contentView = createDS2HostingView()
        
        positionSwitcherWindow()
        
        switcherWindow?.makeKeyAndOrderFront(nil)
        NSApp.activateCompat()
        
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
        
        switcherWindow?.makeKeyAndOrderFront(nil)
        NSApp.activateCompat()
        
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
        
        var candidateWindows: [[String: Any]] = []
        var validWindows: [[String: Any]] = []
        var windowCounter = 1
        var windowIndexByProcess: [pid_t: Int] = [:]

        for windowInfo in windowList {
            guard let processID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String

            if windowBelongsToApp(
                windowProcessID: processID,
                ownerName: ownerName,
                targetApp: targetApp,
                runningAppMap: runningAppMap,
                bundlePrimaryApp: bundlePrimaryApp
            ) {
                candidateWindows.append(windowInfo)
                
                let windowTitle = windowInfo[kCGWindowName as String] as? String ?? ""
                let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
                let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID ?? 0
                let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
                
                Logger.log("🔎 Checking target application window:")
                Logger.log("   Owner: \(ownerName ?? "Unknown") (PID: \(processID))")
                Logger.log("   Title: '\(windowTitle)'")
                Logger.log("   Layer: \(layer)")
                Logger.log("   ID: \(windowID)")
                Logger.log("   OnScreen: \(isOnScreen)")
                
                let hasValidID = windowInfo[kCGWindowNumber as String] is CGWindowID
                let hasValidLayer = isValidWindowLayer(layer, forBundleId: targetApp.bundleIdentifier)
                let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
                let width = (bounds?["Width"] as? NSNumber)?.intValue ?? 0
                let height = (bounds?["Height"] as? NSNumber)?.intValue ?? 0
                let hasReasonableSize = width > 100 && height > 100
                
                Logger.log("   Filter check: ID=\(hasValidID), Layer=\(hasValidLayer), Size=\(width)x\(height), ReasonableSize=\(hasReasonableSize)")
                
                if hasValidID && hasValidLayer && hasReasonableSize {
                    validWindows.append(windowInfo)

                    let currentIndex = windowIndexByProcess[processID] ?? 0
                    windowIndexByProcess[processID] = currentIndex + 1
                    
                    let (axTitle, _) = getAXWindowInfo(windowID: windowID, processID: processID, windowIndex: currentIndex)
                    
                    let displayTitle: String
                    let projectName: String
                    
                    if !axTitle.isEmpty {
                        displayTitle = axTitle
                        projectName = settingsManager.extractProjectName(
                            from: axTitle,
                            bundleId: targetApp.bundleIdentifier ?? "",
                            appName: targetApp.localizedName ?? ""
                        )
                    } else if !windowTitle.isEmpty {
                        displayTitle = windowTitle
                        projectName = settingsManager.extractProjectName(
                            from: windowTitle,
                            bundleId: targetApp.bundleIdentifier ?? "",
                            appName: targetApp.localizedName ?? ""
                        )
                    } else {
                        displayTitle = "\(targetApp.localizedName ?? "App") window \(windowCounter)"
                        projectName = displayTitle
                        windowCounter += 1
                    }
                    
                    let window = WindowInfo(
                        windowID: windowID,
                        title: displayTitle,
                        projectName: projectName,
                        appName: targetApp.localizedName ?? "",
                        processID: processID,
                        axWindowIndex: currentIndex
                    )
                    
                    windows.append(window)
                    Logger.log("   ✅ Window added: '\(projectName)'")
                } else {
                    Logger.log("   ❌ Window filtered out")
                }
                Logger.log("")
            }
        }
        
                 Logger.log("📊 Statistics result:")
         Logger.log("   Target application candidate windows: \(candidateWindows.count)")
         Logger.log("   Valid windows: \(validWindows.count)")
         Logger.log("   Final added windows: \(windows.count)")
         Logger.log("=== Debug Information End ===\n")
     }
     
     // MARK: - CT2 Functionality: Get Window Info for All Apps
     private func getAllAppsWithWindows() {
         apps.removeAll()
         
         Logger.log("\n=== CT2 Debug Information Start ===")
         
        let allApps = NSWorkspace.shared.runningApplications
        Logger.log("Total running applications: \(allApps.count)")
        let runningAppMap = Dictionary(uniqueKeysWithValues: allApps.map { ($0.processIdentifier, $0) })
        var bundlePrimaryApp: [String: NSRunningApplication] = [:]
         
         let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
         Logger.log("System found \(windowList.count) windows in total")
         
        var appWindows: [pid_t: [WindowInfo]] = [:]
        var appInfoMap: [pid_t: (bundleId: String, appName: String)] = [:]
        var appFirstWindowOrder: [pid_t: Int] = [:]

        for app in allApps {
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  let bundleId = app.bundleIdentifier else {
                continue
            }

            appInfoMap[app.processIdentifier] = (
                bundleId: bundleId,
                appName: app.localizedName ?? "Unknown App"
            )

            if bundlePrimaryApp[bundleId] == nil {
                bundlePrimaryApp[bundleId] = app
            }
        }
         
         Logger.log("Valid application count: \(appInfoMap.count)")
         
        var windowCounter = 1
        var axWindowIndexByProcess: [pid_t: Int] = [:]

        for (windowIndex, windowInfo) in windowList.enumerated() {
            guard let processID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
            guard let resolvedApp = resolvePrimaryApp(
                for: processID,
                ownerName: ownerName,
                runningAppMap: runningAppMap,
                bundlePrimaryApp: bundlePrimaryApp
            ),
            resolvedApp.bundleIdentifier != Bundle.main.bundleIdentifier,
            let appInfo = appInfoMap[resolvedApp.processIdentifier] else {
                continue
            }

            let windowTitle = windowInfo[kCGWindowName as String] as? String ?? ""
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
            let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID ?? 0
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false

            let hasValidID = windowInfo[kCGWindowNumber as String] is CGWindowID
            let hasValidLayer = isValidWindowLayer(layer, forBundleId: resolvedApp.bundleIdentifier)
            let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.intValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.intValue ?? 0
            let hasReasonableSize = width > 100 && height > 100

            if hasValidID && hasValidLayer && hasReasonableSize && isOnScreen {
                if isSteamApplication(appInfo.bundleId) {
                    Logger.log("   🎮 CT2: Steam window detected: Layer \(layer), ID \(windowID) (Owner: \(ownerName ?? "Unknown"), PID: \(processID))")
                }

                if appFirstWindowOrder[resolvedApp.processIdentifier] == nil {
                    appFirstWindowOrder[resolvedApp.processIdentifier] = windowIndex
                }

                let currentOwnerWindowCount = axWindowIndexByProcess[processID] ?? 0
                axWindowIndexByProcess[processID] = currentOwnerWindowCount + 1

                let (axTitle, _) = getAXWindowInfo(
                    windowID: windowID,
                    processID: processID,
                    windowIndex: currentOwnerWindowCount
                )

                let displayTitle: String
                let projectName: String

                if !axTitle.isEmpty {
                    displayTitle = axTitle
                    projectName = settingsManager.extractProjectName(
                        from: axTitle,
                        bundleId: appInfo.bundleId,
                        appName: appInfo.appName
                    )
                } else if !windowTitle.isEmpty {
                    displayTitle = windowTitle
                    projectName = settingsManager.extractProjectName(
                        from: windowTitle,
                        bundleId: appInfo.bundleId,
                        appName: appInfo.appName
                    )
                } else {
                    displayTitle = "\(appInfo.appName) window \(windowCounter)"
                    projectName = displayTitle
                    windowCounter += 1
                }

                let window = WindowInfo(
                    windowID: windowID,
                    title: displayTitle,
                    projectName: projectName,
                    appName: appInfo.appName,
                    processID: processID,
                    axWindowIndex: currentOwnerWindowCount
                )

                if appWindows[resolvedApp.processIdentifier] == nil {
                    appWindows[resolvedApp.processIdentifier] = []
                }
                appWindows[resolvedApp.processIdentifier]?.append(window)
            }
        }
         
        for (processID, windows) in appWindows {
            guard let appInfo = appInfoMap[processID], !windows.isEmpty else {
                continue
            }

            let runningApp = runningAppMap[processID]
            let isActive = runningApp?.isActive ?? false

            let app = AppInfo(
                bundleId: appInfo.bundleId,
                processID: processID,
                appName: appInfo.appName,
                windows: windows,
                isActive: isActive,
                lastUsedTime: nil
            )

            apps.append(app)
        }
         
         apps.sort { app1, app2 in
             let order1 = appFirstWindowOrder[app1.processID] ?? Int.max
             let order2 = appFirstWindowOrder[app2.processID] ?? Int.max
             
             if order1 != order2 {
                 return order1 < order2
             }
             
             return app1.appName.localizedCaseInsensitiveCompare(app2.appName) == .orderedAscending
         }
         
         Logger.log("📊 CT2 Statistics result:")
         Logger.log("   Valid application count: \(apps.count)")
         for (index, app) in apps.enumerated() {
             let activeStatus = app.isActive ? " [ACTIVE]" : ""
             Logger.log("   \(index + 1). \(app.appName): \(app.windowCount) windows\(activeStatus)")
         }
         Logger.log("=== CT2 Debug Information End ===\n")
     }
     
     private func getAXWindowInfo(windowID: CGWindowID, processID: pid_t, windowIndex: Int) -> (title: String, axElement: AXUIElement?) {
         let app = AXUIElementCreateApplication(processID)
         
         var windowsRef: CFTypeRef?
         guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let axWindows = windowsRef as? [AXUIElement] else {
             Logger.log("   ❌ Cannot get AX window list")
             return ("", nil)
         }
         
         Logger.log("   🔍 Total AX windows: \(axWindows.count), target index: \(windowIndex)")
         
         guard windowIndex < axWindows.count else {
             Logger.log("   ❌ Window index \(windowIndex) out of range (total: \(axWindows.count))")
             return ("", nil)
         }
         
         let axWindow = axWindows[windowIndex]
         
         var titleRef: CFTypeRef?
         if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String {
             Logger.log("   ✅ Window ID \(windowID) matched successfully through index[\(windowIndex)], title: '\(title)'")
             return (title, axWindow)
         } else {
             Logger.log("   ⚠️ Window ID \(windowID) matched successfully through index[\(windowIndex)], but no title")
             return ("", axWindow)
         }
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
            self?.handleUnifiedKeyEvent(event, isGlobal: true)
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
                Logger.log("🔴 [\(source)] ESC key detected, closing DS2 switcher")
                hideSwitcherAsync()
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
                    let isShiftPressed = event.modifierFlags.contains(.shift)
                    
                    if isShiftPressed {
                        Logger.log("🟢 [\(source)] DS2 reverse switch: \(currentWindowIndex) -> ", terminator: "")
                        moveToPreviousWindow()
                        Logger.log("\(currentWindowIndex)")
                    } else {
                        Logger.log("🟢 [\(source)] DS2 forward switch: \(currentWindowIndex) -> ", terminator: "")
                        moveToNextWindow()
                        Logger.log("\(currentWindowIndex)")
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
                Logger.log("🔴 [\(source)] ESC key detected, closing CT2 switcher")
                hideAppSwitcherAsync()
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
    
    private func hideSwitcherAsync() {
        guard isShowingSwitcher else { return }
        
        Logger.log("🚀 Async DS2 switcher hiding started")
        
        isShowingSwitcher = false
        switcherWindow?.orderOut(nil)
        
        switcherWindow?.contentView = NSView()
        
        stopModifierKeyWatchdog()
        
        stopNumberKeyGlobalIntercept()
        
        cleanupEventMonitors()
        
        hotkeyManager?.reEnableHotkey()
        
        DispatchQueue.global(qos: .utility).async {
            AppIconCache.shared.clearCache()
        }
        
        if currentWindowIndex < windows.count {
            let targetWindow = windows[currentWindowIndex]
            Logger.log("🎯 Preparing async window activation: \(targetWindow.title)")
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.activateWindowAsync(targetWindow)
            }
        }
        
        Logger.log("🚀 DS2 switcher UI hidden, window activation in progress asynchronously")
    }
    
    private func hideAppSwitcherAsync() {
        guard isShowingAppSwitcher else { return }
        
        Logger.log("🚀 Async CT2 switcher hiding started")
        
        isShowingAppSwitcher = false
        switcherWindow?.orderOut(nil)
        
        switcherWindow?.contentView = NSView()
        
        stopModifierKeyWatchdog()
        
        stopNumberKeyGlobalIntercept()
        
        cleanupEventMonitors()
        
        hotkeyManager?.reEnableHotkey()
        
        hotkeyManager?.resetCT2SwitcherState()
        
        DispatchQueue.global(qos: .utility).async {
            AppIconCache.shared.clearCache()
        }
        
        if currentAppIndex < apps.count, let firstWindow = apps[currentAppIndex].firstWindow {
            Logger.log("🎯 Preparing async application activation: \(apps[currentAppIndex].appName)")
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.activateWindowAsync(firstWindow)
            }
        }
        
        Logger.log("🚀 CT2 switcher UI hidden, application activation in progress asynchronously")
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
        
        if let axElement = getCachedAXElement(
            windowID: window.windowID,
            processID: window.processID, 
            windowIndex: window.axWindowIndex
        ) {
            let raiseResult = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
            Logger.log("   ⚡ AX activation result: \(raiseResult == .success ? "successful" : "failed")")
            
            if raiseResult == .success {
                AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                Logger.log("   ✅ Window activation completed")
                return
            }
        }
        
        Logger.log("   ⚠️ AX method failed, using fallback solution")
        fallbackActivateAsync(window)
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
    
    func getWindowTitlesForBundleId(_ bundleId: String) -> [String] {
        Logger.log("🔍 Getting window titles for bundle ID: \(bundleId)")
        
        var windowTitles: [String] = []
        
        let allApps = NSWorkspace.shared.runningApplications
        
        guard let targetApp = allApps.first(where: { $0.bundleIdentifier == bundleId }) else {
            Logger.log("❌ No running application found with bundle ID: \(bundleId)")
            return []
        }
        
        Logger.log("✅ Found application: \(targetApp.localizedName ?? "Unknown") (PID: \(targetApp.processIdentifier))")
        
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        
        for windowInfo in windowList {
            guard let processID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  processID == targetApp.processIdentifier,
                  let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat else { continue }
            
            let hasValidID = windowID > 0
            let hasValidLayer = isValidWindowLayer(layer, forBundleId: targetApp.bundleIdentifier)
            let hasReasonableSize = width > 100 && height > 100
            
            if hasValidID && hasValidLayer && hasReasonableSize && isOnScreen {
                // Log Steam application detection
                if isSteamApplication(targetApp.bundleIdentifier) {
                    Logger.log("   🎮 Steam window detected: Layer \(layer), ID \(windowID)")
                }
                
                let cgTitle = windowInfo[kCGWindowName as String] as? String ?? ""
                
                let axTitle = getAXWindowTitleForSpecificWindow(windowID: windowID, processID: processID)
                
                let finalTitle: String
                if !axTitle.isEmpty {
                    finalTitle = axTitle
                } else if !cgTitle.isEmpty {
                    finalTitle = cgTitle
                } else {
                    finalTitle = "\(targetApp.localizedName ?? "App") window"
                }
                
                if !finalTitle.isEmpty && !windowTitles.contains(finalTitle) {
                    windowTitles.append(finalTitle)
                    Logger.log("   ✅ Found window: '\(finalTitle)'")
                }
            }
        }
        
        Logger.log("📋 Total window titles found: \(windowTitles.count)")
        return windowTitles
    }
    
    private func getAXWindowTitleForSpecificWindow(windowID: CGWindowID, processID: pid_t) -> String {
        let app = AXUIElementCreateApplication(processID)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return ""
        }
        
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                return title
            }
        }
        
        return ""
    }
    
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
            let (axTitle, _) = getAXWindowInfo(windowID: windowID, processID: processID, windowIndex: currentIndex)

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
        
        let eventCallback: CGEventTapCallBack = { (proxy, type, event, refcon) in
            let windowManager = Unmanaged<WindowManager>.fromOpaque(refcon!).takeUnretainedValue()
            
            guard type == .keyDown else {
                return Unmanaged.passRetained(event)
            }
            
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            
            if let numberKey = windowManager.keyCodeToNumberKey(UInt16(keyCode)) {
                
                DispatchQueue.main.async {
                    if windowManager.isShowingSwitcher {
                        Logger.log("🔢 [Global] DS2 number key \(numberKey) intercepted")
                        windowManager.selectWindowByNumberKey(numberKey)
                    } else if windowManager.isShowingAppSwitcher {
                        Logger.log("🔢 [Global] CT2 number key \(numberKey) intercepted")
                        windowManager.selectAppByNumberKey(numberKey)
                    }
                }
                
                return nil
            }
            
            return Unmanaged.passRetained(event)
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
