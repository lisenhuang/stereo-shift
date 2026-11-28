import AVFoundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Only the authenticated server queue reads or changes the catalogue. Media requests
/// carry the resolved asset or picker grant off that queue for iCloud and conversion.
final class PhotoWebShare {
    enum Source {
        case selected([NSItemProvider])
        case library(PHAuthorizationStatus)
    }

    enum Item {
        case picked(NSItemProvider)
        case asset(PHAsset)

        var isVideo: Bool {
            switch self {
            case .picked(let result): return result.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            case .asset(let asset): return asset.mediaType == .video
            }
        }
    }

    let source: Source
    private let depthEstimator: DepthEstimator
    private let strength: Float
    private let options: Stereo3DOptions
    private var localIDs = [UUID: String]()
    private var webIDs = [String: UUID]()
    private var selection: [(UUID, NSItemProvider)] = []
    private var pickedItems = [UUID: NSItemProvider]()

    init(source: Source, depthEstimator: DepthEstimator, strength: Float, options: Stereo3DOptions) {
        self.source = source
        self.depthEstimator = depthEstimator
        self.strength = strength
        var applied = options
        applied.depthModel = .depthAnythingV2SmallF16
        applied.renderEngine = .metal
        applied.renderProfile = .ultraFast
        self.options = applied
        if case .selected(let results) = source {
            selection = results.map { (UUID(), $0) }
            pickedItems = Dictionary(uniqueKeysWithValues: selection)
        }
    }

    static func permitsBrowsing(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    var isAvailable: Bool {
        switch source {
        case .selected: return !selection.isEmpty
        case .library(let consent):
            return Self.permitsBrowsing(consent) && PHPhotoLibrary.authorizationStatus(for: .readWrite) == consent
        }
    }

    private var fetchOptions: PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    func page(offset: Int, limit: Int, canPlayVideo: Bool) -> (items: [GalleryPayloadItem], hasMore: Bool) {
        guard isAvailable else { return ([], false) }
        let assets: PHFetchResult<PHAsset>?
        switch source {
        case .selected: assets = nil
        case .library: assets = PHAsset.fetchAssets(with: fetchOptions)
        }
        let count = assets?.count ?? selection.count
        guard offset < count else { return ([], false) }
        let end = offset + min(limit, count - offset)
        let formatter = ISO8601DateFormatter()
        let items = (offset..<end).map { index in
            let id: UUID
            let video: Bool
            let date: String
            if let asset = assets?.object(at: index) {
                let local = asset.localIdentifier
                id = webIDs[local] ?? UUID()
                webIDs[local] = id
                localIDs[id] = local
                video = asset.mediaType == .video
                date = asset.creationDate.map(formatter.string(from:)) ?? ""
            } else {
                let (key, result) = selection[index]
                id = key
                video = Item.picked(result).isVideo
                date = ""
            }
            let token = id.uuidString
            return GalleryPayloadItem(id: "\(video ? "Video" : "Photo") \(index + 1)",
                type: video ? GalleryMediaType.video.rawValue : GalleryMediaType.image.rawValue, createdAt: date, mediaPath: "/media/\(token)",
                thumbnailPath: "/thumb/\(token)", live: video, locked: video && !canPlayVideo)
        }
        return (items, end < count)
    }

    func item(_ id: UUID) -> Item? {
        guard isAvailable else { return nil }
        switch source {
        case .selected: return pickedItems[id].map(Item.picked)
        case .library:
            guard let local = localIDs[id],
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: fetchOptions).firstObject,
                  !asset.isHidden else { return nil }
            return .asset(asset)
        }
    }

