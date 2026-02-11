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

    static func loadSpatialPhotoPair(from item: PhotosPickerItem) async throws -> StereoImagePair {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw StereoPipelineError.photoPickerDataUnavailable
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

        guard
            let left = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let right = CGImageSourceCreateImageAtIndex(source, 1, nil)
        else {
            throw StereoPipelineError.spatialImagePairUnavailable
        }

        return StereoImagePair(left: left, right: right)
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
}
