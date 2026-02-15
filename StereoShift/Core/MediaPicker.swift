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

enum MediaPicker {
    static func loadPhoto(from item: PhotosPickerItem) async throws -> CGImage {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw StereoPipelineError.photoPickerDataUnavailable
        }

        guard let image = UIImage(data: data), let cgImage = normalizedCGImage(from: image) else {
            throw StereoPipelineError.photoDecodingFailed
        }

        return cgImage
    }

    static func loadPhoto(fromFileURL url: URL) throws -> CGImage {
        let data = try withSecurityScopedAccess(to: url) {
            try Data(contentsOf: url)
        }

        guard let image = UIImage(data: data), let cgImage = normalizedCGImage(from: image) else {
            throw StereoPipelineError.photoDecodingFailed
        }

        return cgImage
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
