import Foundation

enum DepthModel: String, CaseIterable, Sendable {
    case depthAnythingV2SmallF16 = "DepthAnythingV2SmallF16"

    var resourceNameCandidates: [String] {
        switch self {
        case .depthAnythingV2SmallF16:
            return [
                "DepthAnythingV2SmallF16",
                "DepthAnythingV2SmallFP16",
                "coreml-depth-anything-v2-small"
            ]
        }
    }
}

enum DepthQuality: Int, CaseIterable, Sendable {
    case quality = 518

    var shortSide: Int { rawValue }
}

enum StereoRenderEngine: String, CaseIterable, Sendable {
    case cpu
    case ciKernel
}

enum StereoGenerationMethod: String, CaseIterable, Sendable {
    case stereoshift
    case serverLike
}

enum DepthTuning: String, CaseIterable, Sendable {
    case classic
    case enhanced
}

enum StereoViewSynthesis: String, CaseIterable, Sendable {
    case inverseWarp
    case forwardWarp
}

enum DepthRefinement: String, CaseIterable, Sendable {
    case none
    case guidedFilter
    case personMask
    case guidedFilterAndPersonMask
}

enum VideoDepthCadence: Int, CaseIterable, Sendable {
    case everyFrame = 1
    case every2Frames = 2
    case every4Frames = 4
}

struct Stereo3DOptions: Hashable, Sendable {
    // Keep using server-like generation (simple min/max depth normalize + integer pixel shifts).
    var generationMethod: StereoGenerationMethod = .serverLike
    // Fixed depth model choice (no in-app selector).
    var depthModel: DepthModel = .depthAnythingV2SmallF16
    var depthQuality: DepthQuality = .quality
    var renderEngine: StereoRenderEngine = .cpu
    var depthTuning: DepthTuning = .classic
    var viewSynthesis: StereoViewSynthesis = .inverseWarp
    var depthRefinement: DepthRefinement = .none
    var videoDepthCadence: VideoDepthCadence = .everyFrame
    // 0 disables smoothing. 0.25-0.5 can reduce flicker but may lag on fast motion.
    var videoDepthSmoothing: Float = 0
}
