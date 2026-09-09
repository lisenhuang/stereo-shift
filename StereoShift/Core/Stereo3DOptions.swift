import CoreML
import Foundation

/// Depth models StereoShift knows how to run. Output semantics and tuning are compiled
/// in (never read from a downloaded catalog) so a bad catalog entry can never invert
/// or flatten the stereo. The catalog only supplies download URLs, hashes, sizes,
/// requirements and visibility flags for the non-bundled cases.
enum DepthModel: String, CaseIterable, Sendable, Identifiable {
    case depthAnythingV2SmallF16 = "DepthAnythingV2SmallF16"
    case depthAnythingV3SmallF16 = "DepthAnythingV3SmallF16"
    case depthAnythingV3BaseF16 = "DepthAnythingV3BaseF16"
    case depthAnythingV3MonoLargeF16 = "DepthAnythingV3MonoLargeF16"

    /// The model shipped inside the app bundle. Always available; selection falls
    /// back to it whenever a downloaded model is missing or fails to load.
    static let bundledDefault: DepthModel = .depthAnythingV2SmallF16

    var id: String { rawValue }

    /// Neutral names on purpose: no quality claims until the A/B says otherwise.
    var displayName: String {
        switch self {
        case .depthAnythingV2SmallF16:
            return "Depth Anything V2 · Small"
        case .depthAnythingV3SmallF16:
            return "Depth Anything 3 · Small"
        case .depthAnythingV3BaseF16:
            return "Depth Anything 3 · Base"
        case .depthAnythingV3MonoLargeF16:
            return "Depth Anything 3 Mono · Large"
        }
    }

    var isBundled: Bool {
        self == .depthAnythingV2SmallF16
    }

    /// Bundle resource names accepted for this model. Includes the public Core ML port
    /// package names so a package dropped into Resources works for local testing.
    var resourceNameCandidates: [String] {
        switch self {
        case .depthAnythingV2SmallF16:
            return [
                "DepthAnythingV2SmallF16",
                "DepthAnythingV2SmallFP16",
                "coreml-depth-anything-v2-small"
            ]
        case .depthAnythingV3SmallF16:
            return [
                "DepthAnythingV3SmallF16",
                "DepthAnythingV3_small_504",
                "coreml-depth-anything-v3-small"
            ]
        case .depthAnythingV3BaseF16:
            return [
                "DepthAnythingV3BaseF16",
                "DepthAnythingV3_base_504",
                "coreml-depth-anything-v3-base"
            ]
        case .depthAnythingV3MonoLargeF16:
            return [
                "DepthAnythingV3MonoLargeF16",
                "DepthAnythingV3Mono",
                "coreml-depth-anything-v3-mono-large"
            ]
        }
    }

    /// How the model's Core ML output is encoded; `DepthOutputAdapter` normalizes it.
    var outputSpec: DepthOutputSpec {
        switch self {
        case .depthAnythingV2SmallF16:
            // Apple's port: Grayscale16Half image, relu(disparity)/max, larger = nearer.
            return DepthOutputSpec(featureName: "depth", kind: .image16Half, convention: .normalizedInverseDepth)
        case .depthAnythingV3SmallF16, .depthAnythingV3BaseF16, .depthAnythingV3MonoLargeF16:
            // Community ports: MLMultiArray of exponential depth, larger = farther.
            return DepthOutputSpec(featureName: "depth", kind: .multiArray, convention: .depthPositive)
        }
    }

    /// Renderer constants for this model. V2 values for all models until measured.
    var tuning: DepthModelTuning {
        .standard
    }

    /// Compute units to try first for this model; nil keeps the device default order.
    var preferredComputeUnits: MLComputeUnits? {
        nil
    }

    /// True when the model can be loaded right now: bundled, dropped into Resources,
    /// or installed by the user.
    var isInstalled: Bool {
        if isBundled {
            return true
        }
        if DepthModelLibrary.installedCompiledModelURL(for: self) != nil {
            return true
        }
        return isAvailableInBundle
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
    case fast = 280
    case quality = 518

    var shortSide: Int { rawValue }
}

enum StereoRenderEngine: String, CaseIterable, Sendable {
    case metal
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
    var depthModel: DepthModel = .bundledDefault
    // Always keep Ultra Fast as the user-facing default. The renderer can still auto-enable
    // additional edge processing internally at high strength.
    var renderProfile: StereoRenderProfile = .ultraFast
    var depthQuality: DepthQuality = .quality
    var renderEngine: StereoRenderEngine = .metal
    var depthTuning: DepthTuning = .classic
    var viewSynthesis: StereoViewSynthesis = .inverseWarp
    var depthRefinement: DepthRefinement = .none
    var videoDepthCadence: VideoDepthCadence = .everyFrame
    // 0 disables smoothing. 0.25-0.5 can reduce flicker but may lag on fast motion.
    var videoDepthSmoothing: Float = 0
}
