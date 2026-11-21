import XCTest

final class DebugPaidAccessUITests: XCTestCase {
    @MainActor
    func testDebugUnlockDisappearsAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-AppleLanguages", "(en)", "-AppleLocale", "en_NZ"]
        app.launch()
        let upgrade = app.buttons["Upgrade"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10))
        upgrade.tap()
        let unlock = app.buttons["debugUnlockPaidAccess"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        XCTAssertTrue(unlock.isHittable)
        unlock.tap()
        XCTAssertTrue(app.otherElements["debugPaidAccessActive"].exists || app.staticTexts["debugPaidAccessActive"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "debug-paid-access-active"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Close"].tap()
        XCTAssertFalse(upgrade.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10))
        upgrade.tap()
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["debugPaidAccessActive"].exists)
    }
}
