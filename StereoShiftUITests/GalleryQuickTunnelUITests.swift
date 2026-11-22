import CryptoKit
import Security
import XCTest

final class GalleryQuickTunnelUITests: XCTestCase {
    @MainActor
    func testShareSurvivesAppSwitchWithBothQRCodes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STEREOSHIFT_LIVE_TUNNEL_TEST"] == "1", "Requires an isolated simulator and live Cloudflare access")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-AppleLanguages", "(en)", "-AppleLocale", "en_NZ"]
        app.launch()
        app.buttons["Gallery"].tap()
        app.buttons["Start Network Share"].tap()
        var viewerURL: URL?
        var localQR: URLComponents?
        for (label, publicLink) in [("Show QR Code", false), ("Show public link QR code", true)] {
            let qr = app.buttons[label]
            XCTAssertTrue(qr.waitForExistence(timeout: publicLink ? 160 : 20))
            qr.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            let scheme = publicLink ? "https://" : "http://"
            let displayed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", scheme)).firstMatch
            XCTAssertTrue(displayed.waitForExistence(timeout: 5))
            let link = displayed.label
            let digest = SHA256.hash(data: Data(link.utf8)).map { String(format: "%02x", $0) }.joined()
            let capture = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
            capture.name = (publicLink ? "public" : "local") + "-qr-" + digest
            capture.lifetime = .keepAlways
            add(capture)
            let components = try XCTUnwrap(URLComponents(string: link))
            if publicLink {
                XCTAssertEqual(components.scheme, "https")
                XCTAssertTrue(components.host?.hasSuffix(".trycloudflare.com") == true)
                XCTAssertNil(components.query)
                viewerURL = components.url
            } else {
                XCTAssertEqual(components.scheme, "http")
                localQR = components
            }
            done.tap()
        }
        let viewer = try XCTUnwrap(viewerURL)
        let local = try XCTUnwrap(localQR)
        let localHost = try XCTUnwrap(local.host)
        let accessPIN = try XCTUnwrap(local.queryItems?.first { $0.name == "code" }?.value)
        let localEntry = try XCTUnwrap(URL(string: "http://\(localHost)/"))
        let localTLS = try XCTUnwrap(URL(string: "https://\(localHost)/"))
        let fingerprint = try XCTUnwrap(ProcessInfo.processInfo.environment["STEREOSHIFT_LAN_CERT_SHA256"])
        let lanClient = URLSession(configuration: .ephemeral,
                                   delegate: GalleryTestTrust(host: localHost, fingerprint: fingerprint), delegateQueue: nil)
        defer { lanClient.invalidateAndCancel() }
        let localLogin = try XCTUnwrap(URL(string: "session-auth?pin=" + accessPIN, relativeTo: localTLS))
        _ = try await lanClient.data(from: localLogin)
        let localItems = localTLS.appendingPathComponent("api/items")
        try await assertGalleryUnlocked(localItems, client: lanClient)

        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        var login = URLRequest(url: viewer.appendingPathComponent("session-auth"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = Data(("pin=" + accessPIN).utf8)
        _ = try await client.data(for: login)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.buttons["Stop Web Share"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[viewer.absoluteString].exists)
        XCTAssertTrue(app.buttons["Show QR Code"].waitForExistence(timeout: 35))
        let (entry, response) = try await lanClient.data(from: localEntry)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: entry, as: UTF8.self).contains("href=\"\(localTLS.absoluteString)\""))
        try await assertGalleryUnlocked(localItems, client: lanClient)
        try await assertGalleryUnlocked(viewer.appendingPathComponent("api/items"), client: client)

        app.buttons["Stop Web Share"].tap()
        XCTAssertTrue(app.buttons["Start Network Share"].exists)
        XCTAssertFalse(app.buttons["Show public link QR code"].exists)
    }

    private func assertGalleryUnlocked(_ url: URL, client: URLSession) async throws {
        let (data, response) = try await client.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let gallery = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(gallery["items"])
    }
}

private final class GalleryTestTrust: NSObject, URLSessionDelegate {
    let host: String
    let fingerprint: String

    init(host: String, fingerprint: String) {
        self.host = host
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == host else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02x", $0) }).joined() == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
