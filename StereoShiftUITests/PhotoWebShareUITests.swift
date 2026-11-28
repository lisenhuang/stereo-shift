import UIKit
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

    @MainActor
    func testGrantedPhotosLibraryServesSeededVideoThumbnail() async throws {
        guard let fingerprint = ProcessInfo.processInfo.environment["STEREOSHIFT_LAN_CERT_SHA256"] else {
            throw XCTSkip("Requires an isolated simulator with a seeded Photos library and the gallery certificate fingerprint")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-AppleLanguages", "(en)", "-AppleLocale", "en_NZ"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Gallery"].tap()
        app.buttons["Start Network Share"].tap()
        func option(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        option("iPhone Photos").tap()
        option("Browse My Library on Quest").tap()
        let access = app.buttons["Allow Library Access"]
        if access.exists {
            access.tap()
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = system.buttons.matching(NSPredicate(format:
                "label CONTAINS[c] 'full access' OR label CONTAINS[c] 'all photos' OR label == 'Allow'")).firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 15), system.debugDescription)
            allow.tap()
        }
        XCTAssertTrue(option("Full library access").waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["confirmWebShare"].tap()
        XCTAssertTrue(option("Sharing your Photos library").waitForExistence(timeout: 10))
        let qr = app.buttons["Show QR Code"]
        XCTAssertTrue(qr.waitForExistence(timeout: 15), app.debugDescription)
        qr.tap()
        let address = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'http://'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let components = try XCTUnwrap(URLComponents(string: address.label))
        let host = try XCTUnwrap(components.host)
        let pin = try XCTUnwrap(components.queryItems?.first { $0.name == "code" }?.value)
        let base = try XCTUnwrap(URL(string: "https://\(host)/"))
        let client = URLSession(configuration: .ephemeral,
                                delegate: GalleryTestTrust(host: host, fingerprint: fingerprint), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        _ = try await client.data(from: XCTUnwrap(URL(string: "session-auth?pin=" + pin, relativeTo: base)))
        let (list, _) = try await client.data(from: base.appendingPathComponent("api/items"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: list) as? [String: Any])
        XCTAssertEqual(payload["photos"] as? Bool, true)
        let movie = try XCTUnwrap((payload["items"] as? [[String: Any]])?.first { $0["type"] as? String == "video" })
        let thumbnail = try XCTUnwrap(movie["thumbnailPath"] as? String)
        let (image, response) = try await client.data(from: XCTUnwrap(URL(string: thumbnail, relativeTo: base)))
        XCTAssertEqual(response.mimeType, "image/jpeg")
        XCTAssertNotNil(UIImage(data: image))
    }
}
