import XCTest
@testable import MEditor

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultEditorFontSizeIsPositive() {
        XCTAssertGreaterThan(AppSettings.shared.editorFontSize, 0)
    }

    func testDefaultPreviewFontSizeIsPositive() {
        XCTAssertGreaterThan(AppSettings.shared.previewFontSize, 0)
    }

    func testDefaultAutoSaveIntervalIsPositive() {
        XCTAssertGreaterThan(AppSettings.shared.autoSaveInterval, 0)
    }

    func testEditorFontSizeRoundtrip() {
        let s = AppSettings.shared
        let original = s.editorFontSize
        s.editorFontSize = 20
        XCTAssertEqual(s.editorFontSize, 20)
        s.editorFontSize = original
    }

    func testSharePortIsNonZero() {
        XCTAssertGreaterThan(AppSettings.shared.sharePort, 0)
    }

    func testAIAdvancedExpandedRoundtrip() {
        let s = AppSettings.shared
        let original = s.aiAdvancedExpanded
        s.aiAdvancedExpanded = !original
        XCTAssertEqual(s.aiAdvancedExpanded, !original)
        s.aiAdvancedExpanded = original
    }
}
