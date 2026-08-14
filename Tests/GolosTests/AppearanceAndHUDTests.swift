import XCTest
import SwiftUI
import AppKit
@testable import Golos

final class AppearanceAndHUDTests: XCTestCase {
    func testNewSettingsUseDarkAppearance() {
        XCTAssertEqual(Settings().appearance, .dark)
    }

    func testAppearanceSurvivesJSONRoundTrip() throws {
        let settings = Settings()
        settings.appearance = .system

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(decoded.appearance, .system)
        XCTAssertNil(decoded.appearance.colorScheme)
    }

    @MainActor
    func testHUDHostingViewIsActuallyTransparent() {
        let hosting = TransparentHostingView(rootView: Color.clear)

        XCTAssertFalse(hosting.isOpaque)
        XCTAssertFalse(hosting.layer?.isOpaque ?? true)
        XCTAssertEqual(hosting.layer?.backgroundColor, NSColor.clear.cgColor)
    }
}
