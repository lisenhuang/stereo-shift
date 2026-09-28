import AVFoundation
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

struct ImportedInstagramMedia: Identifiable {
    enum Kind { case photo, video }
    let id = UUID()
    let url: URL
    let kind: Kind
}

enum InstagramImportError: LocalizedError {
    case invalidLink, unavailable, tooLarge, invalidMedia, loginRequired, rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return NSLocalizedString("Paste an Instagram post or Reel link.", comment: "")
        case .unavailable:
            return NSLocalizedString("Instagram did not return the media for this post. Please try again.", comment: "")
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
    struct Candidate {
        let url: URL
        let kind: ImportedInstagramMedia.Kind
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
        let tags = matches("<meta\\b[^>]*>", in: html)
        var metadata: [String: String] = [:]
        for tag in tags {
            let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            var attributes: [String: String] = [:]
            for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let keyRange = Range(match.range(at: 1), in: tag),
                      let valueRange = Range(match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2), in: tag) else { continue }
                attributes[String(tag[keyRange]).lowercased()] = decodeEntities(String(tag[valueRange]))
            }
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
                return Candidate(url: url, kind: .video)
            }
        }
        let isVideo = postURL.path.hasPrefix("/reel/") || postURL.path.hasPrefix("/tv/") ||
            (metadata["og:type"]?.lowercased().contains("video") ?? false) ||
            metadata.keys.contains(where: { $0.hasPrefix("og:video") })
        guard !isVideo, let url = metadata["og:image"].flatMap(URL.init(string:)), allowsMediaURL(url) else {
            throw InstagramImportError.unavailable
        }
        return Candidate(url: url, kind: .photo)
    }

    private static func embeddedCandidate(in html: String, postURL: URL) throws -> Candidate? {
        guard let shortcode = InstagramLink.canonicalURL(postURL)?.lastPathComponent else { return nil }
        let pattern = #"<script\b[^>]*>([\s\S]*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var remainingNodes = 50_000
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let script = String(html[range])
            guard script.contains(shortcode), let data = script.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let candidate = try candidate(inJSON: root, shortcode: shortcode, remainingNodes: &remainingNodes) {
                return candidate
            }
        }
        return nil
    }

    static func candidate(inJSON root: Any, postURL: URL) throws -> Candidate? {
        guard let shortcode = InstagramLink.canonicalURL(postURL)?.lastPathComponent else { return nil }
        var remainingNodes = 50_000
        return try candidate(inJSON: root, shortcode: shortcode, remainingNodes: &remainingNodes)
    }

    private static func candidate(inJSON root: Any, shortcode: String, remainingNodes: inout Int) throws -> Candidate? {
        var stack: [(Any, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast(), remainingNodes > 0 {
            remainingNodes -= 1
            guard depth < 40 else { continue }
            if let object = node as? [String: Any] {
                // Related posts can share the same page payload. Never select
                // a media URL unless its enclosing post matches the shared code.
                if (object["code"] as? String ?? object["shortcode"] as? String) == shortcode {
                    if let versions = object["video_versions"] as? [[String: Any]],
                       let url = versions.compactMap({ ($0["url"] as? String).flatMap(URL.init(string:)) }).first(where: allowsMediaURL) {
                        return Candidate(url: url, kind: .video)
                    }
                    if let url = (object["video_url"] as? String).flatMap(URL.init(string:)), allowsMediaURL(url) {
                        return Candidate(url: url, kind: .video)
                    }
                    if object["media_type"] as? Int == 2 || object["is_video"] as? Bool == true {
                        throw InstagramImportError.unavailable
                    }
                    if object["media_type"] as? Int == 1,
                       let images = object["image_versions2"] as? [String: Any],
                       let candidates = images["candidates"] as? [[String: Any]],
                       let url = candidates.compactMap({ ($0["url"] as? String).flatMap(URL.init(string:)) }).first(where: allowsMediaURL) {
                        return Candidate(url: url, kind: .photo)
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

    static func download(postURL: URL, onEvent: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ImportedInstagramMedia {
        guard let postURL = InstagramLink.canonicalURL(postURL) else { throw InstagramImportError.invalidLink }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        // Keep anonymous session cookies only for this import. Instagram's public
        // API expects the session established by the page request.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://www.instagram.com/"
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let trace = InstagramImportTrace(onEvent: onEvent)
        let candidate = try await resolve(postURL: postURL, session: session, trace: trace)
        trace.record("Resolved \(candidate.kind)")
        let (mediaFile, response) = try await fetch(URLRequest(url: candidate.url), session: session,
                                                   limit: 250 * 1_024 * 1_024, media: true, trace: trace)
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
        return ImportedInstagramMedia(url: destination, kind: candidate.kind)
    }

    private static func resolve(postURL: URL, session: URLSession, trace: InstagramImportTrace) async throws -> Candidate {
        var lastError: Error = InstagramImportError.unavailable
        do {
            // Establish an anonymous CSRF session, then request the actual media
            // record. Public post pages can show a login/error shell without it.
            let (bootstrap, _) = try await fetch(URLRequest(url: URL(string: "https://www.instagram.com/")!),
                                                  session: session, limit: 4 * 1_024 * 1_024, media: false, trace: trace)
            try? FileManager.default.removeItem(at: bootstrap)
            let cookies = session.configuration.httpCookieStorage?.cookies(for: postURL) ?? []
            let csrf = cookies.first { $0.name == "csrftoken" }?.value
            let request = mediaRequest(postURL: postURL, csrfToken: csrf)
            let (file, _) = try await fetch(request, session: session, limit: 4 * 1_024 * 1_024, media: false, trace: trace)
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            if let json = try? JSONSerialization.jsonObject(with: data),
               let candidate = try candidate(inJSON: json, postURL: postURL) {
                trace.record("Media API returned matching post")
                return candidate
            }
            trace.record("Media API returned no matching media")
        } catch {
            try Task.checkCancellation()
            lastError = error
            trace.record("Media API failed: \(error.localizedDescription)")
        }
        // Keep HTML extraction as an independent fallback when Instagram changes
        // the web query identifier. Never substitute a Reel's cover image.
        do {
            let html = try await page(postURL, session: session, trace: trace)
            return try candidate(in: html, postURL: postURL)
        } catch {
            try Task.checkCancellation()
            trace.record("Page fallback failed: \(error.localizedDescription)")
            if case InstagramImportError.unavailable = lastError { throw error }
            throw lastError
        }
    }

    static func mediaRequest(postURL: URL, csrfToken: String?) -> URLRequest {
        // PolarisPostRootQuery protocol, also used by Instaloader. Query IDs are
        // an upstream web-client detail, not a stable public Instagram API.
        var request = URLRequest(url: URL(string: "https://www.instagram.com/graphql/query")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue(csrfToken ?? "", forHTTPHeaderField: "X-CSRFToken")
        let variables: [String: Any] = [
            "shortcode": postURL.lastPathComponent,
            "__relay_internal__pv__PolarisAIGMMediaWebLabelEnabledrelayprovider": false
        ]
        let json = (try? JSONSerialization.data(withJSONObject: variables)).flatMap { String(data: $0, encoding: .utf8) }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "doc_id", value: "27128499623469141"),
            URLQueryItem(name: "variables", value: json),
            URLQueryItem(name: "server_timestamps", value: "true")
        ]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }

    private static func page(_ url: URL, session: URLSession, trace: InstagramImportTrace) async throws -> String {
        let (file, response) = try await fetch(URLRequest(url: url), session: session, limit: 4 * 1_024 * 1_024, media: false, trace: trace)
        defer { try? FileManager.default.removeItem(at: file) }
        if response.url?.path.hasPrefix("/accounts/login") == true { throw InstagramImportError.loginRequired }
        guard response.mimeType == "text/html", let html = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw InstagramImportError.unavailable
        }
        return html
    }

    private static func fetch(_ input: URLRequest, session: URLSession, limit: Int64, media: Bool,
                              trace: InstagramImportTrace) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        let delegate = InstagramDownloadGuard(limit: limit, media: media)
        var request = input
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(media ? "video/*, image/*" : "text/html", forHTTPHeaderField: "Accept")
        }
        do {
            let (file, response) = try await session.download(for: request, delegate: delegate)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            trace.record("\(media ? "Media" : (input.httpMethod ?? "GET") + " " + (input.url?.path ?? "")) HTTP \(status), \(response.mimeType ?? "unknown"), \(size) bytes")
            if status == 429 {
                try? FileManager.default.removeItem(at: file)
                throw InstagramImportError.rateLimited
            }
            guard (200...299).contains(status),
                  let finalURL = response.url,
                  (media ? allowsMediaURL(finalURL) : allowsPageURL(finalURL)) else {
                try? FileManager.default.removeItem(at: file)
                throw InstagramImportError.unavailable
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

private final class InstagramDownloadGuard: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let media: Bool
    private let lock = NSLock()
    private var oversized = false
    var exceededLimit: Bool { lock.withLock { oversized } }

    init(limit: Int64, media: Bool) {
        self.limit = limit
        self.media = media
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.withLock { oversized = true }
            downloadTask.cancel()
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
private final class InstagramImportTrace {
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
        events.append(event)
        logger.info("\(event, privacy: .public)")
        onEvent(event)
        if let file { try? events.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8) }
    }
}
