import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class StereoPipeline: ObservableObject {
    let depthEstimator: DepthEstimator
    let stereoRenderer: StereoRenderer
    let videoProcessor: VideoProcessor
    /// Optional depth models: catalog, downloads, install state and selection. Views
    /// reach it through the pipeline (`pipeline.depthModelStore`) rather than a
    /// separate environment object.
    let depthModelStore: DepthModelStore
    private var memoryWarningObserver: NSObjectProtocol?

    /// Main-actor because the store is; `HomeView` creates the pipeline as a
    /// `@StateObject`, which runs on the main actor.
    @MainActor
    init() {
        TempFiles.cleanupStaleFiles()
        DepthModelLibrary.purgeStaleStaging()

        depthEstimator = DepthEstimator()
        stereoRenderer = StereoRenderer(depthEstimator: depthEstimator)
        videoProcessor = VideoProcessor(depthEstimator: depthEstimator, renderer: stereoRenderer)
        depthModelStore = DepthModelStore(depthEstimator: depthEstimator)

#if canImport(UIKit) && !os(watchOS)
        // Downloaded models (up to ~0.35B params) are evicted under memory pressure
        // when no prediction is running; the bundled model stays resident.
        let estimator = depthEstimator
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await estimator.unloadIfIdle() }
        }
#endif
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }
}
