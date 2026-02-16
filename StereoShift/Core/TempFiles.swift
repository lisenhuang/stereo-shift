import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TempFiles {
    private static let folderName = "StereoShiftTemp"

    static func makeTemporaryFileURL(prefix: String, fileExtension: String) throws -> URL {
        let directory = try tempDirectory()
        let name = "\(prefix)-\(UUID().uuidString).\(fileExtension)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    static func writePNG(cgImage: CGImage, prefix: String) throws -> URL {
        let url = try makeTemporaryFileURL(prefix: prefix, fileExtension: "png")

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }

        return url
    }

    static func writeJPEG(cgImage: CGImage, prefix: String, quality: Float) throws -> URL {
        let url = try makeTemporaryFileURL(prefix: prefix, fileExtension: "jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }

        let clampedQuality = max(0, min(1, quality))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }

        return url
    }

    static func removeItemIfExists(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupStaleFiles(olderThan age: TimeInterval = 60 * 60 * 24) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: (try? tempDirectory()) ?? FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                removeItemIfExists(at: file)
            }
        }
    }

    private static func tempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(folderName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}
