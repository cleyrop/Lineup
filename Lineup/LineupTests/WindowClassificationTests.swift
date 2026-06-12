//
//  WindowClassificationTests.swift
//  LineupTests
//
//  Hermetic tests for which windows the switcher keeps. These replace an older
//  integration test that launched and killed TextEdit through the Accessibility
//  API — that drove a real GUI app, needed the AX permission, was flaky, and
//  left a "TextEdit is not open anymore" dialog on every run. The behaviour that
//  actually regressed (Safari's minimized Dock window vanishing) is a pure
//  subrole decision, so it's tested directly with no live windows and no spam.
//

import XCTest
import ApplicationServices
@testable import Lineup

final class WindowClassificationTests: XCTestCase {

    func testStandardWindowIsKept() {
        XCTAssertTrue(WindowManager.acceptsWindowSubrole(kAXStandardWindowSubrole as String))
    }

    /// The Safari-class regression: Safari reports a window minimized to the Dock
    /// with subrole AXDialog. Excluding dialogs dropped every Dock window, so the
    /// switcher must accept AXDialog.
    func testDialogIsKept_SafariMinimizedRegression() {
        XCTAssertTrue(WindowManager.acceptsWindowSubrole(kAXDialogSubrole as String))
    }

    /// Some apps don't set a subrole on their main window; a missing subrole must
    /// be treated as a real window, not filtered out.
    func testMissingSubroleIsKept() {
        XCTAssertTrue(WindowManager.acceptsWindowSubrole(nil))
    }

    /// Floating palettes / system sheets etc. are not switch targets.
    func testNonWindowSubrolesAreRejected() {
        XCTAssertFalse(WindowManager.acceptsWindowSubrole(kAXFloatingWindowSubrole as String))
        XCTAssertFalse(WindowManager.acceptsWindowSubrole(kAXSystemDialogSubrole as String))
        XCTAssertFalse(WindowManager.acceptsWindowSubrole(kAXUnknownSubrole as String))
        XCTAssertFalse(WindowManager.acceptsWindowSubrole(""))
    }
}

/// CT2 (Command+Tab) app-list tests. These read the list from NSWorkspace — no
/// Accessibility permission, no launched apps — so they run anywhere.
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
