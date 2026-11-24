import AVFoundation
import Combine
import CoreImage
import QuartzCore
import VideoToolbox

private enum PreviewInput {
    case video(CVPixelBuffer)
    case spatial([CMTaggedBuffer], CGAffineTransform)
}

// Only the current player frame is requested. A slow prediction never queues old frames
// or slows the source audio clock.
private actor PreviewFrameRenderer {
    func image(for input: PreviewInput, processor: VideoProcessor, strength: Float,
               options: Stereo3DOptions, state: VideoProcessor.FrameState) async throws -> CGImage {
        let frame: CVPixelBuffer
        switch input {
        case .video(let pixels):
            frame = try await processor.renderFrame(pixels, strength: strength, options: options, state: state)
        case let .spatial(buffers, transform):
            frame = try SpatialMediaConverter.previewFrame(from: buffers, transform: transform,
                                                          focusDotsEnabled: options.focusDotsEnabled)
        }
        return try PixelBufferUtilities.makeCGImage(from: frame)
    }
}

@MainActor
final class LiveVideoPreview: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = true
    @Published private(set) var errorMessage: String?

    private let player = AVPlayer()
    private let renderer = PreviewFrameRenderer()
    private var revision = 0
    private var seeking = false
    private var wantsPlayback = true

    func run(url: URL, spatial: Bool, processor: VideoProcessor, strength: Float, options: Stereo3DOptions) async {
        image = nil
        errorMessage = nil
        position = 0
        duration = 0
        wantsPlayback = true
        seeking = false
        player.isMuted = isMuted
        player.allowsExternalPlayback = false
        defer { stop() }

        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StereoPipelineError.noVideoTrack }
            let length = try await asset.load(.duration)
            guard length.seconds.isFinite, length.seconds > 0 else { throw StereoPipelineError.mediaDecodingFailed }
            let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            try Task.checkCancellation()
            duration = length.seconds
            let item = AVPlayerItem(asset: asset)
            let nextFrame = try configureOutput(for: item, track: track, spatial: spatial, duration: length,
                                                size: size, transform: transform, fps: fps)
            let ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                               object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.seeking else { return }
                    self.position = self.duration
                    self.pause()
                }
            }
            defer { NotificationCenter.default.removeObserver(ended) }
            player.replaceCurrentItem(with: item)
            if spatial, wantsPlayback { play() }
            // Hold the playback clock at the beginning during the first depth prediction.
            var seenRevision = revision
            var state = VideoProcessor.FrameState()
            var lastTimestamp = CMTime.invalid
            var needsFrame = true
            var lastFrame = ContinuousClock.now
            while !Task.isCancelled, player.currentItem === item {
                if let error = item.error ?? player.error { throw error }
                if seenRevision != revision {
                    seenRevision = revision
                    state = VideoProcessor.FrameState()
                    lastTimestamp = .invalid
                    needsFrame = true
                    lastFrame = .now
                }
                if seeking {
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let time = player.currentTime().seconds
                if time.isFinite, isPlaying {
                    position = min(duration, max(0, time))
                }
                if needsFrame || isPlaying {
                    if let (input, timestamp) = nextFrame(), !lastTimestamp.isValid || timestamp != lastTimestamp {
                        let frame = try await renderer.image(for: input, processor: processor, strength: strength,
                                                             options: options, state: state)
                        try Task.checkCancellation()
                        guard seenRevision == revision else { continue }
                        image = frame
                        lastTimestamp = timestamp
                        lastFrame = .now
                        if needsFrame, wantsPlayback { play() }
                        needsFrame = false
                    } else if lastFrame.duration(to: .now) > .seconds(15) {
                        throw spatial ? StereoPipelineError.spatialViewsUnavailable : StereoPipelineError.mediaDecodingFailed
                    }
                } else {
                    lastFrame = .now
                }
                try await Task.sleep(for: isPlaying || needsFrame ? .milliseconds(12) : .milliseconds(80))
            }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func configureOutput(for item: AVPlayerItem, track: AVAssetTrack, spatial: Bool, duration length: CMTime,
                                 size: CGSize, transform: CGAffineTransform, fps: Float) throws -> () -> (PreviewInput, CMTime)? {
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if spatial {
            guard #available(iOS 17.2, *), VTIsStereoMVHEVCDecodeSupported() else {
                throw StereoPipelineError.spatialPlaybackUnavailable
            }
            let spec = AVVideoOutputSpecification(tagCollections: [.stereoscopicForVideoOutput()])
            let output = AVPlayerVideoOutput(specification: spec)
            player.videoOutput = output
            return {
                guard let sample = output.taggedBuffers(forHostTime: CMClockGetTime(CMClockGetHostTimeClock())) else { return nil }
                return (.spatial(sample.taggedBufferGroup, transform), sample.presentationTime)
            }
        } else {
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw StereoPipelineError.mediaDecodingFailed
            }
            let target = VideoProcessor.processingSize(for: bounds.size, maxDimension: 640)
            let upright = transform.concatenating(.init(translationX: -bounds.minX, y: -bounds.minY))
            let scaled = upright.concatenating(.init(scaleX: target.width / bounds.width, y: target.height / bounds.height))
            item.videoComposition = VideoProcessor.videoComposition(track: track, duration: length,
                                                                    frameRate: fps > 0 ? Double(fps) : 30,
                                                                    renderSize: target, transform: scaled)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            item.add(output)
            return {
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                var presentation = CMTime.invalid
                guard output.hasNewPixelBuffer(forItemTime: time),
                      let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentation) else { return nil }
                return (.video(frame), presentation)
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else if position >= duration - 0.01 {
            seek(to: 0, resume: true)
        } else {
            play()
        }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        if isPlaying { ScreenAwakeManager.shared.release() }
        isPlaying = false
    }

    private func play() {
        wantsPlayback = true
        player.play()
        if !isPlaying { ScreenAwakeManager.shared.acquire() }
        isPlaying = true
    }

    func seek(to seconds: Double, resume: Bool) {
        pause()
        revision += 1
        let requestedRevision = revision
        seeking = true
        wantsPlayback = resume
        position = min(duration, max(0, seconds))
        // Seeking exactly to EOF can produce no image. Display the final video frame.
        let target = CMTime(seconds: min(position, max(0, duration - 1.0 / 600)), preferredTimescale: 600)
        Task {
            guard requestedRevision == revision else { return }
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            if requestedRevision == revision { seeking = false }
        }
    }

    func toggleSound() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func stop() {
        pause()
        revision += 1
        player.replaceCurrentItem(with: nil)
        if #available(iOS 17.2, *) { player.videoOutput = nil }
    }
}
