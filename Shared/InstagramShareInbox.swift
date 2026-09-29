import Foundation

enum InstagramLink {
    /// Keep only the post identity, without tracking parameters or a carousel index.
    static func canonicalURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["instagram.com", "www.instagram.com", "m.instagram.com"].contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        var parts = url.path.split(separator: "/")
        // Instagram's canonical metadata sometimes includes the owner's username.
        if parts.count == 3, parts[0].range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil {
            parts.removeFirst()
        }
        guard parts.count == 2, ["p", "reel", "reels", "tv"].contains(String(parts[0])),
              parts[1].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let kind = parts[0] == "reels" ? "reel" : String(parts[0])
        return URL(string: "https://www.instagram.com/\(kind)/\(parts[1])/")
    }

    static func extract(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url.flatMap(canonicalURL), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}

struct PendingInstagramImport: Codable, Identifiable {
    let id: UUID
    let url: URL
    let createdAt: Date

    var handoffURL: URL {
        URL(string: "stereoshift://instagram/\(id.uuidString)")!
    }
}

enum InstagramHandoff {
    static func requestID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "stereoshift", components.host == "instagram",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
}

enum InstagramShareInbox {
    static func directory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.huanglisen.StereoShift"
        ) else { throw CocoaError(.fileNoSuchFile) }
        let folder = container.appendingPathComponent("StereoShift/InstagramInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // Each request has its own atomically published file so the extension and app
    // cannot overwrite one another's queue updates.
    @discardableResult
    static func enqueue(_ url: URL, in folder: URL? = nil) throws -> PendingInstagramImport {
        guard let url = InstagramLink.canonicalURL(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let folder = try folder ?? directory()
        let item = PendingInstagramImport(id: UUID(), url: url, createdAt: Date())
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("\(item.id).json"), options: .atomic)
        return item
    }

    static func pending(in folder: URL? = nil) throws -> [PendingInstagramImport] {
        let folder = try folder ?? directory()
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file),
                      let item = try? JSONDecoder().decode(PendingInstagramImport.self, from: data),
                      file.lastPathComponent == "\(item.id).json",
                      InstagramLink.canonicalURL(item.url) != nil else { return nil }
                return item
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Consume before presentation so closing, failing, or restarting cannot reopen a share.
    /// Older queued shares are superseded; requests added after this snapshot stay queued.
    static func takePending(requestID: UUID? = nil, in folder: URL? = nil) throws -> PendingInstagramImport? {
        let folder = try folder ?? directory()
        let items = try pending(in: folder)
        let index = requestID.flatMap { id in items.firstIndex { $0.id == id } }
            ?? (requestID == nil ? items.indices.last : nil)
        guard let index else { return nil }
        let selected = items[index]
        for item in items[...index] {
            try remove(item, in: folder)
        }
        return selected
    }

    static func remove(_ item: PendingInstagramImport, in folder: URL? = nil) throws {
        let folder = try folder ?? directory()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(item.id).json"))
    }
}
