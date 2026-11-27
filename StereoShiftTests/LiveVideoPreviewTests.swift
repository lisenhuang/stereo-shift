import AVFoundation
import VideoToolbox
import XCTest
@testable import StereoShift

final class LiveVideoPreviewTests: XCTestCase {
    @MainActor
    func testFreePlaybackOfPortraitVideoBeyondTenSeconds() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-preview-portrait", withExtension: "mp4"))
        let preview = LiveVideoPreview()
        let processor = StereoPipeline().videoProcessor
        var options = Stereo3DOptions()
        options.focusDotsEnabled = true
        let task = Task {
            await preview.run(url: url, spatial: false, processor: processor, strength: 1, options: options)
        }
        defer { task.cancel() }

        try await waitFor(preview) { preview.image != nil || preview.errorMessage != nil }
        XCTAssertNil(preview.errorMessage)
        let first = try XCTUnwrap(preview.image)
        XCTAssertEqual(first.width, 192)
        XCTAssertEqual(first.height, StereoFocusDots.outputHeight(width: 192, height: 144, enabled: true))
        XCTAssertEqual(preview.duration, 14, accuracy: 0.15)
        XCTAssertTrue(preview.isMuted)
        preview.toggleSound()
        XCTAssertFalse(preview.isMuted)

        try await waitFor(preview) { preview.position > 0 && preview.image !== first }
        preview.pause()
        let pausedAt = preview.position
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(preview.position, pausedAt)
        let beforeSeek = preview.image
        preview.seek(to: 11.5, resume: false)
        try await waitFor(preview) { preview.image !== beforeSeek || preview.errorMessage != nil }
        XCTAssertNil(preview.errorMessage)
        XCTAssertFalse(preview.isPlaying)
        XCTAssertEqual(preview.position, 11.5, accuracy: 0.01)

        preview.togglePlayback()
        try await waitFor(preview) { preview.isPlaying && preview.position > 0.1 && preview.position < 2 }
        preview.pause()
        let loopPosition = preview.position
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(preview.position, loopPosition)
        XCTAssertFalse(preview.isMuted)
        task.cancel()
        await task.value
        XCTAssertFalse(preview.isPlaying)
    }

    @MainActor
    func testSpatialPlaybackDecodesBothEyesFromMultiviewVideo() async throws {
        try XCTSkipUnless(VTIsStereoMVHEVCDecodeSupported(), "This runtime has no multiview HEVC decoder")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-preview-stereo", withExtension: "mov"))
        let preview = LiveVideoPreview()
        let task = Task {
            await preview.run(url: url, spatial: true, processor: StereoPipeline().videoProcessor,
                              strength: 0.8, options: Stereo3DOptions())
        }
        defer { task.cancel() }
        try await waitFor(preview) { preview.image != nil || preview.errorMessage != nil }
        XCTAssertNil(preview.errorMessage)
        let first = try XCTUnwrap(preview.image)
        XCTAssertEqual(first.width, 256)
        XCTAssertEqual(first.height, 96)
        try await waitFor(preview) { preview.position > 0 && preview.image !== first }
    }

    @MainActor
    func testInlineAndFullscreenPlayerLoopsAndStopsOnDismissal() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "web-share-seek", withExtension: "mp4"))
        let playback = LoopingVideoPlayback()
        defer { playback.stopAndReset() }
        playback.prepare(url)
        let player = playback.player
        player.isMuted = true
        player.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while player.currentTime().seconds < 0.1 || player.currentItem == nil {
            guard ContinuousClock.now < deadline else { throw TestError.timeout }
            try await Task.sleep(for: .milliseconds(40))
        }
        let first = try XCTUnwrap(player.currentItem)
        let duration = try await first.asset.load(.duration)
        await player.seek(to: CMTime(seconds: duration.seconds - 0.5, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        while player.currentItem === first || player.currentTime().seconds < 0.1 {
            guard ContinuousClock.now < deadline else { throw TestError.timeout }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertGreaterThan(player.rate, 0)
        player.pause()
        let pausedTime = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(player.currentTime().seconds, pausedTime, accuracy: 0.05)
        playback.stopAndReset()
        XCTAssertNil(player.currentItem)
    }

    func testRegularExportStillProducesStereoFramesAndAudio() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-preview-portrait", withExtension: "mp4"))
        let output = try await StereoPipeline().videoProcessor.processVideo(inputURL: url, strength: 0.8, maxDurationSeconds: 0.4) { _ in }
        defer { TempFiles.removeItemIfExists(at: output) }
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(video.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 192, height: 144))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    func testSpatialPreviewOrdersTaggedEyesAndAppliesFocusDots() throws {
        let left = try PixelBufferUtilities.makePixelBuffer(width: 40, height: 24, pixelFormat: kCVPixelFormatType_32BGRA)
        let right = try PixelBufferUtilities.makePixelBuffer(width: 40, height: 24, pixelFormat: kCVPixelFormatType_32BGRA)
        for (buffer, value) in [(left, 40), (right, 190)] {
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), CVPixelBufferGetBytesPerRow(buffer) * 24)
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let buffers = [CMTaggedBuffer(tags: [.stereoView(.rightEye)], buffer: .pixelBuffer(right)),
                       CMTaggedBuffer(tags: [.stereoView(.leftEye)], buffer: .pixelBuffer(left))]
        let frame = try SpatialMediaConverter.previewFrame(from: buffers, transform: .identity, focusDotsEnabled: true)
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 80)
        XCTAssertEqual(CVPixelBufferGetHeight(frame), 26)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let row = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).advanced(by: CVPixelBufferGetBytesPerRow(frame) * 12)
        XCTAssertLessThan(row.load(as: UInt8.self), row.advanced(by: 40 * 4).load(as: UInt8.self))
    }

    @MainActor
    private func waitFor(_ preview: LiveVideoPreview, file: StaticString = #filePath, line: UInt = #line,
                         until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while !condition() {
            guard preview.errorMessage == nil, ContinuousClock.now < deadline else {
                XCTFail("Preview at \(preview.position)/\(preview.duration), playing \(preview.isPlaying), error \(preview.errorMessage ?? "none")",
                        file: file, line: line)
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private enum TestError: Error { case timeout }
}
