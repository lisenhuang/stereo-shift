import AVFoundation
import Photos
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import StereoShift

final class PhotoWebShareTests: XCTestCase {
    private func share(_ source: PhotoWebShare.Source) -> PhotoWebShare {
        PhotoWebShare(source: source, depthEstimator: DepthEstimator(), strength: 0.8, options: Stereo3DOptions())
    }

    func testLibraryRequiresFullOrLimitedConsent() {
        for denied in [PHAuthorizationStatus.notDetermined, .denied, .restricted] {
            XCTAssertFalse(PhotoWebShare.permitsBrowsing(denied))
            XCTAssertFalse(share(.library(denied)).isAvailable)
        }
        XCTAssertTrue(PhotoWebShare.permitsBrowsing(.limited))
        XCTAssertTrue(PhotoWebShare.permitsBrowsing(.authorized))
        XCTAssertFalse(share(.selected([])).isAvailable)
    }

    func testLibraryUsesPhotosAuthorisationAndResolvesPermittedVideo() async throws {
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(PhotoWebShare.permitsBrowsing(permission), "Requires a seeded, authorised simulator Photos library")
        let library = share(.library(permission))
        let page = library.page(offset: 0, limit: 20, canPlayVideo: true)
        let movie = try XCTUnwrap(page.items.first { $0.live })
        let token = try XCTUnwrap(UUID(uuidString: String(movie.mediaPath.dropFirst("/media/".count))))
        let item = try XCTUnwrap(library.item(token))
        let thumb = try await library.response(for: item, thumbnail: true)
        XCTAssertGreaterThan(thumb.length, 0)
        let video = try await library.response(for: item, thumbnail: false)
        let asset = try XCTUnwrap(video.liveVideo?.asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty)
        let otherConsent: PHAuthorizationStatus = permission == .limited ? .authorized : .limited
        XCTAssertFalse(share(.library(otherConsent)).isAvailable)
        XCTAssertNil(share(.library(permission)).item(token))
    }

    @MainActor
    func testSelectedShareHTTPIsScopedAndVideoRequiresPayment() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-preview-portrait", withExtension: "mp4"))
        let movie = NSItemProvider(contentsOf: url)!
        let frame = try await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: .zero).image
        let jpeg = try AppGalleryLibrary.jpegData(for: frame)
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let saved = try await AppGalleryLibrary().saveMedia(at: imageURL, type: .image)
        defer {
            try? FileManager.default.removeItem(at: saved.url)
            if let thumbnail = saved.thumbnailURL { try? FileManager.default.removeItem(at: thumbnail) }
        }
        let selected = share(.selected([NSItemProvider(contentsOf: imageURL)!, movie]))
        let ready = expectation(description: "Loopback listener")
        var port: UInt16 = 0
        var originKey = ""
        let server = GalleryWebServer(runTunnel: { newPort, key, _ in
            await MainActor.run { port = newPort; originKey = key; ready.fulfill() }
            try await Task.sleep(for: .seconds(180))
        }, localAddress: { nil })
        let access = SubscriptionManager(productIDs: [], userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertTrue(server.startPhotos(selected, access: access))
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let client = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        var cookie: String?
        func get(_ path: String, _ method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)" + path)))
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            request.setValue(originKey, forHTTPHeaderField: "X-StereoShift-Origin")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let (data, response) = try await client.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let (_, locked) = try await get("/api/items")
        XCTAssertEqual(locked.statusCode, 302)
        let (_, login) = try await get("/session-auth?pin=" + server.accessPIN)
        cookie = try XCTUnwrap(login.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
        func page(_ offset: Int) async throws -> [String: Any] {
            let (data, _) = try await get("/api/items?offset=\(offset)&limit=1")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let first = try await page(0)
        XCTAssertEqual(first["photos"] as? Bool, true)
        XCTAssertEqual(first["hasMore"] as? Bool, true)
        let photo = try XCTUnwrap((first["items"] as? [[String: Any]])?.first)
        let photoPath = try XCTUnwrap(photo["mediaPath"] as? String)
        let (sbs, photoResponse) = try await get(photoPath)
        XCTAssertEqual(photoResponse.mimeType, "image/jpeg")
        let decoded = try XCTUnwrap(UIImage(data: sbs)?.cgImage)
        XCTAssertEqual(decoded.width, 2 * frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        let second = try await page(1)
        XCTAssertEqual(second["hasMore"] as? Bool, false)
        let video = try XCTUnwrap((second["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(video["locked"] as? Bool, true)
        let videoPath = try XCTUnwrap(video["mediaPath"] as? String)
        let thumbPath = try XCTUnwrap(video["thumbnailPath"] as? String)
        let (thumb, _) = try await get(thumbPath)
        XCTAssertNotNil(UIImage(data: thumb))
        let (_, unpaid) = try await get(videoPath)
        XCTAssertEqual(unpaid.statusCode, 403)
        let (_, otherMedia) = try await get("/media/" + saved.id)
        XCTAssertEqual(otherMedia.statusCode, 404)
        let (_, otherStream) = try await get("/live/\(UUID()).mp4")
        XCTAssertEqual(otherStream.statusCode, 404)
        server.updateVideoAccess(true)
        let (bytes, stream) = try await get(videoPath)
        XCTAssertEqual(stream.mimeType, "video/mp4")
        XCTAssertNotNil(bytes.range(of: Data("moof".utf8)))
        server.updateVideoAccess(false)
        let (_, revoked) = try await get(videoPath, "HEAD")
        XCTAssertEqual(revoked.statusCode, 403)
        server.resetAccessPIN()
        let (_, oldCookie) = try await get(photoPath)
        XCTAssertEqual(oldCookie.statusCode, 302)
        let newShare = share(.selected([movie]))
        let oldID = try XCTUnwrap(UUID(uuidString: String(videoPath.dropFirst("/media/".count))))
        XCTAssertNil(newShare.item(oldID))
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
