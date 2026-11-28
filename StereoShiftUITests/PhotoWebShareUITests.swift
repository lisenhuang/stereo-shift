import XCTest

final class PhotoWebShareUITests: XCTestCase {
    @MainActor
    func testChoosingPhotosRequiresAnExplicitScopeEachSession() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-AppleLanguages", "(en)", "-AppleLocale", "en_NZ"]
        app.launch()
        app.buttons["Gallery"].tap()
        app.buttons["Start Network Share"].tap()
        let start = app.buttons["confirmWebShare"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled)

        func option(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        option("iPhone Photos").tap()
        XCTAssertFalse(start.isEnabled)
        XCTAssertFalse(option("Allow Library Access").exists)
        option("Browse My Library on Quest").tap()
        let alreadyAllowed = option("Full library access").exists || option("Limited access").exists
        XCTAssertEqual(start.isEnabled, alreadyAllowed)
        app.buttons["Cancel"].tap()

        XCTAssertFalse(app.buttons["Stop Web Share"].exists)
        app.buttons["Start Network Share"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(option("Browse My Library on Quest").exists)
    }
}
