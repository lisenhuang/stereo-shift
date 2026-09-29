import AVFoundation
import Foundation
import Testing
@testable import StereoShift

struct InstagramImportTests {
    @Test func handoffContainsOnlyTheQueuedRequestID() throws {
        let request = PendingInstagramImport(id: UUID(), url: URL(string: "https://www.instagram.com/reel/ABC/")!, createdAt: Date())
        #expect(InstagramHandoff.requestID(from: request.handoffURL) == request.id)
        #expect(!request.handoffURL.absoluteString.contains("https"))
        for invalid in ["https://instagram/\(request.id)", "stereoshift://other/\(request.id)",
                        "stereoshift://instagram/not-a-uuid", "stereoshift://instagram/\(request.id)/extra",
                        "stereoshift://instagram/\(request.id)?url=https://example.com", "stereoshift://user@instagram/\(request.id)"] {
            #expect(InstagramHandoff.requestID(from: try #require(URL(string: invalid))) == nil)
        }
    }

    @Test func extractsPostLinksAndRemovesTracking() throws {
        let links = InstagramLink.extract(from: "Watch https://www.instagram.com/reel/ABC_123-/?igsh=tracking then https://www.instagram.com/reel/ABC_123-/")
        #expect(links.map(\.absoluteString) == ["https://www.instagram.com/reel/ABC_123-/"])
        for invalid in ["https://instagram.com.evil.test/p/ABC/", "https://instagram.com@evil.test/p/ABC/",
                        "http://www.instagram.com/p/ABC/", "https://www.instagram.com/accounts/login/",
                        "https://www.instagram.com/stories/person/123/", "https://www.instagram.com/p/ABC/extra/"] {
            #expect(InstagramLink.canonicalURL(try #require(URL(string: invalid))) == nil)
        }
    }

    @Test func parsesVideoWithReorderedAttributesAndEntities() throws {
        let html = """
        <META content='https://www.instagram.com/reel/ABC/' property='og:url'>
        <meta content="https://scontent.cdninstagram.com/video.mp4?x=1&amp;y=&#50;" property="og:video:secure_url">
        <meta property="og:image" content="https://scontent.cdninstagram.com/poster.jpg">
        """
        let media = try InstagramMediaImporter.candidate(in: html, postURL: URL(string: "https://www.instagram.com/reel/ABC/")!)
        #expect(media.kind == .video)
        #expect(media.url.absoluteString == "https://scontent.cdninstagram.com/video.mp4?x=1&y=2")
    }

