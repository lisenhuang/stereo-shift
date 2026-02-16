import Foundation

enum DepthModel: String, CaseIterable, Sendable {
    case depthAnythingV2SmallF16 = "DepthAnythingV2SmallF16"
    case depthAnythingV2SmallF32 = "DepthAnythingV2SmallF32"

    var displayName: String {
        switch self {
        case .depthAnythingV2SmallF16:
            return "Depth Anything v2 Small F16"
        case .depthAnythingV2SmallF32:
            return "Depth Anything v2 Small F32"
        }
    }

    var resourceNameCandidates: [String] {
        switch self {
        case .depthAnythingV2SmallF16:
            return [
                "DepthAnythingV2SmallF16",
                "DepthAnythingV2SmallFP16",
                "coreml-depth-anything-v2-small"
            ]
        case .depthAnythingV2SmallF32:
            return [
                "DepthAnythingV2SmallF32",
                "DepthAnythingV2SmallFP32",
                "coreml-depth-anything-v2-small-f32",
                "coreml-depth-anything-v2-small-fp32"
            ]
        }
    }

    var isAvailableInBundle: Bool {
        let names = Set(resourceNameCandidates)

        for name in resourceNameCandidates {
            if Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil {
                return true
            }
            if Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Resources") != nil {
                return true
            }
            if Bundle.main.url(forResource: name, withExtension: "mlpackage") != nil {
                return true
            }
            if Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Resources") != nil {
                return true
            }
        }

        guard let resourcesURL = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(at: resourcesURL, includingPropertiesForKeys: nil) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension
            guard ext == "mlmodelc" || ext == "mlpackage" else {
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            if names.contains(name) {
                return true
            }
        }

        return false
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

enum StereoRenderProfile: String, CaseIterable, Sendable {
    case ultraFast
    case quality
}

struct Stereo3DOptions: Hashable, Sendable {
    // Keep using server-like generation (simple min/max depth normalize + integer pixel shifts).
    var generationMethod: StereoGenerationMethod = .serverLike
    // User-selectable model. F16 remains the default.
    var depthModel: DepthModel = .depthAnythingV2SmallF16
    var renderProfile: StereoRenderProfile = .ultraFast
    var depthQuality: DepthQuality = .quality
    var renderEngine: StereoRenderEngine = .cpu
    var depthTuning: DepthTuning = .classic
    var viewSynthesis: StereoViewSynthesis = .inverseWarp
    var depthRefinement: DepthRefinement = .none
    var videoDepthCadence: VideoDepthCadence = .everyFrame
    // 0 disables smoothing. 0.25-0.5 can reduce flicker but may lag on fast motion.
    var videoDepthSmoothing: Float = 0
}
