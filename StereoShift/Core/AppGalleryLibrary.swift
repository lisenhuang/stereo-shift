import Combine
import Foundation

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
    let type: GalleryMediaType
    let createdAt: Date
}

final class AppGalleryLibrary: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    private var reloadTask: Task<Void, Never>?

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
                (try? Self.loadItems()) ?? []
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.items = loaded
            }
        }
    }

    func saveMedia(at sourceURL: URL, type: GalleryMediaType) async throws -> GalleryItem {
        let destinationURL = try await Task.detached(priority: .utility) {
            try Self.copyToGallery(sourceURL: sourceURL, type: type)
        }.value

        let values = try? destinationURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        let item = GalleryItem(
            id: destinationURL.lastPathComponent,
            url: destinationURL,
            type: type,
            createdAt: createdAt
        )

        await MainActor.run {
            items.removeAll { $0.url == destinationURL }
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

    private static func loadItems() throws -> [GalleryItem] {
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
                    type: mediaType,
                    createdAt: createdAt
                )
            )
        }

        return results.sorted { $0.createdAt > $1.createdAt }
    }

    private static func copyToGallery(sourceURL: URL, type: GalleryMediaType) throws -> URL {
        let directory = try galleryDirectory()
        let fileExtension = normalizedFileExtension(for: sourceURL, type: type)
        let destinationURL = directory.appendingPathComponent(
            "\(type.filePrefix)-\(UUID().uuidString).\(fileExtension)",
            isDirectory: false
        )

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func deleteMedia(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func galleryDirectory() throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let baseDirectory else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }

        let directory = baseDirectory
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent("Gallery", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
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
