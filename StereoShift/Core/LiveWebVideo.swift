import AVFoundation
import AudioToolbox
import CoreVideo
import Foundation
import UniformTypeIdentifiers

/// The phone publishes a session URL, never a URL for the original 2D file.
struct LiveWebVideo {
    let id = UUID()
    let sourceURL: URL
    let strength: Float
    let options: Stereo3DOptions
    let depthEstimator: DepthEstimator

    var path: String { "/live/" + id.uuidString + ".mp4" }
}

/// AVAssetWriter delivers the MP4 initialisation segment and successive media fragments
/// in playback order. The HTTP sender acknowledges bytes after the socket accepts them.
final class LiveWebEncoder: NSObject, AVAssetWriterDelegate {
    private let pipe = AsyncThrowingStream<Data, Error>.makeStream()
    private let lock = NSLock()
    private var pendingBytes = 0
    var fragments: AsyncThrowingStream<Data, Error> { pipe.stream }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType) {
        lock.withLock { pendingBytes += data.count }
        pipe.continuation.yield(data)
    }

    func didSend(_ count: Int) {
        lock.withLock { pendingBytes -= count }
    }

    func start(_ source: LiveWebVideo) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            do {
                try await self.encode(source)
                self.pipe.continuation.finish()
            } catch {
                self.pipe.continuation.finish(throwing: error)
            }
        }
    }

    private func encode(_ source: LiveWebVideo) async throws {
        let asset = AVURLAsset(url: source.sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StereoPipelineError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let (naturalSize, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard duration.seconds.isFinite, duration.seconds > 0, bounds.width > 0, bounds.height > 0 else {
            throw StereoPipelineError.mediaDecodingFailed
        }
        // Match the preview's per-eye resolution and cap the work for high-frame-rate inputs.
        let size = VideoProcessor.processingSize(for: bounds.size, maxDimension: 640)
        let frameRate = min(fps.isFinite && fps > 0 ? Double(fps) : 24, 24)
        let upright = transform.concatenating(.init(translationX: -bounds.minX, y: -bounds.minY))
        let scaled = upright.concatenating(.init(scaleX: size.width / bounds.width, y: size.height / bounds.height))
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = VideoProcessor.videoComposition(track: track, duration: duration,
            frameRate: frameRate, renderSize: size, transform: scaled)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw StereoPipelineError.readerSetupFailed }
        reader.add(videoOutput)

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self
        let width = Int(size.width) * 2
        let height = StereoFocusDots.outputHeight(width: width, height: Int(size.height), enabled: source.options.focusDotsEnabled)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000, AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalDurationKey: 1
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw StereoPipelineError.writerSetupFailed }
        writer.add(videoInput)

        var audio: (output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            guard reader.canAdd(output), writer.canAdd(input) else { throw StereoPipelineError.writerSetupFailed }
            reader.add(output)
            writer.add(input)
            audio = (output, input)
        }

        try Task.checkCancellation()
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard reader.startReading() else { throw reader.error ?? StereoPipelineError.readerSetupFailed }
        guard writer.startWriting() else { throw writer.error ?? StereoPipelineError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        // The depth model can be shared with the phone UI. Each viewer gets its own renderer and temporal history.
        let processor = VideoProcessor(depthEstimator: source.depthEstimator,
                                       renderer: StereoRenderer(depthEstimator: source.depthEstimator))
        let state = VideoProcessor.FrameState()
        let clock = ContinuousClock()
        let start = clock.now
        var nextFrameTime = 0.0
        var estimatedRenderSeconds = 0.0
        var hasRendered = false
        let frameStep = 1 / frameRate
        var videoDone = false
        var audioDone = audio == nil
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? StereoPipelineError.exportFailed }
            guard reader.status != .failed else { throw reader.error ?? StereoPipelineError.mediaDecodingFailed }
            if lock.withLock({ pendingBytes > 1_000_000 }) {
                try await Task.sleep(for: .milliseconds(30))
                continue
            }
            var advanced = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw StereoPipelineError.mediaDecodingFailed }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    // The browser may eagerly read the entire HTTP response. Stay just ahead of playback.
                    try await clock.sleep(until: start.advanced(by: .seconds(max(0, pts.seconds - 2))))
                    if pts.seconds + frameStep * 0.25 >= nextFrameTime || pts.seconds + frameStep >= duration.seconds {
                        let renderStart = ProcessInfo.processInfo.systemUptime
                        let sbs = try await processor.renderFrame(pixels, strength: source.strength, options: source.options, state: state)
                        guard adaptor.append(sbs, withPresentationTime: pts) else { throw writer.error ?? StereoPipelineError.writerAppendFailed }
                        // On slower devices, sample fewer pictures while retaining source timestamps and continuous audio.
                        // Exclude the first inference, which may pay the one-off model loading cost.
                        if hasRendered {
                            let cost = ProcessInfo.processInfo.systemUptime - renderStart
                            estimatedRenderSeconds = estimatedRenderSeconds == 0 ? cost : estimatedRenderSeconds * 0.8 + cost * 0.2
                        }
                        hasRendered = true
                        let spacing = max(frameStep, min(1.0, estimatedRenderSeconds * 1.15))
                        nextFrameTime = max(nextFrameTime, pts.seconds - frameStep * 0.75) + spacing
                    }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                advanced = true
            }
            if let audio, !audioDone, audio.input.isReadyForMoreMediaData {
                if let sample = audio.output.copyNextSampleBuffer() {
                    guard audio.input.append(sample) else { throw writer.error ?? StereoPipelineError.writerAppendFailed }
                } else {
                    audio.input.markAsFinished()
                    audioDone = true
                }
                advanced = true
            }
            if !advanced { try await Task.sleep(for: .milliseconds(4)) }
        }
        guard reader.status == .completed else { throw reader.error ?? StereoPipelineError.mediaDecodingFailed }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StereoPipelineError.exportFailed }
    }
}
