//
//  SettingsTests.swift
//  LineupTests
//
//  Verifies every user-facing setting round-trips: defaults are sane, the
//  update methods mutate state, and the model survives a Codable round-trip
//  (the path used to persist settings to UserDefaults).
//

import XCTest
@testable import Lineup

final class SettingsTests: XCTestCase {
    private let manager = SettingsManager.shared
    private var original: AppSettings!

    override func setUp() {
        super.setUp()
        original = manager.settings
    }

    override func tearDown() {
        manager.settings = original
        manager.saveSettings()
        super.tearDown()
    }

    func testDefaultsAreSane() {
        let d = AppSettings.default
        XCTAssertEqual(d.modifierKey, .command)
        XCTAssertEqual(d.triggerKey, .grave)
        XCTAssertTrue(d.ct2Enabled)
        XCTAssertTrue(d.showNumberKeys)
        XCTAssertTrue(d.switcherFollowActiveWindow)
        XCTAssertTrue(d.showWindowsFromAllSpaces, "All-Spaces should default on")
        XCTAssertEqual(d.switcherVerticalPosition, 0.39, accuracy: 0.0001)
        XCTAssertEqual(d.switcherHeaderStyle, .default)
        XCTAssertEqual(d.colorScheme, .system)
    }

    func testEachUpdateMethodMutatesState() {
        manager.updateShowNumberKeys(false)
        XCTAssertFalse(manager.settings.showNumberKeys)

        manager.updateSwitcherFollowActiveWindow(false)
        XCTAssertFalse(manager.settings.switcherFollowActiveWindow)

        manager.updateShowWindowsFromAllSpaces(false)
        XCTAssertFalse(manager.settings.showWindowsFromAllSpaces)

        manager.updateSwitcherHeaderStyle(.simplified)
        XCTAssertEqual(manager.settings.switcherHeaderStyle, .simplified)

        manager.updateColorScheme(.ocean)
        XCTAssertEqual(manager.settings.colorScheme, .ocean)

        manager.updateHotkey(modifier: .option, trigger: .tab)
        XCTAssertEqual(manager.settings.modifierKey, .option)
        XCTAssertEqual(manager.settings.triggerKey, .tab)

        manager.updateCT2Hotkey(modifier: .control, trigger: .space)
        XCTAssertEqual(manager.settings.ct2ModifierKey, .control)
        XCTAssertEqual(manager.settings.ct2TriggerKey, .space)
    }

    func testVerticalPositionIsClamped() {
        manager.updateSwitcherVerticalPosition(5.0)
        XCTAssertLessThanOrEqual(manager.settings.switcherVerticalPosition, 0.8)
        manager.updateSwitcherVerticalPosition(-1.0)
        XCTAssertGreaterThanOrEqual(manager.settings.switcherVerticalPosition, 0.1)
    }

    func testDecodingToleratesMissingKeys() throws {
        // Settings saved by an older version that predates windowDisplayStyle.
        let json = """
        { "modifierKey": "function", "triggerKey": "Space" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        // Present keys win; everything missing falls back to defaults (no throw,
        // so the user's config is never wiped when a field is added).
        XCTAssertEqual(decoded.modifierKey, .function)
        XCTAssertEqual(decoded.triggerKey, .space)
        XCTAssertEqual(decoded.windowDisplayStyle, .initials)
        XCTAssertTrue(decoded.showWindowsFromAllSpaces)
        XCTAssertEqual(decoded.colorScheme, .system)
    }

    func testLegacyShowWindowPreviewsMapsToPreview() throws {
        let json = """
        { "showWindowPreviews": true }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.windowDisplayStyle, .preview,
                       "Legacy showWindowPreviews=true should map to the Preview style")
    }

    func testCodableRoundTripPreservesAllFields() throws {
        var s = AppSettings.default
        s.showWindowsFromAllSpaces = false
        s.colorScheme = .midnight
        s.switcherVerticalPosition = 0.5
        s.ct2Enabled = false

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.showWindowsFromAllSpaces, false)
        XCTAssertEqual(decoded.colorScheme, .midnight)
        XCTAssertEqual(decoded.switcherVerticalPosition, 0.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.ct2Enabled, false)
    }
}
