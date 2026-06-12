//
//  AppRelauncher.swift
//  Lineup
//
//  Relaunch the app without a shell or temp script — no path interpolation, no
//  predictable-temp-file TOCTOU surface (important for an Accessibility-trusted,
//  notarized app).
//

import AppKit

/// Launch a fresh instance of this app, then terminate the current one.
func relaunchApp() {
    let bundleURL = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
        if let error = error {
            Logger.log("❌ Relaunch failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
