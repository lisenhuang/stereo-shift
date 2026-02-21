import Combine
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GalleryMediaType: String {
    case image
    case video

    var filePrefix: String {
        switch self {
        case .image:
            return "photo"
        case .video:
            return "video"
        }
    }
}

struct GalleryItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let thumbnailURL: URL?
    let type: GalleryMediaType
    let createdAt: Date
}

final class AppGalleryLibrary: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    private var reloadTask: Task<Void, Never>?

    private static let appGroupIdentifier = "group.com.huanglisen.StereoShift"
    private static let migrationLock = NSLock()
    private static var didAttemptLegacyGalleryMigration = false
    private static var didAttemptLegacyThumbnailMigration = false

    init() {
        reload()
    }

    deinit {
        reloadTask?.cancel()
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                (try? Self.loadItemsForWeb()) ?? []
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.items = loaded
            }
        }
    }

    func saveMedia(at sourceURL: URL, type: GalleryMediaType) async throws -> GalleryItem {
        let savedMedia = try await Task.detached(priority: .utility) {
            try Self.copyToGalleryAndCreateThumbnail(sourceURL: sourceURL, type: type)
        }.value

        let values = try? savedMedia.mediaURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        let item = GalleryItem(
            id: savedMedia.mediaURL.lastPathComponent,
            url: savedMedia.mediaURL,
            thumbnailURL: savedMedia.thumbnailURL,
            type: type,
            createdAt: createdAt
        )

        await MainActor.run {
            items.removeAll { $0.url == savedMedia.mediaURL }
            items.insert(item, at: 0)
        }

        return item
    }

    func delete(_ item: GalleryItem) async throws {
        try await Task.detached(priority: .utility) {
            try Self.deleteMedia(at: item.url)
        }.value

        await MainActor.run {
            items.removeAll { $0.id == item.id }
        }
    }

    func clearAll() async throws {
        try await Task.detached(priority: .utility) {
            try Self.deleteAllMedia()
        }.value

        await MainActor.run {
            items = []
        }
    }

    static func loadItemsForWeb() throws -> [GalleryItem] {
        let directory = try galleryDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var results: [GalleryItem] = []
        results.reserveCapacity(files.count)

        for url in files {
            guard let mediaType = mediaType(for: url) else {
                continue
            }

            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let createdAt = values?.creationDate ?? values?.contentModificationDate ?? .distantPast

            results.append(
                GalleryItem(
                    id: url.lastPathComponent,
                    url: url,
                    thumbnailURL: existingThumbnailURL(for: url),
                    type: mediaType,
                    createdAt: createdAt
                )
            )
        }

        return results.sorted { $0.createdAt > $1.createdAt }
    }

    private static func copyMediaFileToGallery(sourceURL: URL, type: GalleryMediaType) throws -> URL {
        let directory = try galleryDirectory()
        let fileExtension = normalizedFileExtension(for: sourceURL, type: type)
        let destinationURL = directory.appendingPathComponent(
            "\(type.filePrefix)-\(UUID().uuidString).\(fileExtension)",
            isDirectory: false
        )

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func deleteMedia(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        removeThumbnailIfExists(for: url)
        try FileManager.default.removeItem(at: url)
    }

    private static func deleteAllMedia() throws {
        let directory = try galleryDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in files {
            try FileManager.default.removeItem(at: url)
        }

        let thumbnailDirectory = try thumbnailsDirectory()
        let thumbnailFiles = try FileManager.default.contentsOfDirectory(
            at: thumbnailDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in thumbnailFiles {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func galleryDirectory() throws -> URL {
        let fileManager = FileManager.default
        let sharedBaseDirectory = sharedContainerURL()
        let baseDirectory: URL
        if let sharedBaseDirectory {
            baseDirectory = sharedBaseDirectory
        } else {
            baseDirectory = try legacyApplicationSupportDirectory()
        }

        let directory = baseDirectory
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent("Gallery", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // If the App Group container became available after users already saved items, move them once.
        if sharedBaseDirectory != nil {
            migrateLegacyGalleryIfNeeded(sharedGalleryDirectory: directory)
        }

        return directory
    }

    static func thumbnailsDirectory() throws -> URL {
        let fileManager = FileManager.default
        let sharedBaseDirectory = sharedContainerURL()
        let baseDirectory: URL
        if let sharedBaseDirectory {
            baseDirectory = sharedBaseDirectory
        } else {
            baseDirectory = try legacyApplicationSupportDirectory()
        }

        let directory = baseDirectory
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent("GalleryThumbnails", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if sharedBaseDirectory != nil {
            migrateLegacyThumbnailsIfNeeded(sharedThumbnailDirectory: directory)
        }

        return directory
    }

    private static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static func legacyApplicationSupportDirectory() throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let baseDirectory else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }
        return baseDirectory
    }

    private static func legacyGalleryDirectoryURL() -> URL? {
        guard let baseDirectory = try? legacyApplicationSupportDirectory() else {
            return nil
        }

        return baseDirectory
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent("Gallery", isDirectory: true)
    }

    private static func legacyThumbnailsDirectoryURL() -> URL? {
        guard let baseDirectory = try? legacyApplicationSupportDirectory() else {
            return nil
        }

        return baseDirectory
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent("GalleryThumbnails", isDirectory: true)
    }

    private static func migrateLegacyGalleryIfNeeded(sharedGalleryDirectory: URL) {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !didAttemptLegacyGalleryMigration else {
            return
        }

        didAttemptLegacyGalleryMigration = true
        guard let legacyDirectory = legacyGalleryDirectoryURL() else {
            return
        }

        migrateFiles(from: legacyDirectory, to: sharedGalleryDirectory)
    }

    private static func migrateLegacyThumbnailsIfNeeded(sharedThumbnailDirectory: URL) {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !didAttemptLegacyThumbnailMigration else {
            return
        }

        didAttemptLegacyThumbnailMigration = true
        guard let legacyDirectory = legacyThumbnailsDirectoryURL() else {
            return
        }

        migrateFiles(from: legacyDirectory, to: sharedThumbnailDirectory)
    }

    private static func migrateFiles(from legacyDirectory: URL, to sharedDirectory: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDirectory.path) else {
            return
        }

        guard let legacyFiles = try? fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for legacyFile in legacyFiles {
            let destinationURL = sharedDirectory.appendingPathComponent(legacyFile.lastPathComponent, isDirectory: false)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }

            do {
                try fileManager.moveItem(at: legacyFile, to: destinationURL)
            } catch {
                // Best-effort migration. If move fails (e.g. cross-volume), fall back to copy+delete.
                do {
                    try fileManager.copyItem(at: legacyFile, to: destinationURL)
                    try? fileManager.removeItem(at: legacyFile)
                } catch {
                    continue
                }
            }
        }
    }

    static func thumbnailURL(forMediaFilename mediaFilename: String) throws -> URL {
        let thumbnailDirectory = try thumbnailsDirectory()
        let basename = (mediaFilename as NSString).deletingPathExtension
        return thumbnailDirectory.appendingPathComponent("\(basename).jpg", isDirectory: false)
    }

    static func existingThumbnailURL(for mediaURL: URL) -> URL? {
        guard let thumbnailURL = try? thumbnailURL(forMediaFilename: mediaURL.lastPathComponent) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil
    }

    static func ensureThumbnailExists(for item: GalleryItem) -> URL? {
        if let existing = existingThumbnailURL(for: item.url) {
            return existing
        }

        return try? generateThumbnail(for: item.url, type: item.type)
    }

    private static func copyToGalleryAndCreateThumbnail(sourceURL: URL, type: GalleryMediaType) throws -> (mediaURL: URL, thumbnailURL: URL?) {
        let destinationURL = try copyMediaFileToGallery(sourceURL: sourceURL, type: type)
        let thumbnailURL = try? generateThumbnail(for: destinationURL, type: type)
        return (mediaURL: destinationURL, thumbnailURL: thumbnailURL)
    }

    private static func generateThumbnail(for mediaURL: URL, type: GalleryMediaType) throws -> URL {
        let thumbnailURL = try thumbnailURL(forMediaFilename: mediaURL.lastPathComponent)

        switch type {
        case .image:
            try generateImageThumbnail(from: mediaURL, destinationURL: thumbnailURL)
        case .video:
            try generateVideoThumbnail(from: mediaURL, destinationURL: thumbnailURL)
        }

        return thumbnailURL
    }

    private static func generateImageThumbnail(from sourceURL: URL, destinationURL: URL) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            throw StereoPipelineError.mediaDecodingFailed
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            throw StereoPipelineError.mediaDecodingFailed
        }

        try writeJPEG(image: thumbnail, to: destinationURL)
    }

    private static func generateVideoThumbnail(from sourceURL: URL, destinationURL: URL) throws {
        let asset = AVAsset(url: sourceURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 320, height: 320)

        let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
        try writeJPEG(image: cgImage, to: destinationURL)
    }

    private static func writeJPEG(image: CGImage, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let imageDestination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(imageDestination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(imageDestination) else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }
    }

    private static func removeThumbnailIfExists(for mediaURL: URL) {
        guard let thumbnailURL = try? thumbnailURL(forMediaFilename: mediaURL.lastPathComponent) else {
            return
        }
        guard FileManager.default.fileExists(atPath: thumbnailURL.path) else {
            return
        }
        try? FileManager.default.removeItem(at: thumbnailURL)
    }

    private static func normalizedFileExtension(for url: URL, type: GalleryMediaType) -> String {
        let existing = url.pathExtension.lowercased()
        if !existing.isEmpty {
            return existing
        }

        switch type {
        case .image:
            return "png"
        case .video:
            return "mp4"
        }
    }

    private static func mediaType(for url: URL) -> GalleryMediaType? {
        let fileExtension = url.pathExtension.lowercased()
        if imageExtensions.contains(fileExtension) {
            return .image
        }
        if videoExtensions.contains(fileExtension) {
            return .video
        }
        return nil
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
}
