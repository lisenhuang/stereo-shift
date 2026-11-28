import Foundation

/// Each HTTP consumer owns a cursor. The transport reads again only when the viewer is ready.
final class GalleryResponseBody {
    static let chunkSize = 256 * 1024
    let length: Int64
    private(set) var remaining: Int64
    private let data: Data?
    private let file: FileHandle?

    init(_ data: Data) {
        self.data = data
        file = nil
        length = Int64(data.count)
        remaining = length
    }

    init(file: FileHandle, offset: Int64, length: Int64) throws {
        try file.seek(toOffset: UInt64(offset))
        self.file = file
        data = nil
        self.length = length
        remaining = length
    }

    func read() throws -> Data {
        let count = Int(min(Int64(Self.chunkSize), remaining))
        guard count > 0 else { return Data() }
        let chunk: Data
        if let data {
            let offset = Int(length - remaining)
            chunk = data.subdata(in: offset..<(offset + count))
        } else if let bytes = try file?.read(upToCount: count), !bytes.isEmpty {
            chunk = bytes
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
        remaining -= Int64(chunk.count)
        return chunk
    }

    deinit { try? file?.close() }
}

struct PhotoWebRequest {
    let id: UUID
    let item: PhotoWebShare.Item
    let thumbnail: Bool
    let request: GalleryHTTPRequest
}

struct GalleryHTTPResponse {
    private(set) var photoRequest: PhotoWebRequest?
    private(set) var liveVideo: LiveWebVideo?
    let status: Int
    var headers: [String: String]
    let body: GalleryResponseBody
    let length: Int64

    init(_ status: Int, _ headers: [String: String], body: GalleryResponseBody, length: Int64? = nil) {
        self.status = status
        self.headers = headers
        self.headers["Cache-Control"] = "private, no-store"
        self.body = body
        self.length = length ?? body.length
    }

    init(photoRequest: PhotoWebRequest) {
        self.init(200)
        self.photoRequest = photoRequest
    }

    init(liveVideo: LiveWebVideo) {
        self.init(200, "", headers: ["Content-Type": "video/mp4", "Accept-Ranges": "none"])
        self.liveVideo = liveVideo
    }

    init(_ status: Int, _ text: String = "", headers: [String: String] = [:]) {
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
        self.init(status, headers, body: GalleryResponseBody(Data(text.utf8)))
    }
}
