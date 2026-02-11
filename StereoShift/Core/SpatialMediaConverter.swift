import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

enum SpatialMediaConverter {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func makeSBSImage(from pair: StereoImagePair) throws -> CGImage {
        let targetWidth = min(pair.left.width, pair.right.width)
        let targetHeight = min(pair.left.height, pair.right.height)

        let leftBuffer = try makeBuffer(from: pair.left, targetSize: CGSize(width: targetWidth, height: targetHeight))
        let rightBuffer = try makeBuffer(from: pair.right, targetSize: CGSize(width: targetWidth, height: targetHeight))
        let sbsBuffer = try makeSBSPixelBuffer(left: leftBuffer, right: rightBuffer)
        return try PixelBufferUtilities.makeCGImage(from: sbsBuffer, context: PixelBufferUtilities.sharedCIContext)
    }

    static func processSpatialVideo(
        inputURL: URL,
        progress: @escaping @Sendable (VideoProcessingProgress) -> Void
    ) async throws -> URL {
        let asset = AVAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw StereoPipelineError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let totalDurationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        let outputURL = try TempFiles.makeTemporaryFileURL(prefix: "stereoshift-spatial-video", fileExtension: "mp4")
        TempFiles.removeItemIfExists(at: outputURL)

        let leftReader = try AVAssetReader(asset: asset)
        let rightReader = try AVAssetReader(asset: asset)
        let leftOutput = makeLayerReaderOutput(track: videoTrack, layerID: 0)
        let rightOutput = makeLayerReaderOutput(track: videoTrack, layerID: 1)

        guard leftReader.canAdd(leftOutput), rightReader.canAdd(rightOutput) else {
            throw StereoPipelineError.readerSetupFailed
        }
        leftReader.add(leftOutput)
        rightReader.add(rightOutput)

        guard leftReader.startReading() else {
            throw leftReader.error ?? StereoPipelineError.readerSetupFailed
        }
        guard rightReader.startReading() else {
            throw rightReader.error ?? StereoPipelineError.readerSetupFailed
        }

        progress(VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: totalDurationSeconds))

        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var processingSize: CGSize?
        var wroteAnyFrames = false

        do {
            while leftReader.status == .reading, rightReader.status == .reading {
                try Task.checkCancellation()

                guard
                    let leftSampleBuffer = leftOutput.copyNextSampleBuffer(),
                    let rightSampleBuffer = rightOutput.copyNextSampleBuffer()
                else {
                    break
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(leftSampleBuffer)
                guard
                    let leftRawBuffer = CMSampleBufferGetImageBuffer(leftSampleBuffer),
                    let rightRawBuffer = CMSampleBufferGetImageBuffer(rightSampleBuffer)
                else {
                    throw StereoPipelineError.spatialViewsUnavailable
                }

                if processingSize == nil {
                    let rawSize = CGSize(width: CVPixelBufferGetWidth(leftRawBuffer), height: CVPixelBufferGetHeight(leftRawBuffer))
                    let oriented = orientedSize(naturalSize: rawSize, preferredTransform: preferredTransform)
                    processingSize = VideoProcessor.processingSize(for: oriented, maxDimension: 720)
                }

                guard let processingSize else {
                    throw StereoPipelineError.exportFailed
                }

                let left = try makeUprightAndScaledBuffer(from: leftRawBuffer, transform: preferredTransform, targetSize: processingSize)
                let right = try makeUprightAndScaledBuffer(from: rightRawBuffer, transform: preferredTransform, targetSize: processingSize)
                let sbsFrame = try makeSBSPixelBuffer(left: left, right: right)

                if writer == nil || writerInput == nil || adaptor == nil {
                    let outputWidth = Int(processingSize.width) * 2
                    let outputHeight = Int(processingSize.height)
                    let created = try makeWriterContext(outputURL: outputURL, width: outputWidth, height: outputHeight)
                    writer = created.writer
                    writerInput = created.input
                    adaptor = created.adaptor

                    guard let writer else {
                        throw StereoPipelineError.writerSetupFailed
                    }

                    guard writer.startWriting() else {
                        throw writer.error ?? StereoPipelineError.writerSetupFailed
                    }
                    writer.startSession(atSourceTime: presentationTime)
                }

                try await append(
                    pixelBuffer: sbsFrame,
                    at: presentationTime,
                    to: adaptor!,
                    writerInput: writerInput!,
                    writer: writer!
                )

                wroteAnyFrames = true

                let processedSeconds = max(CMTimeGetSeconds(presentationTime), 0)
                let fraction = max(0, min(1, processedSeconds / totalDurationSeconds))
                progress(VideoProcessingProgress(
                    fractionCompleted: fraction,
                    processedSeconds: processedSeconds,
                    totalSeconds: totalDurationSeconds
                ))
            }

            if leftReader.status == .failed {
                throw leftReader.error ?? StereoPipelineError.readerSetupFailed
            }
            if rightReader.status == .failed {
                throw rightReader.error ?? StereoPipelineError.readerSetupFailed
            }
            if leftReader.status == .cancelled || rightReader.status == .cancelled {
                throw StereoPipelineError.processingCancelled
            }
            guard wroteAnyFrames, let writer, let writerInput else {
                throw StereoPipelineError.spatialViewsUnavailable
            }

            writerInput.markAsFinished()
            try await finishWriting(writer)

            if writer.status != .completed {
                throw writer.error ?? StereoPipelineError.exportFailed
            }

            progress(VideoProcessingProgress(
                fractionCompleted: 1,
                processedSeconds: totalDurationSeconds,
                totalSeconds: totalDurationSeconds
            ))

            return outputURL
        } catch {
            leftReader.cancelReading()
            rightReader.cancelReading()
            writer?.cancelWriting()
            TempFiles.removeItemIfExists(at: outputURL)

            if error is CancellationError {
                throw StereoPipelineError.processingCancelled
            }
            throw error
        }
    }

