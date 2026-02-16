import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let sourceURL = received.file
            let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let destinationURL = try TempFiles.makeTemporaryFileURL(prefix: "picked-video", fileExtension: fileExtension)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return PickedVideoFile(url: destinationURL)
        }
    }
}

struct StereoImagePair {
    let left: CGImage
    let right: CGImage
}

struct PickedPhoto {
    let image: CGImage
    let embeddedDepth: CVPixelBuffer?
}

enum MediaPicker {
    static func loadPhoto(from item: PhotosPickerItem) async throws -> CGImage {
        try await loadPhotoWithEmbeddedDepth(from: item).image
    }

    static func loadPhotoWithEmbeddedDepth(from item: PhotosPickerItem) async throws -> PickedPhoto {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw StereoPipelineError.photoPickerDataUnavailable
        }

        guard let image = UIImage(data: data), let cgImage = normalizedCGImage(from: image) else {
            throw StereoPipelineError.photoDecodingFailed
        }

        let embeddedDepth = embeddedDepthClosenessMap(from: data, uiOrientation: image.imageOrientation)
        return PickedPhoto(image: cgImage, embeddedDepth: embeddedDepth)
    }

    static func loadPhoto(fromFileURL url: URL) throws -> CGImage {
        try loadPhotoWithEmbeddedDepth(fromFileURL: url).image
    }

    static func loadPhotoWithEmbeddedDepth(fromFileURL url: URL) throws -> PickedPhoto {
        let data = try withSecurityScopedAccess(to: url) {
            try Data(contentsOf: url)
        }

        guard let image = UIImage(data: data), let cgImage = normalizedCGImage(from: image) else {
            throw StereoPipelineError.photoDecodingFailed
        }

        let embeddedDepth = embeddedDepthClosenessMap(from: data, uiOrientation: image.imageOrientation)
        return PickedPhoto(image: cgImage, embeddedDepth: embeddedDepth)
    }

    static func loadVideoURL(from item: PhotosPickerItem) async throws -> URL {
        if let file = try await item.loadTransferable(type: PickedVideoFile.self) {
            return file.url
        }

        if let fallbackURL = try await item.loadTransferable(type: URL.self) {
            let extensionName = fallbackURL.pathExtension.isEmpty ? "mov" : fallbackURL.pathExtension
            let copiedURL = try TempFiles.makeTemporaryFileURL(prefix: "picked-video", fileExtension: extensionName)
            try FileManager.default.copyItem(at: fallbackURL, to: copiedURL)
            return copiedURL
        }

        throw StereoPipelineError.photoPickerDataUnavailable
    }

    static func loadVideoURL(fromFileURL url: URL) throws -> URL {
        try withSecurityScopedAccess(to: url) {
            let extensionName = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let copiedURL = try TempFiles.makeTemporaryFileURL(prefix: "picked-video", fileExtension: extensionName)
            try FileManager.default.copyItem(at: url, to: copiedURL)
            return copiedURL
        }
    }

    static func loadSpatialPhotoPair(from item: PhotosPickerItem) async throws -> StereoImagePair {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw StereoPipelineError.photoPickerDataUnavailable
        }

        return try decodeSpatialPair(from: data)
    }

    static func loadSpatialPhotoPair(fromFileURL url: URL) throws -> StereoImagePair {
        let data = try withSecurityScopedAccess(to: url) {
            try Data(contentsOf: url)
        }

        return try decodeSpatialPair(from: data)
    }

    private static func decodeSpatialPair(from data: Data) throws -> StereoImagePair {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw StereoPipelineError.photoDecodingFailed
        }

        let imageCount = CGImageSourceGetCount(source)
        guard imageCount >= 2 else {
            throw StereoPipelineError.spatialImagePairUnavailable
        }

        let (leftIndex, rightIndex) = spatialStereoIndices(from: source, imageCount: imageCount)

        guard
            let left = CGImageSourceCreateImageAtIndex(source, leftIndex, nil),
            let right = CGImageSourceCreateImageAtIndex(source, rightIndex, nil)
        else {
            throw StereoPipelineError.spatialImagePairUnavailable
        }

        return StereoImagePair(left: left, right: right)
    }

    private static func spatialStereoIndices(from source: CGImageSource, imageCount: Int) -> (left: Int, right: Int) {
        let defaultPair = (left: 0, right: 1)

        if
            let allProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let groupEntries = allProperties[kCGImagePropertyGroups] as? [[CFString: Any]]
        {
            for group in groupEntries {
                guard let groupType = group[kCGImagePropertyGroupType] as? String else {
                    continue
                }
                guard groupType == (kCGImagePropertyGroupTypeStereoPair as String) else {
                    continue
                }

                if
                    let leftIndexNumber = group[kCGImagePropertyGroupImageIndexLeft] as? NSNumber,
                    let rightIndexNumber = group[kCGImagePropertyGroupImageIndexRight] as? NSNumber
                {
                    let leftIndex = leftIndexNumber.intValue
                    let rightIndex = rightIndexNumber.intValue
                    if isValidStereoIndexPair(left: leftIndex, right: rightIndex, imageCount: imageCount) {
                        return (left: leftIndex, right: rightIndex)
                    }
                }
            }
        }

        var leftByFlag: Int?
        var rightByFlag: Int?

        for index in 0..<imageCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                continue
            }

            let isLeft = boolValue(from: properties[kCGImagePropertyGroupImageIsLeftImage])
            let isRight = boolValue(from: properties[kCGImagePropertyGroupImageIsRightImage])

            if isLeft, leftByFlag == nil {
                leftByFlag = index
            }
            if isRight, rightByFlag == nil {
                rightByFlag = index
            }

            if let leftByFlag, let rightByFlag,
               isValidStereoIndexPair(left: leftByFlag, right: rightByFlag, imageCount: imageCount) {
                return (left: leftByFlag, right: rightByFlag)
            }
        }

        return defaultPair
    }

    private static func isValidStereoIndexPair(left: Int, right: Int, imageCount: Int) -> Bool {
        guard left >= 0, right >= 0 else {
            return false
        }
        guard left < imageCount, right < imageCount else {
            return false
        }
        return left != right
    }

    private static func boolValue(from value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        return normalized.cgImage
    }

    private static func embeddedDepthClosenessMap(from data: Data, uiOrientation: UIImage.Orientation) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let orientation = cgImageOrientation(from: uiOrientation)

        let candidates: [(type: CFString, invert: Bool, targetType: OSType)] = [
            (kCGImageAuxiliaryDataTypeDisparity, false, kCVPixelFormatType_DisparityFloat32),
            (kCGImageAuxiliaryDataTypeDepth, true, kCVPixelFormatType_DepthFloat32)
        ]

        for candidate in candidates {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, candidate.type) as? [AnyHashable: Any] else {
                continue
            }

            guard let depthData = try? AVDepthData(fromDictionaryRepresentation: info) else {
                continue
            }

            let orientedDepth = depthData.applyingExifOrientation(orientation)
            let converted: AVDepthData
            do {
                converted = try orientedDepth.converting(toDepthDataType: candidate.targetType)
            } catch {
                continue
            }

            guard let normalized = try? normalizeDepthMapToOneComponent8(converted.depthDataMap, invert: candidate.invert) else {
                continue
            }
            return normalized
        }

        return nil
    }

    private static func normalizeDepthMapToOneComponent8(_ depthMap: CVPixelBuffer, invert: Bool) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let format = CVPixelBufferGetPixelFormatType(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        var values = [Float](repeating: 0, count: width * height)
        var valid = [Float]()
        valid.reserveCapacity(width * height)

        func addValue(_ raw: Float, at index: Int) {
            let value = raw.isFinite ? raw : 0
            values[index] = value
            if value > 0 {
                valid.append(value)
            }
        }

        switch format {
        case kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16:
            let stride = bytesPerRow / MemoryLayout<UInt16>.stride
            let pointer = baseAddress.bindMemory(to: UInt16.self, capacity: stride * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * stride)
                for x in 0..<width {
                    let bits = row[x]
                    let value = Float(Float16(bitPattern: bits))
                    addValue(value, at: (y * width) + x)
                }
            }
        case kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DepthFloat32:
            let stride = bytesPerRow / MemoryLayout<Float>.stride
            let pointer = baseAddress.bindMemory(to: Float.self, capacity: stride * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * stride)
                for x in 0..<width {
                    addValue(row[x], at: (y * width) + x)
                }
            }
        case kCVPixelFormatType_OneComponent16:
            let stride = bytesPerRow / MemoryLayout<UInt16>.stride
            let pointer = baseAddress.bindMemory(to: UInt16.self, capacity: stride * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * stride)
                for x in 0..<width {
                    addValue(Float(row[x]) / 65535, at: (y * width) + x)
                }
            }
        case kCVPixelFormatType_OneComponent8:
            let stride = bytesPerRow / MemoryLayout<UInt8>.stride
            let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: stride * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * stride)
                for x in 0..<width {
                    addValue(Float(row[x]) / 255, at: (y * width) + x)
                }
            }
        default:
            throw StereoPipelineError.unsupportedPixelFormat
        }

        guard valid.count >= 64 else {
            throw StereoPipelineError.embeddedDepthUnavailable
        }

        valid.sort()
        let lowIndex = max(0, min(valid.count - 1, Int((Double(valid.count) * 0.02).rounded(.down))))
        let highIndex = max(lowIndex, min(valid.count - 1, Int((Double(valid.count) * 0.98).rounded(.down))))
        let low = valid[lowIndex]
        let high = valid[highIndex]
        let range = max(high - low, 0.000001)

        let output = try PixelBufferUtilities.makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_OneComponent8)

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        guard let outputBase = CVPixelBufferGetBaseAddress(output) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let outputBPR = CVPixelBufferGetBytesPerRow(output)
        let outputPtr = outputBase.bindMemory(to: UInt8.self, capacity: outputBPR * height)

        for y in 0..<height {
            let outRow = outputPtr.advanced(by: y * outputBPR)
            for x in 0..<width {
                let value = values[(y * width) + x]
                if !value.isFinite || value <= 0 {
                    outRow[x] = 0
                    continue
                }

                let clipped = max(low, min(high, value))
                var t = (clipped - low) / range
                if invert {
                    t = 1 - t
                }
                outRow[x] = UInt8(max(0, min(255, Int((t * 255).rounded()))))
            }
        }

        return output
    }

    private static func cgImageOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .upMirrored:
            return .upMirrored
        case .downMirrored:
            return .downMirrored
        case .leftMirrored:
            return .leftMirrored
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }

    private static func withSecurityScopedAccess<T>(to url: URL, work: () throws -> T) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
