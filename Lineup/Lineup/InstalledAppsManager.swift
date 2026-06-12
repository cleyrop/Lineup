//
//  InstalledAppsManager.swift
//  Lineup
//
//  Created by river on 2025-07-30.
//

import Foundation
import AppKit

struct InstalledAppInfo {
    let bundleId: String
    let name: String
    let icon: NSImage?
    let path: String
    
    init(bundleId: String, name: String, icon: NSImage? = nil, path: String) {
        self.bundleId = bundleId
        self.name = name
        self.icon = icon
        self.path = path
    }
}

class InstalledAppsManager: ObservableObject {
    @Published var installedApps: [InstalledAppInfo] = []
    @Published var isLoading = false
    
    private var loadTask: Task<Void, Never>?
    
    init() {
    }
    
    deinit {
        loadTask?.cancel()
        Logger.log("🗑️ InstalledAppsManager deallocated")
    }
    
    func loadInstalledApps() {
        guard !isLoading && installedApps.isEmpty else { return }
        
        isLoading = true
        Logger.log("📱 Starting to load installed applications...")
        
        loadTask = Task { @MainActor in
            do {
                let apps = await loadAppsInBackground()
                
                guard !Task.isCancelled else {
                    Logger.log("📱 App loading task was cancelled")
                    return
                }
                
                self.installedApps = apps
                self.isLoading = false
                Logger.log("📱 Successfully loaded \(apps.count) applications")
            } catch {
                Logger.log("❌ Failed to load applications: \(error)")
                self.isLoading = false
            }
        }
    }
    
    func cleanup() {
        loadTask?.cancel()
        installedApps.removeAll()
        Logger.log("🧹 InstalledAppsManager cleaned up")
    }
    
    private func loadAppsInBackground() async -> [InstalledAppInfo] {
        return await withTaskGroup(of: [InstalledAppInfo].self) { group in
            var allApps: [InstalledAppInfo] = []
            
            
            group.addTask {
                await self.getRunningApps()
            }
            
            group.addTask {
                await self.getAppsFromDirectories(["/Applications"])
            }
            
            group.addTask {
                await self.getAppsFromDirectories(["/System/Applications"])
            }
            
            group.addTask {
                if let userAppsPath = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first?.path {
                    return await self.getAppsFromDirectories([userAppsPath])
                }
                return []
            }
            
            for await apps in group {
                allApps.append(contentsOf: apps)
            }
            
            let uniqueApps = self.removeDuplicatesAndSort(allApps)
            return uniqueApps
        }
    }
    
    private func getRunningApps() async -> [InstalledAppInfo] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var apps: [InstalledAppInfo] = []
                
                let runningApps = NSWorkspace.shared.runningApplications
                for runningApp in runningApps {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: [])
                        return
                    }
                    
                    guard let bundleId = runningApp.bundleIdentifier,
                          let appName = runningApp.localizedName,
                          !bundleId.isEmpty,
                          runningApp.activationPolicy == .regular else {
                        continue
                    }
                    
                    let appPath = runningApp.bundleURL?.path ?? ""
                    let appIcon = runningApp.icon
                    
                    let appInfo = InstalledAppInfo(
                        bundleId: bundleId,
                        name: appName,
                        icon: appIcon,
                        path: appPath
                    )
                    apps.append(appInfo)
                }
                
                continuation.resume(returning: apps)
            }
        }
    }
    
    private func getAppsFromDirectories(_ directories: [String]) async -> [InstalledAppInfo] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var allApps: [InstalledAppInfo] = []
                
                for directory in directories {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: [])
                        return
                    }
                    
                    let apps = self.getAppsFromDirectory(directory)
                    allApps.append(contentsOf: apps)
                    
                    if Task.isCancelled {
                        continuation.resume(returning: [])
                        return
                    }
                }
                
                continuation.resume(returning: allApps)
            }
        }
    }
    
    private func getAppsFromDirectory(_ directoryPath: String) -> [InstalledAppInfo] {
        var apps: [InstalledAppInfo] = []
        
        guard FileManager.default.fileExists(atPath: directoryPath) else {
            return apps
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: directoryPath)
            
            for fileName in contents {
                guard !Task.isCancelled else { break }
                
                if fileName.hasSuffix(".app") {
                    let appPath = "\(directoryPath)/\(fileName)"
                    
                    if let appInfo = getAppInfoOptimized(from: appPath) {
                        apps.append(appInfo)
                    }
                }
            }
        } catch {
            Logger.log("⚠️ Failed to read directory \(directoryPath): \(error)")
        }
        
        return apps
    }
    
    private func getAppInfoOptimized(from appPath: String) -> InstalledAppInfo? {
        let bundleURL = URL(fileURLWithPath: appPath)
        
        guard let bundle = Bundle(url: bundleURL),
              let bundleId = bundle.bundleIdentifier else {
            return nil
        }
        
        let appName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ??
                     bundle.infoDictionary?["CFBundleDisplayName"] as? String ??
                     bundle.localizedInfoDictionary?["CFBundleName"] as? String ??
                     bundle.infoDictionary?["CFBundleName"] as? String ??
                     bundleURL.deletingPathExtension().lastPathComponent
        
        var appIcon: NSImage? = nil
        
        if shouldLoadIcon(for: bundleId) {
            appIcon = NSWorkspace.shared.icon(forFile: appPath)
        }
        
        return InstalledAppInfo(
            bundleId: bundleId,
            name: appName,
            icon: appIcon,
            path: appPath
        )
    }
    
    private func shouldLoadIcon(for bundleId: String) -> Bool {
        let commonApps = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.apple.Safari",
            "com.google.Chrome",
            "com.apple.finder",
            "com.apple.mail",
            "com.apple.notes",
            "com.apple.calculator",
            "com.apple.systempreferences",
            "com.jetbrains.intellij",
            "com.sublimetext.4",
            "com.figma.Desktop"
        ]
        
        return commonApps.contains(bundleId)
    }
    
    private func removeDuplicatesAndSort(_ apps: [InstalledAppInfo]) -> [InstalledAppInfo] {
        let uniqueApps = Dictionary(grouping: apps, by: { $0.bundleId })
            .compactMapValues { appGroup in
                return appGroup.first { $0.icon != nil } ?? appGroup.first
            }
            .values
            .sorted { app1, app2 in
                if app1.icon != nil && app2.icon == nil {
                    return true
                } else if app1.icon == nil && app2.icon != nil {
                    return false
                } else {
                    return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
                }
            }
        
        return Array(uniqueApps)
    }
    
    func searchApps(query: String) -> [InstalledAppInfo] {
        guard !query.isEmpty else { return installedApps }
        
        return installedApps.filter { app in
            app.name.localizedCaseInsensitiveContains(query) ||
            app.bundleId.localizedCaseInsensitiveContains(query)
        }
    }
    
    func loadIconIfNeeded(for app: InstalledAppInfo) -> InstalledAppInfo {
        guard app.icon == nil else { return app }
        
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        return InstalledAppInfo(
            bundleId: app.bundleId,
            name: app.name,
            icon: icon,
            path: app.path
        )
    }
}