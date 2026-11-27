import UIKit
import WebKit
import XCTest
@testable import StereoShift

final class GalleryQuickTunnelTests: XCTestCase {
    func testViewerLinkRequiresCloudflareHTTPSHostname() {
        let host = "four-random-test-words.trycloudflare.com"
        XCTAssertNotNil(GalleryQuickTunnel.viewerURL("https://\(host)"))
        for input in ["http://\(host)", "https://user@\(host)", "https://\(host):444", "https://\(host)/?code=1234",
                      "https://\(host)/other", "https://trycloudflare.com", "https://bad.sub.trycloudflare.com",
                      "https://\(host).example.com"] {
            XCTAssertNil(GalleryQuickTunnel.viewerURL(input))
        }
    }

    func testFileCursorIsBoundedAndSeeksToOffset() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let size = GalleryResponseBody.chunkSize
        let data = Data((0..<(size + 99)).map { UInt8($0 % 251) })
        try data.write(to: file)
        let cursor = try GalleryResponseBody(file: FileHandle(forReadingFrom: file), offset: 8, length: Int64(size + 12))
        XCTAssertEqual(try cursor.read(), data.subdata(in: 8..<(size + 8)))
        XCTAssertEqual(try cursor.read(), data.subdata(in: (size + 8)..<(size + 20)))
        XCTAssertEqual(cursor.remaining, 0)
    }

    @MainActor
    func testUnavailableTunnelLeavesLocalRouteAvailable() async throws {
        let server = GalleryWebServer(runTunnel: { _, _, _ in throw URLError(.cannotConnectToHost) }, localAddress: { "127.0.0.1" })
        server.start()
        defer { server.stop() }
        try await waitUntil { server.publicLink == .unavailable && server.hostAddress != nil }
        XCTAssertTrue(server.isRunning)
        server.retryPublicLink()
        XCTAssertEqual(server.publicLink, .connecting)
        try await waitUntil { server.publicLink == .unavailable }
        XCTAssertEqual(server.hostAddress, "127.0.0.1")
    }

    @MainActor
    func testForegroundRebindsBothListenersAtTheSameIP() async throws {
        let server = GalleryWebServer(runTunnel: { _, _, _ in throw URLError(.cannotConnectToHost) },
                                      localAddress: { "127.0.0.1" })
        server.start()
        defer { server.stop() }
        try await waitUntil { server.hostAddress == "127.0.0.1" }
        let pin = server.accessPIN
        server.restoreLocalSharingAfterBackground()
        // Only advertise the old IP again after both replacement listeners report ready.
        XCTAssertNil(server.hostAddress)
        try await waitUntil { server.hostAddress == "127.0.0.1" }
        XCTAssertEqual(server.accessPIN, pin)
    }

    @MainActor
    func testDelayedHotspotAddressAfterUnlock() async throws {
        var address: String?
        let server = GalleryWebServer(runTunnel: { _, _, _ in throw URLError(.cannotConnectToHost) },
                                      localAddress: { address })
        server.start()
        server.restoreLocalSharingAfterBackground()
        XCTAssertNil(server.hostAddress)
        // Simulate a hotspot address becoming available without a default-path change.
        try await Task.sleep(for: .milliseconds(250))
        address = "127.0.0.1"
        try await waitUntil(seconds: 5) { server.hostAddress == address }
        server.stop()
        server.restoreLocalSharingAfterBackground()
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.hostAddress)
    }

    // Run via QuickTunnel/test/ios-simulator.sh with a disposable gallery and local TLS trust.
    @MainActor
    func testBrowserGalleryAcrossBothRoutes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STEREOSHIFT_LIVE_TUNNEL_TEST"] == "1", "Requires an isolated simulator and live Cloudflare access")
        var address: String? = "127.0.0.1"
        let server = GalleryWebServer(localAddress: { address })
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "web-share-seek", withExtension: "mp4"))
        let directory = try AppGalleryLibrary.galleryDirectory()
        let photoURL = directory.appendingPathComponent("photo-\(UUID()).jpg")
        let videoURL = directory.appendingPathComponent("video-\(UUID()).mp4")
        defer {
            server.stop()
            for file in [photoURL, videoURL] {
                try? FileManager.default.removeItem(at: file)
                if let thumb = AppGalleryLibrary.existingThumbnailURL(for: file) { try? FileManager.default.removeItem(at: thumb) }
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 80), format: format).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 80))
        }
        try jpeg.write(to: photoURL)
        let thumbnailURL = try AppGalleryLibrary.thumbnailURL(forMediaFilename: photoURL.lastPathComponent)
        try jpeg.prefix(12).write(to: thumbnailURL)
        try FileManager.default.copyItem(at: movie, to: videoURL)
        server.start()
        try await waitUntil(seconds: 160) { server.publicLink.url != nil && server.hostAddress != nil }
        let viewer = try XCTUnwrap(server.publicLink.url)
        let local = URL(string: "https://localhost/")!
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        // DNS for a newly allocated Quick Tunnel can take a few seconds to propagate.
        try await waitUntil {
            guard let (data, _) = try? await client.data(from: viewer) else { return false }
            return String(decoding: data, as: UTF8.self).contains("Enter the 4-digit PIN")
        }
        for base in [local, viewer] {
            let (locked, _) = try await client.data(from: base)
            XCTAssertTrue(String(decoding: locked, as: UTF8.self).contains("Enter the 4-digit PIN"))
            let (privateFile, _) = try await client.data(from: base.appendingPathComponent("media/" + videoURL.lastPathComponent))
            XCTAssertTrue(String(decoding: privateFile, as: UTF8.self).contains("Enter the 4-digit PIN"))
        }
        _ = try await client.data(from: URL(string: "session-auth?pin=" + server.accessPIN, relativeTo: local)!)
        var pin = URLRequest(url: viewer.appendingPathComponent("session-auth"))
        pin.httpMethod = "POST"
        pin.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let wrongPIN = server.accessPIN == "0000" ? "0001" : "0000"
        pin.httpBody = Data(("pin=" + wrongPIN).utf8)
        let (rejected, _) = try await client.data(for: pin)
        XCTAssertTrue(String(decoding: rejected, as: UTF8.self).contains("Incorrect PIN"))
        pin.httpBody = Data(("pin=" + server.accessPIN).utf8)
        _ = try await client.data(for: pin)
        let (lan, _) = try await client.data(from: local.appendingPathComponent("api/items"))
        let (remote, _) = try await client.data(from: viewer.appendingPathComponent("api/items"))
        let lanJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: lan) as? NSDictionary)
        XCTAssertEqual(lanJSON, try JSONSerialization.jsonObject(with: remote) as? NSDictionary)
        let list = try XCTUnwrap(lanJSON["items"] as? [[String: Any]])
        XCTAssertTrue(list.contains { ($0["id"] as? String) == photoURL.lastPathComponent })
        XCTAssertTrue(list.contains { ($0["id"] as? String) == videoURL.lastPathComponent })
        let bytes = try Data(contentsOf: movie)
        for base in [local, viewer] {
            let (photo, _) = try await client.data(from: base.appendingPathComponent("media/" + photoURL.lastPathComponent))
            XCTAssertEqual(photo, jpeg)
            var seek = URLRequest(url: base.appendingPathComponent("media/" + videoURL.lastPathComponent))
            seek.setValue("bytes=32768-40959", forHTTPHeaderField: "Range")
            let (part, reply) = try await client.data(for: seek)
            XCTAssertEqual((reply as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual((reply as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 32768-40959/\(bytes.count)")
            XCTAssertEqual(part, bytes.subdata(in: 32768..<40960))
            seek.httpMethod = "HEAD"
            let (empty, head) = try await client.data(for: seek)
            XCTAssertTrue(empty.isEmpty)
            XCTAssertEqual((head as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(head.expectedContentLength, 8192)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 600), configuration: config)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        window.addSubview(web)
        defer { web.removeFromSuperview() }
        web.load(URLRequest(url: viewer))
        try await waitUntil { (try? await web.evaluateJavaScript("!!document.querySelector('#pin')") as? Bool) == true }
        _ = try await web.callAsyncJavaScript("document.querySelector('#pin').value = pin; document.querySelector('form').requestSubmit()",
                                              arguments: ["pin": server.accessPIN], in: nil, contentWorld: .page)
        try await waitUntil {
            if !web.isLoading, web.url?.path == "/session-auth",
               let message = try? await web.evaluateJavaScript("document.body.innerText") as? String {
                throw NSError(domain: "WebShareBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: String(message.prefix(150))])
            }
            return (try? await web.evaluateJavaScript("document.querySelectorAll('#grid .card').length") as? Int) == list.count
        }
        try await waitUntil {
            let decoded = try await web.callAsyncJavaScript("""
                const card = [...document.querySelectorAll('#grid .card')].find(card => card.querySelector('.name').textContent === photoID);
                const thumbnail = card?.querySelector('img');
                return thumbnail?.complete && thumbnail.naturalWidth === 48 && thumbnail.naturalHeight === 80;
                """, arguments: ["photoID": photoURL.lastPathComponent], in: nil, contentWorld: .page)
            return decoded as? Bool == true
        }
        XCTAssertNotNil(UIImage(contentsOfFile: thumbnailURL.path))
        let played = try await web.callAsyncJavaScript("""
            const cards = [...document.querySelectorAll('#grid .card')];
            const open = id => cards.find(card => card.querySelector('.name').textContent === id).click();
            open(photoID);
            const photo = document.querySelector('#viewerBody img');
            await photo.decode();
            document.querySelector('#closeButton').click();
            open(videoID);
            const video = document.querySelector('#viewerBody video');
            video.muted = true;
            return await new Promise((resolve, reject) => {
              const events = [];
              for (const key of ['loadedmetadata','loadeddata','canplay','playing','seeking','seeked','stalled','waiting']) {
                video.addEventListener(key, () => events.push(key));
              }
              const timer = setTimeout(() => reject(new Error('Playback timed out: ' +
                [video.readyState, video.networkState, video.currentTime, video.duration, video.paused, ...events].join(' '))), 30000);
              let sought = false;
              video.onerror = () => reject(new Error('Media error ' + video.error.code));
              video.addEventListener('playing', () => { video.currentTime = 5; }, {once: true});
              video.onseeked = () => { sought = true; };
              video.ontimeupdate = () => {
                if (sought && video.currentTime > 5.2 && !video.paused) {
                  clearTimeout(timer); video.pause();
                  resolve(photo.naturalHeight === 80 && video.videoWidth === 160);
                }
              };
              video.play().catch(reject);
            });
            """, arguments: ["photoID": photoURL.lastPathComponent, "videoID": videoURL.lastPathComponent], in: nil, contentWorld: .page)
        XCTAssertEqual(played as? Bool, true)

        address = nil
        server.refreshNetworkStatus()
        XCTAssertNil(server.hostAddress)
        XCTAssertEqual(server.publicLink.url, viewer)
        let (cellularOnly, _) = try await client.data(from: viewer.appendingPathComponent("media/" + photoURL.lastPathComponent))
        XCTAssertEqual(cellularOnly, jpeg)
        server.stop()
        try await waitUntil { try await Self.linkHasEnded(viewer.appendingPathComponent("media/" + videoURL.lastPathComponent), client: client) }
        server.start()
        try await waitUntil(seconds: 160) { server.publicLink.url != nil }
        XCTAssertNil(server.hostAddress)
        let nextViewer = try XCTUnwrap(server.publicLink.url)
        XCTAssertNotEqual(nextViewer, viewer)
        let (nextPage, _) = try await client.data(from: nextViewer)
        XCTAssertTrue(String(decoding: nextPage, as: UTF8.self).contains("Enter the 4-digit PIN"))
        let oldLinkEnded = try await Self.linkHasEnded(viewer, client: client)
        XCTAssertTrue(oldLinkEnded)
    }

    private static func linkHasEnded(_ url: URL, client: URLSession) async throws -> Bool {
        do {
            let (_, response) = try await client.data(from: url)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) >= 400
        } catch let error as URLError where [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(error.code) {
            return true
        }
    }

    @MainActor
    private func waitUntil(seconds: Int = 60, file: StaticString = #filePath, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for Web Share", file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
