import CoreImage
import ImageIO
import simd
import UIKit

/// Measures sideways travel relative to the first shot, with height anchored to gravity.
struct StereoCaptureGuide {
    static let targetDistance: Float = 0.064
    let horizontal: Float
    let vertical: Float
    let forward: Float
    let angleDegrees: Float

    init(origin: simd_float4x4, current: simd_float4x4) {
        let relative = simd_inverse(origin) * current
        let delta = SIMD3(current.columns.3.x - origin.columns.3.x,
                          current.columns.3.y - origin.columns.3.y,
                          current.columns.3.z - origin.columns.3.z)
        // ARKit's gravity-aligned world keeps Y vertical. Project screen-right onto
        // that horizontal plane so a tilted phone never asks the user to move uphill.
        let projectedRight = SIMD3(origin.columns.0.x, 0, origin.columns.0.z)
        let right = simd_length(projectedRight) > 0.01 ? simd_normalize(projectedRight) : SIMD3<Float>(1, 0, 0)
        horizontal = simd_dot(delta, right)
        vertical = delta.y
        forward = simd_dot(delta, simd_cross(right, SIMD3(0, 1, 0)))
        let rotation = simd_float3x3(
            SIMD3(relative.columns.0.x, relative.columns.0.y, relative.columns.0.z),
            SIMD3(relative.columns.1.x, relative.columns.1.y, relative.columns.1.z),
            SIMD3(relative.columns.2.x, relative.columns.2.y, relative.columns.2.z)
        )
        let cosine = (rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z - 1) / 2
        angleDegrees = acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    var isAligned: Bool { abs(vertical) <= 0.012 && abs(forward) <= 0.02 && angleDegrees <= 3 }
    var isAtTarget: Bool { abs(horizontal - Self.targetDistance) <= 0.01 }
    var isReady: Bool { isAligned && isAtTarget }
    var progress: Double { min(1, max(0, Double(horizontal / Self.targetDistance))) }
}

enum StereoCaptureImage {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func orientation(for interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch interfaceOrientation {
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }

    static func makeImage(from buffer: CVPixelBuffer, orientation: UIInterfaceOrientation) throws -> CGImage {
        try render(CIImage(cvPixelBuffer: buffer).oriented(Self.orientation(for: orientation)))
    }

    static func render(_ image: CIImage) throws -> CGImage {
        // Bound peak memory while keeping a detailed, full-colour stereo pair.
        let scale = min(1, 2560 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let output = context.createCGImage(scaled, from: scaled.extent.integral) else {
            throw StereoPipelineError.exportFailed
        }
        return output
    }
}
