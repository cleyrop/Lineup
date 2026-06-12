//
//  TitleExtractionTests.swift
//  LineupTests
//
//  Pure-logic tests for the window-title -> project-name extraction strategies.
//

import XCTest
@testable import Lineup

final class TitleExtractionTests: XCTestCase {
    private let settings = SettingsManager.shared

    private func extract(_ title: String, _ strategy: TitleExtractionStrategy,
                         _ separator: String? = nil) -> String {
        settings.extractProjectName(from: title, using: strategy, customSeparator: separator)
    }

    func testBeforeFirstSeparatorWithCustomSeparator() {
        XCTAssertEqual(extract("MyProject — main.swift — Edited", .beforeFirstSeparator, " — "),
                       "MyProject")
    }

    func testAfterLastSeparatorWithCustomSeparator() {
        XCTAssertEqual(extract("Folder - Sub - readme.md", .afterLastSeparator, " - "),
                       "readme.md")
    }

    func testFirstPartUsesCommonSeparatorList() {
        XCTAssertEqual(extract("WebApp | localhost", .firstPart), "WebApp")
    }

    func testLastPartUsesCommonSeparatorList() {
        XCTAssertEqual(extract("WebApp | localhost", .lastPart), "localhost")
    }

    func testFullTitleReturnsWholeString() {
        let title = "main.swift — Lineup — Edited"
        XCTAssertEqual(extract(title, .fullTitle), title)
    }

    func testNoSeparatorReturnsOriginalTitle() {
        XCTAssertEqual(extract("Untitled", .beforeFirstSeparator, " — "), "Untitled")
    }

    func testEmptyTitleIsReturnedUnchanged() {
        XCTAssertEqual(extract("", .firstPart), "")
    }

    func testWhitespaceIsTrimmedAroundResult() {
        XCTAssertEqual(extract("  Project   -   file  ", .beforeFirstSeparator, " - "), "Project")
    }
}