    func response(for item: Item, thumbnail: Bool) async throws -> GalleryHTTPResponse {
        try Task.checkCancellation()
        if !thumbnail, item.isVideo {
            let asset: AVAsset
            var file: PhotoWebFile?
            switch item {
            case .asset(let photo):
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.version = .current
                asset = try await PhotoWebLoad<AVAsset>().get { finish in
                    let manager = PHImageManager.default()
                    let id = manager.requestAVAsset(forVideo: photo, options: options) { asset, _, info in
                        finish(asset, info?[PHImageErrorKey] as? Error)
                    }
                    return { manager.cancelImageRequest(id) }
                }
            case .picked(let result):
                let copy = try await Self.copyRepresentation(result, type: .movie)
                asset = AVURLAsset(url: copy.url)
                file = copy
            }
            return GalleryHTTPResponse(liveVideo: LiveWebVideo(asset: asset, temporaryFile: file,
                strength: strength, options: options, depthEstimator: depthEstimator))
        }

        let dimension = thumbnail ? 320 : 1280
        let image: UIImage
        switch item {
        case .asset(let asset):
            let request = PHImageRequestOptions()
            request.isNetworkAccessAllowed = true
            request.deliveryMode = .highQualityFormat
            request.resizeMode = .exact
            image = try await PhotoWebLoad<UIImage>().get { finish in
                let manager = PHImageManager.default()
                let id = manager.requestImage(for: asset, targetSize: CGSize(width: dimension, height: dimension),
                    contentMode: .aspectFit, options: request) { image, info in
                    guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                    finish(image, info?[PHImageErrorKey] as? Error)
                }
                return { manager.cancelImageRequest(id) }
            }
        case .picked(let provider):
            if thumbnail, let preview = try? await Self.preview(provider) {
                image = preview
            } else {
                try Task.checkCancellation()
                let file = try await Self.copyRepresentation(provider, type: item.isVideo ? .movie : .image)
                if item.isVideo {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: dimension, height: dimension)
                    let frame = try await generator.image(at: .zero)
                    withExtendedLifetime(file) {}
                    image = UIImage(cgImage: frame.image)
                } else {
                    guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: dimension
                          ] as CFDictionary) else { throw StereoPipelineError.photoDecodingFailed }
                    withExtendedLifetime(file) {}
                    image = UIImage(cgImage: cg)
                }
            }
        }

        try Task.checkCancellation()
        let jpeg: Data
        if thumbnail {
            guard let data = image.jpegData(compressionQuality: 0.75) else { throw StereoPipelineError.photoDecodingFailed }
            jpeg = data
        } else {
            guard let upright = MediaPicker.normalizedCGImage(from: image) else { throw StereoPipelineError.photoDecodingFailed }
            let pixels = try PixelBufferUtilities.makePixelBuffer(from: upright)
            let depth = try await depthEstimator.predictRawDepth(pixelBuffer: pixels, model: options.depthModel, quality: options.depthQuality)
            try Task.checkCancellation()
            let renderer = StereoRenderer(depthEstimator: depthEstimator)
            let sbs = try renderer.makeSBS(from: pixels, rawDepth: depth, strength: strength, options: options)
            let output = try StereoFocusDots.addingIfEnabled(to: sbs, enabled: options.focusDotsEnabled)
            jpeg = try AppGalleryLibrary.jpegData(for: PixelBufferUtilities.makeCGImage(from: output))
        }
        return GalleryHTTPResponse(200, ["Content-Type": "image/jpeg"], body: GalleryResponseBody(jpeg))
    }

    private static func preview(_ provider: NSItemProvider) async throws -> UIImage {
        try await PhotoWebLoad<UIImage>().get { finish in
            provider.loadPreviewImage(options: [NSItemProviderPreferredImageSizeKey: NSValue(cgSize: CGSize(width: 320, height: 320))]) { value, error in
                finish(value as? UIImage, error)
            }
            return {}
        }
    }

    private static func copyRepresentation(_ provider: NSItemProvider, type: UTType) async throws -> PhotoWebFile {
        try await PhotoWebLoad<PhotoWebFile>().get { finish in
            let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { finish(nil, error); return }
                do {
                    let temp = try PhotoWebFile(copying: url)
                    finish(temp, nil)
                } catch { finish(nil, error) }
            }
            return { progress.cancel() }
        }
    }
}

final class PhotoWebFile {
    let url: URL

    init(copying source: URL) throws {
        url = try TempFiles.makeTemporaryFileURL(prefix: "web-photos", fileExtension: source.pathExtension)
        // The item provider can withdraw its URL when the callback returns. Keep a
        // private link for the request, copying only if the filesystem requires it.
        do { try FileManager.default.linkItem(at: source.resolvingSymlinksInPath(), to: url) }
        catch { try FileManager.default.copyItem(at: source, to: url) }
    }

    deinit { TempFiles.removeItemIfExists(at: url) }
}

/// PhotoKit and item-provider callbacks can arrive before the request ID or after cancellation.
private final class PhotoWebLoad<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelRequest: (() -> Void)?
    private var cancelled = false

    func get(_ start: (@escaping (Value?, Error?) -> Void) -> () -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stopped = lock.withLock {
                    if !cancelled { self.continuation = continuation }
                    return cancelled
                }
                if stopped { continuation.resume(throwing: CancellationError()); return }
                let cancel = start { value, error in
                    let waiting = self.lock.withLock {
                        defer { self.continuation = nil; self.cancelRequest = nil }
                        return self.continuation
                    }
                    if let value { waiting?.resume(returning: value) }
                    else { waiting?.resume(throwing: error ?? StereoPipelineError.mediaDecodingFailed) }
                }
                let cancelNow = lock.withLock {
                    if self.continuation != nil { self.cancelRequest = cancel }
                    return cancelled
                }
                if cancelNow { cancel() }
            }
        } onCancel: {
            let (waiting, cancel) = self.lock.withLock {
                self.cancelled = true
                defer { self.continuation = nil; self.cancelRequest = nil }
                return (self.continuation, self.cancelRequest)
            }
            cancel?()
            waiting?.resume(throwing: CancellationError())
        }
    }
}
