import Combine
import Foundation

final class StereoPipeline: ObservableObject {
    let depthEstimator: DepthEstimator
    let stereoRenderer: StereoRenderer
    let videoProcessor: VideoProcessor

    init() {
        TempFiles.cleanupStaleFiles()

        depthEstimator = DepthEstimator()
        stereoRenderer = StereoRenderer(depthEstimator: depthEstimator)
        videoProcessor = VideoProcessor(depthEstimator: depthEstimator, renderer: stereoRenderer)
    }
}
