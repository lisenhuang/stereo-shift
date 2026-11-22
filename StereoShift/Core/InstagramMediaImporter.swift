import AVFoundation
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

struct ImportedInstagramMedia: Identifiable {
    enum Kind: Equatable, Sendable { case photo, video }
    let id = UUID()
    let url: URL
    let kind: Kind
}

enum InstagramImportError: LocalizedError {
    case invalidLink, unavailable, previewOnly, tooLarge, invalidMedia, loginRequired, rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return NSLocalizedString("Paste an Instagram post or Reel link.", comment: "")
        case .unavailable:
            return NSLocalizedString("Instagram did not make the media available for this post.", comment: "")
        case .previewOnly:
            return NSLocalizedString("Instagram only made a cropped preview available. Choose the original from Photos.", comment: "")
        case .loginRequired:
            return NSLocalizedString("Instagram requires a signed-in session to access this post.", comment: "")
        case .rateLimited:
            return NSLocalizedString("Instagram is temporarily limiting downloads on this connection. Please try again later.", comment: "")
        case .tooLarge:
            return NSLocalizedString("This file is too large for link import (250 MB maximum). Save it first and import it from Photos.", comment: "")
        case .invalidMedia:
            return NSLocalizedString("The downloaded file could not be opened as a photo or video.", comment: "")
        }
    }
}

enum InstagramMediaImporter {
    struct Candidate: Equatable, Sendable {
        let url: URL
        let kind: ImportedInstagramMedia.Kind
        var thumbnailURL: URL? = nil
    }

    final class ResolvedPost: Sendable {
        let candidates: [Candidate]
        fileprivate let session: URLSession
        fileprivate let trace: InstagramImportTrace

        fileprivate init(candidates: [Candidate], session: URLSession, trace: InstagramImportTrace) {
            self.candidates = candidates
            self.session = session
            self.trace = trace
        }

        func cancel() { session.invalidateAndCancel() }
        deinit { session.invalidateAndCancel() }
    }