    @Test func parsesEmbeddedVideoAndSkipsRelatedPosts() throws {
        let html = #"""
        <meta property="og:url" content="https://www.instagram.com/creator.name/reel/ABC/">
        <script type="application/json">{"require":[{"related":{"code":"OTHER","video_versions":[{"url":"https://scontent.cdninstagram.com/wrong.mp4"}]},"__bbox":{"result":{"data":{"xig_polaris_media":{"if_not_gated_logged_out":{"code":"ABC","media_type":2,"video_versions":[{"url":"https:\/\/video.xx.fbcdn.net\/correct.mp4?x=1\u0026y=2"}]}}}}}}]}</script>
        """#
        let media = try InstagramMediaImporter.candidate(in: html, postURL: URL(string: "https://www.instagram.com/reel/ABC/")!)
        #expect(media.kind == .video)
        #expect(media.url.absoluteString == "https://video.xx.fbcdn.net/correct.mp4?x=1&y=2")
        #expect(InstagramLink.canonicalURL(URL(string: "https://www.instagram.com/creator.name/reel/ABC/")!)?.absoluteString == "https://www.instagram.com/reel/ABC/")
        #expect(throws: InstagramImportError.self) {
            try InstagramMediaImporter.candidate(in: html.replacingOccurrences(of: #""code":"ABC""#, with: #""code":"DIFFERENT""#),
                                                postURL: URL(string: "https://www.instagram.com/reel/ABC/")!)
        }
    }

    @Test func neverUsesReelPosterOrLoginImageAsSource() {
        let poster = "<meta property='og:image' content='https://scontent.cdninstagram.com/poster.jpg'>"
        for html in [poster, "<meta property='og:url' content='https://www.instagram.com/reel/ABC/'>" + poster] {
            #expect(throws: InstagramImportError.self) {
                try InstagramMediaImporter.candidate(in: html, postURL: URL(string: "https://www.instagram.com/reel/ABC/")!)
            }
        }
        #expect(throws: InstagramImportError.self) {
            try InstagramMediaImporter.candidate(in: "<meta property='og:url' content='https://www.instagram.com/accounts/login/'>" + poster,
                                                postURL: URL(string: "https://www.instagram.com/p/ABC/")!)
        }
    }

    @Test func videoPostsCannotFallBackToImages() {
        let html = """
        <meta property='og:url' content='https://www.instagram.com/p/ABC/'>
        <meta property='og:type' content='video.other'>
        <meta property='og:image' content='https://scontent.cdninstagram.com/poster.jpg'>
        """
        #expect(throws: InstagramImportError.self) {
            try InstagramMediaImporter.candidate(in: html, postURL: URL(string: "https://www.instagram.com/p/ABC/")!)
        }
    }

    @Test func parsesPhotoAndRejectsForeignMediaHosts() throws {
        let html = """
        <meta property='og:url' content='https://www.instagram.com/p/ABC/'>
        <meta property='og:type' content='instapp:photo'>
        <meta property='og:image' content='https://scontent.cdninstagram.com/image.jpg'>
        """
        let photo = try InstagramMediaImporter.candidate(in: html, postURL: URL(string: "https://www.instagram.com/p/ABC/")!)
        #expect(photo.kind == .photo)
        for invalid in ["https://cdninstagram.com.evil.test/video.mp4", "http://scontent.cdninstagram.com/video.mp4",
                        "https://127.0.0.1/video.mp4", "file:///tmp/photo.jpg", "https://scontent.fbcdn.net:8080/v.mp4"] {
            #expect(!InstagramMediaImporter.allowsMediaURL(URL(string: invalid)!))
        }
        #expect(InstagramMediaImporter.allowsMediaURL(URL(string: "https://video.xx.fbcdn.net/a.mp4")!))
    }

    @Test func parsesMediaAPIResponseWithoutOpenGraphTags() throws {
        let post = URL(string: "https://www.instagram.com/reel/ABC/")!
        let json: [String: Any] = ["data": ["xdt_api__v1__media__shortcode__web_info": ["items": [
            ["code": "ABC", "media_type": 2, "video_versions": [["url": "https://video.xx.fbcdn.net/source.mp4"]]]
        ]]]]
        let candidate = try #require(try InstagramMediaImporter.candidate(inJSON: json, postURL: post))
        #expect(candidate.kind == .video)
        #expect(candidate.url.lastPathComponent == "source.mp4")
        #expect(try InstagramMediaImporter.candidate(inJSON: json, postURL: URL(string: "https://www.instagram.com/reel/OTHER/")!) == nil)
        let data = try JSONSerialization.data(withJSONObject: json)
        let html = "<script type='application/json'>" + String(decoding: data, as: UTF8.self) + "</script>"
        #expect(try InstagramMediaImporter.candidate(in: html, postURL: post).kind == .video)
    }

    @Test func carouselReturnsChildrenInOrderWithoutParentCoverOrRelatedPosts() throws {
        let json: [String: Any] = ["items": [["code": "ABC", "media_type": 8,
            "image_versions2": ["candidates": [["url": "https://scontent.cdninstagram.com/cover.jpg"]]],
            "carousel_media": [
                ["code": "CHILD1", "media_type": 1, "image_versions2": ["candidates": [
                    ["url": "https://scontent.cdninstagram.com/one.jpg", "width": 1080],
                    ["url": "https://scontent.cdninstagram.com/one-thumb.jpg", "width": 320]]]],
                ["code": "CHILD2", "media_type": 1, "image_versions2": ["candidates": [
                    ["url": "https://scontent.cdninstagram.com/two.jpg"]]]]
            ]
        ], ["code": "OTHER", "media_type": 1, "display_url": "https://scontent.cdninstagram.com/wrong.jpg"]]]
        let candidates = try #require(try InstagramMediaImporter.candidates(inJSON: json, postURL: URL(string: "https://www.instagram.com/p/ABC/")!))
        #expect(candidates.map { $0.url.lastPathComponent } == ["one.jpg", "two.jpg"])
        #expect(candidates.allSatisfy { $0.kind == .photo })
        #expect(candidates[0].thumbnailURL?.lastPathComponent == "one-thumb.jpg")
    }

    @Test func graphSidecarSupportsPhotosAndVideosButNeverImportsVideoPosters() throws {
        let json: [String: Any] = ["shortcode": "ABC", "__typename": "GraphSidecar",
            "edge_sidecar_to_children": ["edges": [
                ["node": ["is_video": false, "display_url": "https://scontent.cdninstagram.com/photo.jpg"]],
                ["node": ["is_video": true, "display_url": "https://scontent.cdninstagram.com/poster.jpg"]],
                ["node": ["is_video": true, "video_url": "https://video.xx.fbcdn.net/clip.mp4",
                          "display_url": "https://scontent.cdninstagram.com/thumb.jpg"]],
                ["node": ["is_video": false, "display_url": "https://evil.test/photo.jpg"]]
            ]]]
        let postURL = URL(string: "https://www.instagram.com/p/ABC/")!
        let candidates = try #require(try InstagramMediaImporter.candidates(inJSON: json, postURL: postURL))
        #expect(candidates.map(\.kind) == [.photo, .video])
        #expect(candidates.map { $0.url.lastPathComponent } == ["photo.jpg", "clip.mp4"])
        let html = "<script type='application/json'>" + String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "</script>"
        #expect(try InstagramMediaImporter.candidates(in: html, postURL: postURL).count == 2)
    }

    @Test func unavailableCarouselCannotSilentlyImportItsCover() {
        let post: [String: Any] = ["code": "ABC", "media_type": 8,
                                  "display_url": "https://scontent.cdninstagram.com/cover.jpg"]
        #expect(throws: InstagramImportError.self) {
            try InstagramMediaImporter.candidates(inJSON: post, postURL: URL(string: "https://www.instagram.com/p/ABC/")!)
        }
    }

    @Test func mediaQueryIncludesCSRFHeaderAndRequiredRelayVariable() throws {
        let request = InstagramMediaImporter.mediaRequest(postURL: URL(string: "https://www.instagram.com/reel/ABC/")!, csrfToken: "anonymous-token")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://www.instagram.com/graphql/query")
        #expect(request.value(forHTTPHeaderField: "X-CSRFToken") == "anonymous-token")
        let body = try #require(request.httpBody)
        let form = try #require(URLComponents(string: "?" + String(decoding: body, as: UTF8.self)))
        let encoded = try #require(form.queryItems?.first(where: { $0.name == "variables" })?.value)
        let variables = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(variables["shortcode"] as? String == "ABC")
        #expect(variables["__relay_internal__pv__PolarisAIGMMediaWebLabelEnabledrelayprovider"] as? Bool == false)
    }

    @Test func presentedShareDoesNotReopenAfterClosingFailureOrRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = URL(string: "https://www.instagram.com/reel/ABC/")!
        let older = try InstagramShareInbox.enqueue(url, in: folder)
        let latest = try InstagramShareInbox.enqueue(url, in: folder)
        #expect(try InstagramShareInbox.takePending(in: folder)?.id == latest.id)
        // No success callback is needed: even a cancelled or failed import is consumed.
        #expect(try InstagramShareInbox.takePending(in: folder) == nil)
        #expect(try InstagramShareInbox.takePending(requestID: latest.id, in: folder) == nil)
        #expect(try InstagramShareInbox.takePending(requestID: older.id, in: folder) == nil)
        let reshared = try InstagramShareInbox.enqueue(url, in: folder)
        #expect(try InstagramShareInbox.takePending(in: folder)?.id == reshared.id)
    }

    @Test func explicitHandoffPreservesNewerSharesAndUnknownIDsDoNotConsumeThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = URL(string: "https://www.instagram.com/reel/ABC/")!
        let first = try InstagramShareInbox.enqueue(url, in: folder)
        let second = try InstagramShareInbox.enqueue(url, in: folder)
        #expect(try InstagramShareInbox.takePending(requestID: UUID(), in: folder) == nil)
        #expect(try InstagramShareInbox.pending(in: folder).count == 2)
        #expect(try InstagramShareInbox.takePending(requestID: first.id, in: folder)?.id == first.id)
        #expect(try InstagramShareInbox.pending(in: folder).map(\.id) == [second.id])
    }

    @Test func inboxPersistsMultipleSharesAndOnlyRemovesSelectedRequest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = URL(string: "https://www.instagram.com/reel/ABC/")!
        try InstagramShareInbox.enqueue(url, in: folder)
        try InstagramShareInbox.enqueue(url, in: folder)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("invalid.json"))
        let queued = try InstagramShareInbox.pending(in: folder)
        #expect(queued.count == 2)
        try InstagramShareInbox.remove(try #require(queued.first), in: folder)
        #expect(try InstagramShareInbox.pending(in: folder).map(\.id) == [queued[1].id])
    }
}

struct InstagramNetworkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STEREOSHIFT_INSTAGRAM_TEST_URL"] != nil))
    func downloadsPlayableMediaOnThisDevice() async throws {
        let link = try #require(ProcessInfo.processInfo.environment["STEREOSHIFT_INSTAGRAM_TEST_URL"])
        let progress = InstagramProgressCapture()
        let media = try await InstagramMediaImporter.download(postURL: #require(URL(string: link)), onProgress: {
            progress.append($0)
        }, onEvent: {
            print("INSTAGRAM_DEVICE_TEST: \($0)")
        })
        defer { try? FileManager.default.removeItem(at: media.url) }
        let size = try media.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0)
        #expect(media.kind == .video)
        let updates = progress.values
        #expect(updates.contains { $0 > 0 && $0 < 1 })
        #expect(updates.last == 1)
        #expect(updates.allSatisfy { (0...1).contains($0) })
        print("INSTAGRAM_DEVICE_TEST: received \(updates.count) progress updates including intermediate percentages")
        let asset = AVURLAsset(url: media.url)
        #expect(try await asset.load(.isPlayable))
        let duration = try await asset.load(.duration)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let dimensions = try await track.load(.naturalSize)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        print("INSTAGRAM_DEVICE_TEST: duration \(duration.seconds), dimensions \(dimensions), audio tracks \(audioTracks.count)")
        print("INSTAGRAM_DEVICE_TEST: downloaded and validated \(size) bytes on \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}

private final class InstagramProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] { lock.withLock { recorded } }
    func append(_ value: Double) { lock.withLock { recorded.append(value) } }
}
