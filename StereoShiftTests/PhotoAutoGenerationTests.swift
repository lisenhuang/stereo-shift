import SwiftUI
import UIKit
import XCTest
@testable import StereoShift

final class PhotoAutoGenerationTests: XCTestCase {
    @MainActor
    func testImportedPhotoGeneratesWithoutTappingGenerate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 30, y: 16, width: 32, height: 32))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let generated = expectation(description: "SBS photo generated from the imported file")
        let flow = PhotoFlowView(
            pipeline: StereoPipeline(), inputMode: .constant(.regular2D),
            strength: .constant(0.8), sbsLayoutEnabled: .constant(true),
            stereo3DOptions: .constant(Stereo3DOptions()),
            subscriptionManager: SubscriptionManager(), galleryLibrary: AppGalleryLibrary(),
            importedFileURL: url, onRequireSubscription: { XCTFail("Photo generation requested a subscription") },
            onGenerated: { generated.fulfill() }, onProcessingStateChanged: { _ in }
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: flow)
        window.isHidden = false
        defer { window.isHidden = true }

        await fulfillment(of: [generated], timeout: 60)
    }
}
