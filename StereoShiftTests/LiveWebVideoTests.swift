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
