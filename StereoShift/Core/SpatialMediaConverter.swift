import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

enum SpatialMediaConverter {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private static let spatialMaxDimension = 640

    private struct PreparedSpatialFrame {
        let presentationTime: CMTime
        let sbsFrame: CVPixelBuffer
        let processedSeconds: Double
    }

    private enum StereoEye {
        case left
        case right
    }

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
        do {
            return try await processSpatialVideoUsingTaggedBuffers(inputURL: inputURL, progress: progress)
        } catch {
            if error is CancellationError {
                throw StereoPipelineError.processingCancelled
            }

            if let pipelineError = error as? StereoPipelineError, case .processingCancelled = pipelineError {
                throw pipelineError
            }

            let taggedPathDescription = (error as NSError).localizedDescription

            do {
                return try await processSpatialVideoUsingLayerReaders(inputURL: inputURL, progress: progress)
            } catch {
                if error is CancellationError {
                    throw StereoPipelineError.processingCancelled
                }
                if let pipelineError = error as? StereoPipelineError, case .processingCancelled = pipelineError {
                    throw pipelineError
                }

                let layerPathDescription = (error as NSError).localizedDescription
                throw NSError(
                    domain: "SpatialMediaConverter",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Spatial conversion failed. Tagged path: \(taggedPathDescription). Layer path: \(layerPathDescription). Please choose an original spatial video."
                    ]
                )
            }
        }
    }

    private static func processSpatialVideoUsingTaggedBuffers(
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

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = makeLayerReaderOutput(track: videoTrack, layerIDs: [0, 1])
        guard reader.canAdd(readerOutput) else {
            throw StereoPipelineError.readerSetupFailed
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw reader.error ?? StereoPipelineError.readerSetupFailed
        }

        progress(VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: totalDurationSeconds))

        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var processingSize: CGSize?
        var wroteAnyFrames = false
        var processedFrameCount = 0

        do {
            while reader.status == .reading {
                try Task.checkCancellation()

                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                    break
                }

                let frame = try autoreleasepool { () throws -> PreparedSpatialFrame in
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let rawPair = try extractSpatialStereoPair(from: sampleBuffer)

                    if processingSize == nil {
                        let rawSize = CGSize(width: CVPixelBufferGetWidth(rawPair.left), height: CVPixelBufferGetHeight(rawPair.left))
                        let oriented = orientedSize(naturalSize: rawSize, preferredTransform: preferredTransform)
                        processingSize = VideoProcessor.processingSize(for: oriented, maxDimension: spatialMaxDimension)
                    }

                    guard let processingSize else {
                        throw StereoPipelineError.exportFailed
                    }

                    let left = try makeUprightAndScaledBuffer(from: rawPair.left, transform: preferredTransform, targetSize: processingSize)
                    let right = try makeUprightAndScaledBuffer(from: rawPair.right, transform: preferredTransform, targetSize: processingSize)
                    let sbsFrame = try makeSBSPixelBuffer(left: left, right: right)
                    let processedSeconds = max(CMTimeGetSeconds(presentationTime), 0)

                    return PreparedSpatialFrame(
                        presentationTime: presentationTime,
                        sbsFrame: sbsFrame,
                        processedSeconds: processedSeconds
                    )
                }

                if writer == nil || writerInput == nil || adaptor == nil {
                    guard let processingSize else {
                        throw StereoPipelineError.exportFailed
                    }
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
                    writer.startSession(atSourceTime: frame.presentationTime)
                }

                try await append(
                    pixelBuffer: frame.sbsFrame,
                    at: frame.presentationTime,
                    to: adaptor!,
                    writerInput: writerInput!,
                    writer: writer!
                )

                wroteAnyFrames = true
                processedFrameCount += 1
                if processedFrameCount % 90 == 0 {
                    ciContext.clearCaches()
                    PixelBufferUtilities.sharedCIContext.clearCaches()
                }

                let fraction = max(0, min(1, frame.processedSeconds / totalDurationSeconds))
                progress(VideoProcessingProgress(
                    fractionCompleted: fraction,
                    processedSeconds: frame.processedSeconds,
                    totalSeconds: totalDurationSeconds
                ))
            }

            if reader.status == .failed {
                throw reader.error ?? StereoPipelineError.readerSetupFailed
            }
            if reader.status == .cancelled {
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
            reader.cancelReading()
            writer?.cancelWriting()
            TempFiles.removeItemIfExists(at: outputURL)

            if error is CancellationError {
                throw StereoPipelineError.processingCancelled
            }
            throw error
        }
    }

    private static func processSpatialVideoUsingLayerReaders(
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

        guard let layerPair = try detectStereoLayerPair(asset: asset, track: videoTrack) else {
            throw StereoPipelineError.spatialViewsUnavailable
        }

        let leftReader = try AVAssetReader(asset: asset)
        let rightReader = try AVAssetReader(asset: asset)
        let leftOutput = makeLayerReaderOutput(track: videoTrack, layerIDs: [layerPair.leftLayerID])
        let rightOutput = makeLayerReaderOutput(track: videoTrack, layerIDs: [layerPair.rightLayerID])

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
        var processedFrameCount = 0

        do {
            while leftReader.status == .reading, rightReader.status == .reading {
                try Task.checkCancellation()

                guard
                    let leftSampleBuffer = leftOutput.copyNextSampleBuffer(),
                    let rightSampleBuffer = rightOutput.copyNextSampleBuffer()
                else {
                    break
                }

                let frame = try autoreleasepool { () throws -> PreparedSpatialFrame in
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
                        processingSize = VideoProcessor.processingSize(for: oriented, maxDimension: spatialMaxDimension)
                    }

                    guard let processingSize else {
                        throw StereoPipelineError.exportFailed
                    }

                    let left = try makeUprightAndScaledBuffer(from: leftRawBuffer, transform: preferredTransform, targetSize: processingSize)
                    let right = try makeUprightAndScaledBuffer(from: rightRawBuffer, transform: preferredTransform, targetSize: processingSize)
                    let sbsFrame = try makeSBSPixelBuffer(left: left, right: right)
                    let processedSeconds = max(CMTimeGetSeconds(presentationTime), 0)

                    return PreparedSpatialFrame(
                        presentationTime: presentationTime,
                        sbsFrame: sbsFrame,
                        processedSeconds: processedSeconds
                    )
                }

                if writer == nil || writerInput == nil || adaptor == nil {
                    guard let processingSize else {
                        throw StereoPipelineError.exportFailed
                    }
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
                    writer.startSession(atSourceTime: frame.presentationTime)
                }

                try await append(
                    pixelBuffer: frame.sbsFrame,
                    at: frame.presentationTime,
                    to: adaptor!,
                    writerInput: writerInput!,
                    writer: writer!
                )

                wroteAnyFrames = true
                processedFrameCount += 1
                if processedFrameCount % 90 == 0 {
                    ciContext.clearCaches()
                    PixelBufferUtilities.sharedCIContext.clearCaches()
                }

                let fraction = max(0, min(1, frame.processedSeconds / totalDurationSeconds))
                progress(VideoProcessingProgress(
                    fractionCompleted: fraction,
                    processedSeconds: frame.processedSeconds,
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

    private static func detectStereoLayerPair(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (leftLayerID: Int, rightLayerID: Int)? {
        let candidateLayerIDs = [0, 1, 2, 3]
        var discovered: [Int] = []
        var detectedLayerForEye: [StereoEye: Int] = [:]

        for layerID in candidateLayerIDs {
            let reader = try AVAssetReader(asset: asset)
            let output = makeLayerReaderOutput(track: track, layerIDs: [layerID])
            guard reader.canAdd(output) else {
                continue
            }

            reader.add(output)
            guard reader.startReading() else {
                continue
            }

            if let sampleBuffer = output.copyNextSampleBuffer() {
                discovered.append(layerID)

                if let taggedBuffers = sampleBuffer.taggedBuffers {
                    for taggedBuffer in taggedBuffers {
                        guard let eye = stereoEye(from: taggedBuffer.tags) else {
                            continue
                        }

                        if let taggedLayerID = videoLayerID(from: taggedBuffer.tags) {
                            detectedLayerForEye[eye] = taggedLayerID
                        } else {
                            detectedLayerForEye[eye] = layerID
                        }
                    }
                }

                if
                    let leftLayerID = detectedLayerForEye[.left],
                    let rightLayerID = detectedLayerForEye[.right],
                    leftLayerID != rightLayerID
                {
                    reader.cancelReading()
                    return (leftLayerID: leftLayerID, rightLayerID: rightLayerID)
                }

                if discovered.count >= 2 {
                    reader.cancelReading()
                    break
                }
            }

            reader.cancelReading()
        }

        guard discovered.count >= 2 else {
            return nil
        }

        return (leftLayerID: discovered[0], rightLayerID: discovered[1])
    }

    private static func extractSpatialStereoPair(from sampleBuffer: CMSampleBuffer) throws -> (left: CVPixelBuffer, right: CVPixelBuffer) {
        guard let taggedBuffers = sampleBuffer.taggedBuffers else {
            throw StereoPipelineError.spatialViewsUnavailable
        }

        var taggedEntries: [(pixelBuffer: CVPixelBuffer, eye: StereoEye?, isOrderReversed: Bool)] = []
        taggedEntries.reserveCapacity(2)

        for taggedBuffer in taggedBuffers {
            if let pixelBuffer = pixelBuffer(from: taggedBuffer) {
                let eye = stereoEye(from: taggedBuffer.tags)
                let isOrderReversed = hasStereoOrderReversedTag(in: taggedBuffer.tags)
                taggedEntries.append((pixelBuffer: pixelBuffer, eye: eye, isOrderReversed: isOrderReversed))
            }
        }

        guard taggedEntries.count >= 2 else {
            throw StereoPipelineError.spatialViewsUnavailable
        }

        let leftTagged = taggedEntries.first(where: { $0.eye == .left })?.pixelBuffer
        let rightTagged = taggedEntries.first(where: { $0.eye == .right })?.pixelBuffer

        if let leftTagged, let rightTagged {
            return (left: leftTagged, right: rightTagged)
        }

        if let leftTagged, rightTagged == nil {
            if let fallbackRight = taggedEntries.first(where: { $0.eye != .left })?.pixelBuffer {
                return (left: leftTagged, right: fallbackRight)
            }
        }

        if leftTagged == nil, let rightTagged {
            if let fallbackLeft = taggedEntries.first(where: { $0.eye != .right })?.pixelBuffer {
                return (left: fallbackLeft, right: rightTagged)
            }
        }

        if taggedEntries.contains(where: { $0.isOrderReversed }) {
            return (left: taggedEntries[1].pixelBuffer, right: taggedEntries[0].pixelBuffer)
        }

        return (left: taggedEntries[0].pixelBuffer, right: taggedEntries[1].pixelBuffer)
    }

    private static func stereoEye(from tags: [CMTag]) -> StereoEye? {
        for tag in tags {
            guard let components = tag.value(onlyIfMatching: CMTypedTag<CMStereoViewComponents>.Category.stereoView) else {
                continue
            }

            let hasLeft = components.contains(.leftEye)
            let hasRight = components.contains(.rightEye)

            if hasLeft, !hasRight {
                return .left
            }

            if hasRight, !hasLeft {
                return .right
            }
        }

        return nil
    }

    private static func videoLayerID(from tags: [CMTag]) -> Int? {
        for tag in tags {
            if let layerID = tag.value(onlyIfMatching: CMTypedTag<Int64>.Category.videoLayerID) {
                return Int(layerID)
            }
        }

        return nil
    }

    private static func hasStereoOrderReversedTag(in tags: [CMTag]) -> Bool {
        for tag in tags {
            guard let interpretation = tag.value(onlyIfMatching: CMTypedTag<CMStereoViewInterpretationOptions>.Category.stereoViewInterpretation) else {
                continue
            }

            if interpretation.contains(.stereoOrderReversed) {
                return true
            }
        }

        return false
    }

    private static func pixelBuffer(from taggedBuffer: CMTaggedBuffer) -> CVPixelBuffer? {
        switch taggedBuffer.buffer {
        case let .pixelBuffer(pixelBuffer):
            return pixelBuffer
        case let .sampleBuffer(sampleBuffer):
            return CMSampleBufferGetImageBuffer(sampleBuffer)
        @unknown default:
            return nil
        }
    }

    private static func makeLayerReaderOutput(track: AVAssetTrack, layerIDs: [Int]) -> AVAssetReaderTrackOutput {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            AVVideoDecompressionPropertiesKey: [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: layerIDs
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
            colorSpace: rgbColorSpace
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
            colorSpace: rgbColorSpace
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
