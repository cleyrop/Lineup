//
//  WindowEnumerationTests.swift
//  LineupTests
//
//  Integration ("e2e") tests for cross-Space / Dock window discovery — the
//  behaviour that regressed for Safari, where a minimized window failed to
//  appear in the switcher. These drive a real app (TextEdit) through the
//  Accessibility API, so they require the test runner to hold the Accessibility
//  permission; they skip cleanly when it isn't granted (e.g. in CI).
//

import XCTest
import AppKit
import ApplicationServices
@testable import Lineup

final class WindowEnumerationTests: XCTestCase {
    private let textEditBundleId = "com.apple.TextEdit"
    private var textEdit: NSRunningApplication?

    override func setUpWithError() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
                          "Accessibility permission is required for window-enumeration tests")
    }

    override func tearDown() {
        textEdit?.terminate()
        textEdit = nil
        super.tearDown()
    }

    /// Launch TextEdit and ensure it has at least one standard window.
    private func launchTextEditWithWindow() throws -> NSRunningApplication {
        let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEditBundleId))
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let exp = expectation(description: "TextEdit launches")
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            launched = app
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        let app = try XCTUnwrap(launched)
        textEdit = app

        // Ask TextEdit (via AppleScript) for a fresh document so a window exists.
        _ = runAppleScript("tell application \"TextEdit\" to make new document")

        // Wait until AX reports a window for the app.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        try waitUntil(timeout: 8) { Self.axWindows(of: axApp).isEmpty == false }
        return app
    }

    func testEnumerationFindsAStandardWindow() throws {
        let app = try launchTextEditWithWindow()
        let result = WindowManager().appWindows(of: app)
        XCTAssertFalse(result.isEmpty, "Expected at least one window for TextEdit")
    }

    /// The Safari-class regression: a window minimized to the Dock must still be
    /// discovered (and flagged isMinimized).
    func testMinimizedWindowIsDiscovered() throws {
        let app = try launchTextEditWithWindow()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = try XCTUnwrap(Self.axWindows(of: axApp).first)

        // Minimize it to the Dock.
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        try waitUntil(timeout: 5) { Self.isMinimized(window) }

        let result = WindowManager().appWindows(of: app)
        XCTAssertTrue(result.contains { $0.isMinimized },
                      "A minimized (Dock) window must be discovered by the enumeration")
    }

    // MARK: - Helpers

    private static func axWindows(of axApp: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
           let value = ref as? Bool { return value }
        return false
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                throw XCTSkip("Timed out waiting for AX state; environment may be headless")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }
}

/// CT2 (Command+Tab) app-list tests. These do NOT need Accessibility — the list
/// comes from NSWorkspace — so they live in their own class without the
/// permission gate.
final class AppListTests: XCTestCase {
    func testRunningAppsListExcludesSelfAndIsNonEmpty() throws {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        try XCTSkipIf(regular.count < 2, "Needs at least one other regular app running")

        let apps = WindowManager().runningRegularApps()
        XCTAssertFalse(apps.isEmpty)
        XCTAssertFalse(apps.contains { $0.bundleId == Bundle.main.bundleIdentifier },
                       "The app must not list itself in the CT2 switcher")
    }
}
