import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StereoShift

@MainActor
struct EngagementTests {
    @Test func thirdPaidExportTriggersReviewAndProgressSurvivesRelaunch() {
        let name = "ReviewTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let firstSession = ReviewPrompter(userDefaults: defaults, currentVersion: "1.0")
        for _ in 0..<5 { firstSession.recordSuccessfulExport(isPaidUser: false) }
        #expect(!firstSession.shouldPromptNow)
        firstSession.recordSuccessfulExport(isPaidUser: true)
        firstSession.recordSuccessfulExport(isPaidUser: true)
        #expect(!firstSession.shouldPromptNow)
        let nextSession = ReviewPrompter(userDefaults: defaults, currentVersion: "1.0")
        nextSession.recordSuccessfulExport(isPaidUser: true)
        #expect(nextSession.shouldPromptNow)
        nextSession.recordPromptShown()
        #expect(!nextSession.shouldPromptNow)
        #expect(!ReviewPrompter(userDefaults: defaults, currentVersion: "1.0").shouldPromptNow)
        #expect(!ReviewPrompter(userDefaults: defaults, currentVersion: "1.1").shouldPromptNow)
    }

    @Test func generatedVideoPreviewHasBoundedHeightInTallScrollContent() {
        let preview = ResultPreviewView(title: "SBS Output",
                                        media: .video(URL(fileURLWithPath: "/tmp/layout-test.mp4")),
                                        allowsFullscreenPreview: true,
                                        canOpenFullscreen: false,
                                        allowsInlinePlayback: true)
        let host = UIHostingController(rootView: preview)
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 4000))
        #expect(size.height >= 200)
        #expect(size.height < 400)
    }

    @Test func newerStoreVersionPromptsButNewerLocalBuildDoesNot() async throws {
        let name = "UpdateTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateLookupStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let oldBundleURL = try makeBundle(version: "9.9.8")
        let newBundleURL = try makeBundle(version: "9.9.10")
        defer {
            try? FileManager.default.removeItem(at: oldBundleURL)
            try? FileManager.default.removeItem(at: newBundleURL)
        }
        let old = AppUpdateChecker(userDefaults: defaults, bundle: try #require(Bundle(url: oldBundleURL)), session: session)
        await old.check(force: true)
        #expect(old.availableUpdate?.version == "9.9.9")
        #expect(old.availableUpdate?.storeURL == AppUpdateChecker.listingURL)
        old.dismiss()
        await old.check(force: true)
        #expect(old.availableUpdate == nil)
        defaults.removePersistentDomain(forName: name)
        let new = AppUpdateChecker(userDefaults: defaults, bundle: try #require(Bundle(url: newBundleURL)), session: session)
        await new.check(force: true)
        #expect(new.availableUpdate == nil)
    }

    private func makeBundle(version: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "test.\(UUID())", "CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent("Info.plist"))
        return folder
    }
}

private final class UpdateLookupStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data(#"{"results":[{"version":"9.9.9"}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