    private static func makeLayerReaderOutput(track: AVAssetTrack, layerID: Int) -> AVAssetReaderTrackOutput {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            AVVideoDecompressionPropertiesKey: [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: [layerID]
            ]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        return output
    }

    private static func makeBuffer(from image: CGImage, targetSize: CGSize) throws -> CVPixelBuffer {
        let buffer = try PixelBufferUtilities.makePixelBuffer(from: image)
        return try PixelBufferUtilities.resize(
            buffer,
            to: targetSize,
            context: ciContext,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    private static func makeUprightAndScaledBuffer(
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

    private static func makeSBSPixelBuffer(left: CVPixelBuffer, right: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(left)
        let height = CVPixelBufferGetHeight(left)

        guard width == CVPixelBufferGetWidth(right), height == CVPixelBufferGetHeight(right) else {
            throw StereoPipelineError.mediaDecodingFailed
        }

        let output = try PixelBufferUtilities.makePixelBuffer(
            width: width * 2,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        CVPixelBufferLockBaseAddress(left, .readOnly)
        CVPixelBufferLockBaseAddress(right, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(right, .readOnly)
            CVPixelBufferUnlockBaseAddress(left, .readOnly)
        }

        guard
            let leftBase = CVPixelBufferGetBaseAddress(left),
            let rightBase = CVPixelBufferGetBaseAddress(right),
            let outputBase = CVPixelBufferGetBaseAddress(output)
        else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let leftStride = CVPixelBufferGetBytesPerRow(left)
        let rightStride = CVPixelBufferGetBytesPerRow(right)
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        let eyeBytesPerRow = width * 4

        for y in 0..<height {
            let leftSrc = leftBase.advanced(by: y * leftStride)
            let rightSrc = rightBase.advanced(by: y * rightStride)
            let dst = outputBase.advanced(by: y * outputStride)

            memcpy(dst, leftSrc, eyeBytesPerRow)
            memcpy(dst.advanced(by: eyeBytesPerRow), rightSrc, eyeBytesPerRow)
        }

        return output
    }

    private static func makeWriterContext(outputURL: URL, width: Int, height: Int) throws -> (
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw StereoPipelineError.writerSetupFailed
        }
        writer.add(input)

        return (writer, input, adaptor)
    }

    private static func append(
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

    private static func finishWriting(_ writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw writer.error ?? StereoPipelineError.exportFailed
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
}
