//
//  AppRelauncher.swift
//  Lineup
//
//  Relaunch the app without a shell or temp script — no path interpolation, no
//  predictable-temp-file TOCTOU surface (important for an Accessibility-trusted,
//  notarized app).
//

import AppKit

/// Launch argument the relaunched instance checks to reopen Preferences.
let reopenPreferencesLaunchArgument = "--reopen-preferences"

/// Launch a fresh instance of this app, then terminate the current one. Every
/// restart we trigger is from a settings/permissions context, so by default the
/// new instance reopens the configuration window (passed as a launch argument so
/// there's no persistent flag to leak if the app dies mid-relaunch).
func relaunchApp(reopenPreferences: Bool = true) {
    let bundleURL = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    if reopenPreferences {
        config.arguments = [reopenPreferencesLaunchArgument]
    }
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
