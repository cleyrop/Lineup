//
//  ModelTests.swift
//  LineupTests
//
//  Pure-logic tests for the value types: hotkey-to-keycode mappings, the
//  display-name tables, and WindowInfo/AppInfo defaults.
//

import XCTest
import Carbon
@testable import Lineup

final class ModelTests: XCTestCase {

    // MARK: - Modifier keys

    func testModifierCarbonMapping() {
        XCTAssertEqual(ModifierKey.command.carbonModifier, UInt32(cmdKey))
        XCTAssertEqual(ModifierKey.option.carbonModifier, UInt32(optionKey))
        XCTAssertEqual(ModifierKey.control.carbonModifier, UInt32(controlKey))
        XCTAssertEqual(ModifierKey.function.carbonModifier, UInt32(kEventKeyModifierFnMask))
    }

    func testModifierEventFlags() {
        XCTAssertTrue(ModifierKey.command.eventModifier.contains(.command))
        XCTAssertTrue(ModifierKey.option.eventModifier.contains(.option))
        XCTAssertTrue(ModifierKey.control.eventModifier.contains(.control))
    }

    func testAllModifiersHaveDisplayNames() {
        for key in ModifierKey.allCases {
            XCTAssertFalse(key.displayName.isEmpty, "\(key) has no display name")
        }
    }

    // MARK: - Trigger keys

    func testTriggerKeyCodes() {
        XCTAssertEqual(TriggerKey.grave.keyCode, UInt32(kVK_ANSI_Grave))
        XCTAssertEqual(TriggerKey.tab.keyCode, UInt32(kVK_Tab))
        XCTAssertEqual(TriggerKey.space.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(TriggerKey.semicolon.keyCode, UInt32(kVK_ANSI_Semicolon))
    }

    func testAllTriggersHaveDistinctKeyCodes() {
        let codes = TriggerKey.allCases.map { $0.keyCode }
        XCTAssertEqual(codes.count, Set(codes).count, "Trigger key codes must be unique")
    }

    func testAllTriggersHaveDisplayNames() {
        for key in TriggerKey.allCases {
            XCTAssertFalse(key.displayName.isEmpty, "\(key) has no display name")
        }
    }

    // MARK: - Other enums

    func testTitleStrategyDisplayNames() {
        for strategy in TitleExtractionStrategy.allCases {
            XCTAssertFalse(strategy.displayName.isEmpty)
        }
    }

    func testLanguageHasOnlySystemAndEnglish() {
        XCTAssertEqual(Set(AppLanguage.allCases), [.system, .english],
                       "Chinese should have been removed")
    }

    func testColorSchemeCount() {
        XCTAssertEqual(ColorScheme.allCases.count, 10)
    }

    // MARK: - Window / app models

    func testWindowInfoDefaults() {
        let w = WindowInfo(windowID: 1, title: "t", projectName: "p", appName: "a",
                           processID: 99, axWindowIndex: 0)
        XCTAssertFalse(w.isMinimized)
        XCTAssertFalse(w.isOnOtherSpace)
        XCTAssertEqual(w.cgWindowID, 0)
        XCTAssertNil(w.axElement)
    }

    func testAppInfoStoresCount() {
        let app = AppInfo(bundleId: "com.x", processID: 1, appName: "X",
                          windowCount: 3, isActive: true)
        XCTAssertEqual(app.windowCount, 3)
        XCTAssertTrue(app.isActive)
    }
}
