import XCTest

final class LiveVideoPreviewUITests: XCTestCase {
    @MainActor
    func testFreePreviewFromPhotosBeforeGenerating() throws {
        // Seed the isolated simulator using simctl addmedia with the 14-second portrait fixture.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STEREOSHIFT_PREVIEW_PHOTOS_TEST"] == "1",
                          "Requires live-preview-portrait.mp4 in the simulator Photos library")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Upgrade"].exists)
        app.buttons["Video"].tap()
        app.buttons["Pick Video"].tap()

        let clip = app.images.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                    "fourteen seconds", "14 seconds")).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 15), app.debugDescription)
        // The remote Photos picker exposes its grid thumbnail without a tappable AX action.
        let center = CGVector(dx: clip.frame.midX, dy: clip.frame.midY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()

        let preview = app.buttons["SBS Preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        if !preview.isHittable { app.swipeUp() }
        preview.tap()
        XCTAssertTrue(app.staticTexts["SBS Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 35))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "SBS Preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].exists)
        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Generate"].exists)
        XCTAssertFalse(app.buttons["Save to Photos"].exists)
    }
}