    static func allowsPageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            ["instagram.com", "www.instagram.com", "m.instagram.com"].contains(url.host?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    static func allowsMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["cdninstagram.com", "fbcdn.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Read public page data without running JavaScript. A Reel's poster is never a video fallback.
    static func candidate(in html: String, postURL: URL) throws -> Candidate {
        guard let first = try candidates(in: html, postURL: postURL).first else { throw InstagramImportError.unavailable }
        return first
    }

    static func candidates(in html: String, postURL: URL) throws -> [Candidate] {
        let tags = matches("<meta\\b[^>]*>", in: html)
        var metadata: [String: String] = [:]
        for tag in tags {
            let attributes = htmlAttributes(in: tag)
            if let key = attributes["property"] ?? attributes["name"], let value = attributes["content"] {
                metadata[key.lowercased()] = value
            }
        }
        // Embedded media identifies the exact post even when Open Graph tags are absent.
        if let embedded = try embeddedCandidate(in: html, postURL: postURL) { return embedded }
        // Login pages and generic previews must not be mistaken for a post photo.
        guard let pageURL = metadata["og:url"].flatMap(URL.init(string:)),
              InstagramLink.canonicalURL(pageURL) == InstagramLink.canonicalURL(postURL) else {
            throw InstagramImportError.unavailable
        }
        for key in ["og:video:secure_url", "og:video:url", "og:video"] {
            if let url = metadata[key].flatMap(URL.init(string:)), allowsMediaURL(url) {
                return [Candidate(url: url, kind: .video)]
            }
        }
        let isVideo = postURL.path.hasPrefix("/reel/") || postURL.path.hasPrefix("/tv/") ||
            (metadata["og:type"]?.lowercased().contains("video") ?? false) ||
            metadata.keys.contains(where: { $0.hasPrefix("og:video") })
        guard !isVideo, let url = metadata["og:image"].flatMap(URL.init(string:)), allowsMediaURL(url) else {
            throw InstagramImportError.unavailable
        }
        guard !isCroppedImageURL(url) else { throw InstagramImportError.previewOnly }
        return [Candidate(url: url, kind: .photo)]
    }

    private static func embeddedCandidate(in html: String, postURL: URL) throws -> [Candidate]? {
        guard let shortcode = InstagramLink.canonicalURL(postURL)?.lastPathComponent else { return nil }
        let pattern = #"<script\b[^>]*>([\s\S]*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var remainingNodes = 50_000
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let script = String(html[range])
            guard script.contains(shortcode), let data = script.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let candidate = try candidates(inJSON: root, shortcode: shortcode, remainingNodes: &remainingNodes) {
                return candidate
            }
        }
        return nil
    }

    static func candidate(inJSON root: Any, postURL: URL) throws -> Candidate? {
        try candidates(inJSON: root, postURL: postURL)?.first
    }

    static func candidates(inJSON root: Any, postURL: URL) throws -> [Candidate]? {
        guard let shortcode = InstagramLink.canonicalURL(postURL)?.lastPathComponent else { return nil }
        var remainingNodes = 50_000
        return try candidates(inJSON: root, shortcode: shortcode, remainingNodes: &remainingNodes)
    }

    private static func candidates(inJSON root: Any, shortcode: String, remainingNodes: inout Int) throws -> [Candidate]? {
        var stack: [(Any, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast(), remainingNodes > 0 {
            remainingNodes -= 1
            guard depth < 40 else { continue }
            if let object = node as? [String: Any] {
                // Related posts can share the same page payload. Never select
                // a media URL unless its enclosing post matches the shared code.
                if (object["code"] as? String ?? object["shortcode"] as? String) == shortcode {
                    if object["if_not_gated_logged_out"] is NSNull, object["gating_ruling"] is [String: Any] {
                        throw InstagramImportError.loginRequired
                    }
                    // Children belong to the verified parent post; their shortcodes differ.
                    let children = object["carousel_media"] as? [[String: Any]]
                        ?? ((object["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]])?
                            .compactMap { $0["node"] as? [String: Any] }
                    if let children {
                        let media = children.prefix(30).compactMap(singleCandidate)
                        guard !media.isEmpty else { throw InstagramImportError.unavailable }
                        return media
                    }
                    guard object["media_type"] as? Int != 8,
                          object["__typename"] as? String != "GraphSidecar" else { throw InstagramImportError.unavailable }
                    if let media = singleCandidate(object) { return [media] }
                    if object["media_type"] as? Int == 2 || object["is_video"] as? Bool == true ||
                        object["media_type"] as? Int == 8 || object["__typename"] as? String == "GraphSidecar" {
                        throw InstagramImportError.unavailable
                    }
                }
                stack.append(contentsOf: object.values.map { ($0, depth + 1) })
            } else if let array = node as? [Any] {
                stack.append(contentsOf: array.map { ($0, depth + 1) })
            } else if let string = node as? String, string.contains(shortcode),
                      let data = string.data(using: .utf8),
                      let nested = try? JSONSerialization.jsonObject(with: data) {
                stack.append((nested, depth + 1))
            }
        }
        return nil
    }

    private static func singleCandidate(_ object: [String: Any]) -> Candidate? {
        let images = (object["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]] ?? []
        let imageURLs = images.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.filter(allowsMediaURL)
        let displayURL = (object["display_url"] as? String).flatMap(URL.init(string:)).flatMap { allowsMediaURL($0) ? $0 : nil }
        let photoURL = bestPhotoMatchingOriginalRatio(in: images, media: object) ?? imageURLs.first ?? displayURL
        let thumbnail = images.filter { ($0["width"] as? Int ?? 0) >= 240 }
            .sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
            .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first(where: allowsMediaURL) ?? photoURL
        let videos = object["video_versions"] as? [[String: Any]] ?? []
        let videoURL = videos.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first(where: allowsMediaURL)
            ?? (object["video_url"] as? String).flatMap(URL.init(string:)).flatMap { allowsMediaURL($0) ? $0 : nil }
        if let videoURL { return Candidate(url: videoURL, kind: .video, thumbnailURL: thumbnail) }
        guard object["media_type"] as? Int != 2, object["is_video"] as? Bool != true,
              object["__typename"] as? String != "GraphVideo", let photoURL else { return nil }
        return Candidate(url: photoURL, kind: .photo, thumbnailURL: thumbnail)
    }

    private static func bestPhotoMatchingOriginalRatio(in images: [[String: Any]], media: [String: Any]) -> URL? {
        let dimensions = media["dimensions"] as? [String: Any]
        guard let width = media["original_width"] as? Int ?? dimensions?["width"] as? Int, width > 0,
              let height = media["original_height"] as? Int ?? dimensions?["height"] as? Int, height > 0 else { return nil }

        let originalRatio = Double(width) / Double(height)
        return images.compactMap { image -> (url: URL, width: Int)? in
            guard let width = image["width"] as? Int, width > 0,
                  let height = image["height"] as? Int, height > 0,
                  abs((Double(width) / Double(height)) / originalRatio - 1) <= 0.015,
                  let url = (image["url"] as? String).flatMap(URL.init(string:)),
                  allowsMediaURL(url), !isCroppedImageURL(url) else { return nil }
            return (url, width)
        }.max { $0.width < $1.width }?.url
    }

    private static func isCroppedImageURL(_ url: URL) -> Bool {
        let transform = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stp" }?.value
        return transform?.range(of: #"(?:^|_)c[0-9]+(?:\.[0-9]+){3}a?(?:_|$)"#, options: .regularExpression) != nil
    }

    private static func uncroppedEmbedSource(from srcset: String?) -> URL? {
        srcset?.split(separator: ",").compactMap { variant -> (url: URL, width: Int)? in
            let fields = variant.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1].hasSuffix("w"),
                  let width = Int(fields[1].dropLast()), width > 0,
                  let url = URL(string: String(fields[0])), allowsMediaURL(url), !isCroppedImageURL(url) else { return nil }
            return (url, width)
        }.max { $0.width < $1.width }?.url
    }

    static func download(postURL: URL, onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                         onEvent: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ImportedInstagramMedia {
        let post = try await prepare(postURL: postURL, onEvent: onEvent)
        defer { post.cancel() }
        guard let first = post.candidates.first else { throw InstagramImportError.unavailable }
        return try await download(first, from: post, onProgress: onProgress)
    }

    static func prepare(postURL: URL, onEvent: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ResolvedPost {
        guard let postURL = InstagramLink.canonicalURL(postURL) else { throw InstagramImportError.invalidLink }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        let trace = InstagramImportTrace(onEvent: onEvent)
        do {
            let candidates = try await resolve(postURL: postURL, session: session, trace: trace)
            try Task.checkCancellation()
            return ResolvedPost(candidates: candidates, session: session, trace: trace)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    static func thumbnail(_ candidate: Candidate, from post: ResolvedPost) async throws -> CGImage {
        guard post.candidates.contains(candidate),
              let url = candidate.thumbnailURL ?? (candidate.kind == .photo ? candidate.url : nil) else {
            throw InstagramImportError.invalidMedia
        }
        let (file, response) = try await fetch(URLRequest(url: url), session: post.session,
                                              limit: 8 * 1_024 * 1_024, media: true, trace: post.trace)
        defer { TempFiles.removeItemIfExists(at: file) }
        guard response.mimeType?.hasPrefix("image/") == true,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw InstagramImportError.invalidMedia }
        try Task.checkCancellation()
        return image
    }

    static func download(_ candidate: Candidate, from post: ResolvedPost,
                         onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ImportedInstagramMedia {
        guard post.candidates.contains(candidate) else { throw InstagramImportError.invalidMedia }
        let session = post.session
        let trace = post.trace
        trace.record("Resolved \(candidate.kind)")
        let (mediaFile, response) = try await fetch(URLRequest(url: candidate.url), session: session,
                                                   limit: 250 * 1_024 * 1_024, media: true, trace: trace, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: mediaFile) }
        try Task.checkCancellation()
        let mime = response.mimeType ?? ""
        let fileExtension = candidate.kind == .video
            ? (mime == "video/quicktime" ? "mov" : "mp4")
            : (UTType(mimeType: mime)?.preferredFilenameExtension ?? "jpg")
        let destination = try TempFiles.makeTemporaryFileURL(prefix: "instagram", fileExtension: fileExtension)
        // AVFoundation may reject URLSession's .tmp files even when they contain
        // valid MP4 data. Give the file its media extension before opening it.
        try FileManager.default.moveItem(at: mediaFile, to: destination)
        var keepFile = false
        defer { if !keepFile { TempFiles.removeItemIfExists(at: destination) } }
        switch candidate.kind {
        case .photo:
            guard mime.hasPrefix("image/"),
                  let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else {
                throw InstagramImportError.invalidMedia
            }
        case .video:
            guard mime.hasPrefix("video/") || mime == "application/octet-stream" else { throw InstagramImportError.invalidMedia }
            let asset = AVURLAsset(url: destination)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            guard !tracks.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else { throw InstagramImportError.invalidMedia }
        }
        try Task.checkCancellation()
        trace.record("Validated \(candidate.kind) file")
        keepFile = true
        onProgress(1)
        return ImportedInstagramMedia(url: destination, kind: candidate.kind)
    }

    private static func resolve(postURL: URL, session: URLSession, trace: InstagramImportTrace) async throws -> [Candidate] {
        let embedURL = postURL.appendingPathComponent("embed", isDirectory: true)
        let embed: String?
        do {
            embed = try await page(embedURL, session: session, trace: trace)
        } catch InstagramImportError.unavailable {
            embed = nil
        }
        if let embed, let media = try publicEmbedCandidates(in: embed, postURL: postURL) {
            trace.record("Public embed returned matching media")
            return media
        }
        let html = try await page(postURL, session: session, trace: trace)
        return try candidates(in: html, postURL: postURL)
    }

    /// Instagram publishes single photos as markup and rich embeds as a JSON
    /// string inside a script. Decode only the data for the shared post.
    static func publicEmbedCandidates(in html: String, postURL: URL) throws -> [Candidate]? {
        guard let shortcode = InstagramLink.canonicalURL(postURL)?.lastPathComponent else {
            throw InstagramImportError.invalidLink
        }
        let container = matches(#"<div\b[^>]*\bdata-permalink\s*=[^>]*>"#, in: html)
            .lazy.map { htmlAttributes(in: $0) }.first { $0["class"]?.split(separator: " ").contains("Embed") == true }
        guard let container else { return nil }
        guard let permalink = container["data-permalink"].flatMap(URL.init(string:)).flatMap(InstagramLink.canonicalURL),
              permalink.lastPathComponent == shortcode else { throw InstagramImportError.unavailable }

        if container["data-media-type"] == "GraphImage" {
            guard !["reel", "tv"].contains(postURL.pathComponents.dropFirst().first ?? "") else {
                throw InstagramImportError.unavailable
            }
            for anchor in matches(#"<a\b[^>]*>\s*<img\b[^>]*>"#, in: html) {
                guard let split = anchor.firstIndex(of: ">") else { continue }
                let link = htmlAttributes(in: String(anchor[...split]))
                let image = htmlAttributes(in: String(anchor[anchor.index(after: split)...]))
                guard link["class"]?.split(separator: " ").contains("EmbeddedMedia") == true,
                      let url = link["href"].flatMap(URL.init(string:)).flatMap(InstagramLink.canonicalURL),
                      url.lastPathComponent == shortcode,
                      image["class"]?.split(separator: " ").contains("EmbeddedMediaImage") == true,
                      let source = image["src"].flatMap(URL.init(string:)), allowsMediaURL(source) else { continue }
                if !isCroppedImageURL(source) { return [Candidate(url: source, kind: .photo)] }
                if let fullPhoto = uncroppedEmbedSource(from: image["srcset"]) {
                    return [Candidate(url: fullPhoto, kind: .photo)]
                }
            }
            return nil
        }

        guard let kind = container["data-media-type"], ["GraphVideo", "GraphSidecar"].contains(kind),
              let key = html.range(of: #""contextJSON"\s*:\s*""#, options: .regularExpression) else {
            throw InstagramImportError.unavailable
        }
        // Find the closing quote of the JSON string, skipping escaped bytes.
        let bytes = html.utf8
        var end = key.upperBound
        while end < bytes.endIndex {
            let byte = bytes[end]
            bytes.formIndex(after: &end)
            if byte == 0x22 { break }
            if byte == 0x5c, end < bytes.endIndex { bytes.formIndex(after: &end) }
        }
        let start = bytes.index(before: key.upperBound)
        guard let json = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<end])),
              let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let context = payload["context"] as? [String: Any], context["shortcode"] as? String == shortcode,
              context["type"] as? String == kind else { throw InstagramImportError.unavailable }

        guard let graph = payload["gql_data"] as? [String: Any],
              let media = graph["shortcode_media"] as? [String: Any] else { return nil }
        guard media["shortcode"] as? String == shortcode, media["__typename"] as? String == kind else {
            throw InstagramImportError.unavailable
        }
        // A Reel embed can have only a poster while the public post supplies the video.
        if kind == "GraphVideo" { return singleCandidate(media).map { [$0] } }
        return try candidates(inJSON: media, postURL: postURL)
    }

    private static func page(_ url: URL, session: URLSession, trace: InstagramImportTrace) async throws -> String {
        let (file, response) = try await fetch(URLRequest(url: url), session: session, limit: 4 * 1_024 * 1_024, media: false, trace: trace)
        defer { try? FileManager.default.removeItem(at: file) }
        guard response.mimeType == "text/html", let html = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw InstagramImportError.unavailable
        }
        return html
    }

    private static func fetch(_ input: URLRequest, session: URLSession, limit: Int64, media: Bool,
                              trace: InstagramImportTrace, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        let delegate = InstagramDownloadGuard(limit: limit, media: media, onProgress: onProgress)
        var request = input
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(media ? "video/*, image/*" : "text/html", forHTTPHeaderField: "Accept")
        }
        do {
            let (file, response) = try await session.download(for: request, delegate: delegate)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            trace.record("\(media ? "Media" : (input.httpMethod ?? "GET") + " " + (input.url?.path ?? "")) HTTP \(status), \(response.mimeType ?? "unknown"), \(size) bytes")
            if let error = responseError(response, media: media) {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            guard size <= limit else {
                try? FileManager.default.removeItem(at: file)
                throw InstagramImportError.tooLarge
            }
            return (file, response)
        } catch {
            if delegate.exceededLimit { throw InstagramImportError.tooLarge }
            throw error
        }
    }

    static func responseError(_ response: URLResponse, media: Bool) -> InstagramImportError? {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              (media ? allowsMediaURL(url) : allowsPageURL(url)) else { return .unavailable }
        if http.statusCode == 429 { return .rateLimited }
        if !media, http.statusCode == 401 || url.pathComponents.prefix(3).elementsEqual(["/", "accounts", "login"]) {
            return .loginRequired
        }
        return (200...299).contains(http.statusCode) ? nil : .unavailable
    }

    private static func htmlAttributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var attributes: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2), in: tag) else { continue }
            attributes[String(tag[keyRange]).lowercased()] = decodeEntities(String(tag[valueRange]))
        }
        return attributes
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for entity in matches("&#(?:[xX][0-9a-fA-F]+|[0-9]+);", in: text) {
            let digits = String(entity.dropFirst(2).dropLast())
            let isHex = digits.lowercased().hasPrefix("x")
            if let code = UInt32(isHex ? String(digits.dropFirst()) : digits, radix: isHex ? 16 : 10),
               let scalar = UnicodeScalar(code) {
                result = result.replacingOccurrences(of: entity, with: String(scalar))
            }
        }
        return result.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private final class InstagramDownloadGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let limit: Int64
    private let media: Bool
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var oversized = false
    private var progressObservation: NSKeyValueObservation?
    var exceededLimit: Bool { lock.withLock { oversized } }

    init(limit: Int64, media: Bool, onProgress: @escaping @Sendable (Double) -> Void) {
        self.limit = limit
        self.media = media
        self.onProgress = onProgress
    }

    // Async URLSession downloads do not deliver didWriteData callbacks.
    // Observe the task's Progress instead, retaining observation for this request.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        progressObservation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self, weak task] _, _ in
            guard let self, let task else { return }
            let received = task.countOfBytesReceived
            let expected = task.countOfBytesExpectedToReceive
            if received > self.limit || expected > self.limit {
                self.lock.withLock { self.oversized = true }
                task.cancel()
                return
            }
            // Unknown lengths stay indeterminate; completion awaits validation.
            if expected > 0 {
                self.onProgress(min(0.99, max(0, Double(received) / Double(expected))))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              (media ? InstagramMediaImporter.allowsMediaURL(url) : InstagramMediaImporter.allowsPageURL(url)) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// Keep only the latest import's transport/validation results, without cookies,
// access tokens, CDN URLs, or page contents, for physical-device diagnostics.
fileprivate final class InstagramImportTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private let onEvent: @Sendable (String) -> Void
    private let file: URL?
    private let logger = Logger(subsystem: "com.huanglisen.StereoShift", category: "InstagramImport")

    init(onEvent: @escaping @Sendable (String) -> Void) {
        self.onEvent = onEvent
        let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        file = folder?.appendingPathComponent("InstagramImportDiagnostic.log")
    }

    func record(_ event: String) {
        logger.info("\(event, privacy: .public)")
        onEvent(event)
        lock.withLock {
            events.append(event)
            if let file { try? events.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8) }
        }
    }
}
