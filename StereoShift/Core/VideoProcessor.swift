import AVFoundation
import CoreImage
import CoreVideo
import Foundation

struct VideoProcessingProgress: Sendable {
    let fractionCompleted: Double
    let processedSeconds: Double
    let totalSeconds: Double
}

final class VideoProcessor {
    private let depthEstimator: DepthEstimator
    private let renderer: StereoRenderer
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(depthEstimator: DepthEstimator, renderer: StereoRenderer) {
        self.depthEstimator = depthEstimator
        self.renderer = renderer
    }

    func processVideo(
        inputURL: URL,
        strength: Float,
        maxDurationSeconds: Double? = nil,
        progress: @escaping @Sendable (VideoProcessingProgress) -> Void
    ) async throws -> URL {
        let asset = AVAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw StereoPipelineError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let totalDurationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let effectiveDurationSeconds: Double
        if let maxDurationSeconds {
            effectiveDurationSeconds = max(0.001, min(maxDurationSeconds, totalDurationSeconds))
        } else {
            effectiveDurationSeconds = totalDurationSeconds
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let orientedSize = Self.orientedSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let processingSize = Self.processingSize(for: orientedSize, maxDimension: 720)

        let outputURL = try TempFiles.makeTemporaryFileURL(prefix: "stereoshift-video", fileExtension: "mp4")
        TempFiles.removeItemIfExists(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw StereoPipelineError.readerSetupFailed
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let outputWidth = Int(processingSize.width) * 2
        let outputHeight = Int(processingSize.height)

        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptorAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: adaptorAttributes)

        guard writer.canAdd(writerInput) else {
            throw StereoPipelineError.writerSetupFailed
        }
        writer.add(writerInput)

        do {
            guard reader.startReading() else {
                throw reader.error ?? StereoPipelineError.readerSetupFailed
            }

            guard writer.startWriting() else {
                throw writer.error ?? StereoPipelineError.writerSetupFailed
            }
            writer.startSession(atSourceTime: .zero)

            progress(VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: effectiveDurationSeconds))

            while reader.status == .reading {
                try Task.checkCancellation()

                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                    break
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let presentationSeconds = max(CMTimeGetSeconds(presentationTime), 0)
                if presentationSeconds > effectiveDurationSeconds {
                    break
                }

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw StereoPipelineError.mediaDecodingFailed
                }
                let preparedFrame = try makeUprightAndScaledBuffer(
                    from: imageBuffer,
                    transform: preferredTransform,
                    targetSize: processingSize
                )

                let depth = try await depthEstimator.predictDepth(pixelBuffer: preparedFrame)
                let stereoFrame = try renderer.makeSBS(from: preparedFrame, depth: depth, strength: strength)

                try await append(
                    pixelBuffer: stereoFrame,
                    at: presentationTime,
                    to: adaptor,
                    writerInput: writerInput,
                    writer: writer
                )

                let processedSeconds = presentationSeconds
                let fraction = max(0, min(1, processedSeconds / effectiveDurationSeconds))
                progress(VideoProcessingProgress(
                    fractionCompleted: fraction,
                    processedSeconds: processedSeconds,
                    totalSeconds: effectiveDurationSeconds
                ))
            }

            if reader.status == .failed {
                throw reader.error ?? StereoPipelineError.readerSetupFailed
            }
            if reader.status == .cancelled {
                throw StereoPipelineError.processingCancelled
            }

            writerInput.markAsFinished()
            try await finishWriting(writer)

            if writer.status != .completed {
                throw writer.error ?? StereoPipelineError.exportFailed
            }

            progress(VideoProcessingProgress(
                fractionCompleted: 1,
                processedSeconds: effectiveDurationSeconds,
                totalSeconds: effectiveDurationSeconds
            ))
            try Task.checkCancellation()
            return try await attachOriginalAudioIfAvailable(sourceURL: inputURL, processedVideoURL: outputURL)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            TempFiles.removeItemIfExists(at: outputURL)

            if error is CancellationError {
                throw StereoPipelineError.processingCancelled
            }
            throw error
        }
    }

    static func processingSize(for sourceSize: CGSize, maxDimension: Int) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: maxDimension, height: maxDimension)
        }

        let maxSide = max(sourceSize.width, sourceSize.height)
        let scale = min(1, CGFloat(maxDimension) / maxSide)
        let scaledWidth = even(max(2, Int((sourceSize.width * scale).rounded())))
        let scaledHeight = even(max(2, Int((sourceSize.height * scale).rounded())))

        return CGSize(width: scaledWidth, height: scaledHeight)
    }

    private func makeUprightAndScaledBuffer(
        from pixelBuffer: CVPixelBuffer,
        transform: CGAffineTransform,
        targetSize: CGSize
    ) throws -> CVPixelBuffer {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let transformed = sourceImage.transformed(by: transform)
        let translated = transformed.transformed(
            by: CGAffineTransform(translationX: -transformed.extent.origin.x, y: -transformed.extent.origin.y)
        )

        let sx = targetSize.width / max(translated.extent.width, 1)
        let sy = targetSize.height / max(translated.extent.height, 1)

        let scaled = translated
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(origin: .zero, size: targetSize))

        let output = try PixelBufferUtilities.makePixelBuffer(
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        ciContext.render(
            scaled,
            to: output,
            bounds: CGRect(origin: .zero, size: targetSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return output
    }

    private func append(
        pixelBuffer: CVPixelBuffer,
        at presentationTime: CMTime,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writerInput: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !writerInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw writer.error ?? StereoPipelineError.writerAppendFailed
        }
    }

    private func finishWriting(_ writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw writer.error ?? StereoPipelineError.exportFailed
        }
    }

    private func attachOriginalAudioIfAvailable(sourceURL: URL, processedVideoURL: URL) async throws -> URL {
        let sourceAsset = AVAsset(url: sourceURL)
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard let sourceAudioTrack = sourceAudioTracks.first else {
            return processedVideoURL
        }

        let processedAsset = AVAsset(url: processedVideoURL)
        let processedVideoTracks = try await processedAsset.loadTracks(withMediaType: .video)
        guard let processedVideoTrack = processedVideoTracks.first else {
            return processedVideoURL
        }

        let processedDuration = try await processedAsset.load(.duration)
        guard CMTimeCompare(processedDuration, .zero) > 0 else {
            return processedVideoURL
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StereoPipelineError.exportFailed
        }
        let videoTimeRange = CMTimeRange(start: .zero, duration: processedDuration)
        try compositionVideoTrack.insertTimeRange(videoTimeRange, of: processedVideoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await processedVideoTrack.load(.preferredTransform)

        let sourceAudioTimeRange = try await sourceAudioTrack.load(.timeRange)
        let audioDuration = CMTimeMinimum(processedDuration, sourceAudioTimeRange.duration)
        guard CMTimeCompare(audioDuration, .zero) > 0 else {
            return processedVideoURL
        }

        guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StereoPipelineError.exportFailed
        }
        let audioTimeRange = CMTimeRange(start: sourceAudioTimeRange.start, duration: audioDuration)
        try compositionAudioTrack.insertTimeRange(audioTimeRange, of: sourceAudioTrack, at: .zero)

        let muxedURL = try TempFiles.makeTemporaryFileURL(prefix: "stereoshift-video-with-audio", fileExtension: "mp4")
        TempFiles.removeItemIfExists(at: muxedURL)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StereoPipelineError.exportFailed
        }
        exportSession.outputURL = muxedURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = false

        do {
            try await export(session: exportSession)
        } catch {
            TempFiles.removeItemIfExists(at: muxedURL)
            throw error
        }

        TempFiles.removeItemIfExists(at: processedVideoURL)
        return muxedURL
    }

    private func export(session: AVAssetExportSession) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: StereoPipelineError.processingCancelled)
                    case .failed:
                        continuation.resume(throwing: session.error ?? StereoPipelineError.exportFailed)
                    default:
                        continuation.resume(throwing: StereoPipelineError.exportFailed)
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }

    private static func orientedSize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)

        if width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }

        return naturalSize
    }

    private static func even(_ value: Int) -> Int {
        if value % 2 == 0 {
            return value
        }
        return max(2, value - 1)
    }
}
