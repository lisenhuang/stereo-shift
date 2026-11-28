import AVFoundation
import XCTest
@testable import StereoShift

final class LiveWebVideoTests: XCTestCase {
    func testStreamCarriesUprightStereoVideoAndAudio() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-preview-portrait", withExtension: "mp4"))
        var options = Stereo3DOptions()
        options.focusDotsEnabled = false
        let source = LiveWebVideo(sourceURL: url, strength: 0.8, options: options, depthEstimator: DepthEstimator())
        let encoder = LiveWebEncoder()
        let task = encoder.start(source)
        defer { task.cancel() }

        // Reassemble the same fragments the browser receives and inspect the actual tracks.
        var bytes = Data()
        var count = 0
        for try await fragment in encoder.fragments {
            if count == 0 { XCTAssertNotNil(fragment.range(of: Data("ftyp".utf8))) }
            bytes.append(fragment)
            encoder.didSend(fragment.count)
            count += 1
        }
        XCTAssertGreaterThan(count, 2)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try bytes.write(to: output)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 192, height: 144))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let length = try await asset.load(.duration)
        XCTAssertEqual(length.seconds, 14, accuracy: 0.3)
    }

#if DEBUG
    @MainActor
    func testAuthenticatedLiveOnlyHTTPShare() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-preview-portrait", withExtension: "mp4"))
        let source = LiveWebVideo(sourceURL: movie, strength: 0.8, options: Stereo3DOptions(), depthEstimator: DepthEstimator())
        let access = SubscriptionManager(productIDs: [], userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        access.enableDebugPaidAccessForSession()

        // Exercise the real loopback listener used by the public connector without publishing a URL.
        let listening = expectation(description: "Origin listener ready")
        var endpoint: (port: UInt16, key: String)?
        let server = GalleryWebServer(runTunnel: { port, key, _ in
            await MainActor.run {
                endpoint = (port, key)
                listening.fulfill()
            }
            try await Task.sleep(for: .seconds(180))
        }, localAddress: { nil })
        server.shareLiveVideo(source, access: access)
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 10)
        let origin = try XCTUnwrap(endpoint)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(origin.port)"))
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let client = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        var cookie: String?
        func request(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: base)))
            request.httpMethod = method
            request.setValue(origin.key, forHTTPHeaderField: "X-StereoShift-Origin")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let (data, response) = try await client.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let (_, locked) = try await request(source.path)
        XCTAssertEqual(locked.statusCode, 302)
        let (_, login) = try await request("/session-auth?pin=" + server.accessPIN)
        XCTAssertEqual(login.statusCode, 303)
        cookie = try XCTUnwrap(login.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
        let (list, _) = try await request("/api/items")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: list) as? [String: Any])
        XCTAssertEqual(payload["liveVideoPath"] as? String, source.path)
        XCTAssertEqual(payload["liveOnly"] as? Bool, true)
        XCTAssertEqual((payload["items"] as? [Any])?.count, 0)
        let (_, info) = try await request(source.path, method: "HEAD")
        XCTAssertEqual(info.mimeType, "video/mp4")
        let (bytes, response) = try await request(source.path)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(bytes.range(of: Data("ftyp".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("moof".utf8)))
        server.resetAccessPIN()
        let (_, expired) = try await request(source.path)
        XCTAssertEqual(expired.statusCode, 302)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
#endif

    @MainActor
    func testFreeAccountCannotStartLiveShare() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let access = SubscriptionManager(productIDs: [], userDefaults: defaults)
        let server = GalleryWebServer(runTunnel: { _, _, _ in }, localAddress: { nil })
        let video = LiveWebVideo(sourceURL: URL(fileURLWithPath: "/unused"), strength: 1,
                                 options: Stereo3DOptions(), depthEstimator: DepthEstimator())
        server.shareLiveVideo(video, access: access)
        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(server.isSharingLiveVideo)
#if DEBUG
        access.enableDebugPaidAccessForSession()
        server.shareLiveVideo(video, access: access)
        XCTAssertTrue(server.isRunning)
        XCTAssertTrue(server.isSharingLiveVideo)
        server.removeLiveVideo()
        XCTAssertFalse(server.isRunning)
        server.start()
        defer { server.stop() }
        server.shareLiveVideo(video, access: access)
        server.removeLiveVideo()
        XCTAssertTrue(server.isRunning)
        XCTAssertFalse(server.isSharingLiveVideo)
#endif
    }
}
