import CoreImage
import Testing
import UIKit
import simd
@testable import StereoShift

struct StereoCaptureTests {
    @Test func onlyRightwardTranslationReachesTarget() {
        let origin = matrix_identity_float4x4
        #expect(guide(x: 0.064).isReady)
        #expect(!guide(x: -0.064).isReady)
        #expect(!guide(x: 0).isReady)
        #expect(!guide(x: 0.09).isReady)
        #expect(!guide(x: 0.064, y: 0.025).isReady)
        #expect(!guide(x: 0.064, z: 0.04).isReady)
        var turned = simd_float4x4(simd_quatf(angle: .pi / 18, axis: SIMD3(0, 1, 0)))
        turned.columns.3.x = 0.064
        #expect(!StereoCaptureGuide(origin: origin, current: turned).isReady)
    }

    @Test func distanceUsesFirstShotAxesInAnyOrientation() {
        // Turning to face another direction must still preserve screen-right guidance.
        var origin = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        origin.columns.3 = SIMD4(4, 2, -3, 1)
        var localMovement = matrix_identity_float4x4
        localMovement.columns.3.x = 0.064
        let guide = StereoCaptureGuide(origin: origin, current: origin * localMovement)
        #expect(guide.isReady)
        #expect(abs(guide.horizontal - 0.064) < 0.0001)
        #expect(abs(guide.vertical) < 0.0001)
    }

    @Test func tiltedPhoneStillRequestsHorizontalTravel() {
        let origin = simd_float4x4(simd_quatf(angle: .pi / 9, axis: SIMD3(0, 0, 1)))
        var current = origin
        current.columns.3.x = 0.064
        #expect(StereoCaptureGuide(origin: origin, current: current).isReady)
        current.columns.3.y = 0.03
        #expect(!StereoCaptureGuide(origin: origin, current: current).isReady)
    }

    @Test func progressDoesNotOverflowOrGoNegative() {
        #expect(guide(x: -0.05).progress == 0)
        #expect(guide(x: 0.2).progress == 1)
        #expect(abs(guide(x: 0.032).progress - 0.5) < 0.0001)
    }

    @Test func captureOrientationMatchesRearCameraSensor() throws {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
        for orientation in [UIInterfaceOrientation.portrait, .portraitUpsideDown] {
            let result = try StereoCaptureImage.render(image.oriented(StereoCaptureImage.orientation(for: orientation)))
            #expect(result.width == 60)
            #expect(result.height == 80)
        }
        for orientation in [UIInterfaceOrientation.landscapeLeft, .landscapeRight] {
            let result = try StereoCaptureImage.render(image.oriented(StereoCaptureImage.orientation(for: orientation)))
            #expect(result.width == 80)
            #expect(result.height == 60)
        }
        #expect(StereoCaptureImage.orientation(for: .portrait) == .right)
        #expect(StereoCaptureImage.orientation(for: .landscapeRight) == .up)
    }

    @Test func stereoExportKeepsLeftAndRightInOrder() throws {
        let rect = CGRect(x: 0, y: 0, width: 80, height: 60)
        let left = try StereoCaptureImage.render(CIImage(color: .red).cropped(to: rect))
        let right = try StereoCaptureImage.render(CIImage(color: .blue).cropped(to: rect))
        let image = try SpatialMediaConverter.makeSBSImage(from: StereoImagePair(left: left, right: right))
        #expect(image.width == 160)
        #expect(image.height == 60)
        let context = CIContext()
        var leftPixel = [UInt8](repeating: 0, count: 4)
        var rightPixel = leftPixel
        context.render(CIImage(cgImage: image), toBitmap: &leftPixel, rowBytes: 4,
                       bounds: CGRect(x: 20, y: 20, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        context.render(CIImage(cgImage: image), toBitmap: &rightPixel, rowBytes: 4,
                       bounds: CGRect(x: 120, y: 20, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        #expect(leftPixel[0] > 240 && leftPixel[2] < 15)
        #expect(rightPixel[2] > 240 && rightPixel[0] < 15)
    }

    @Test func largeCaptureHasBoundedMemoryAndPreservedAspectRatio() throws {
        let image = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 4032, height: 3024))
        let result = try StereoCaptureImage.render(image)
        #expect(result.width == 2560)
        #expect(result.height == 1920)
    }

    private func guide(x: Float, y: Float = 0, z: Float = 0) -> StereoCaptureGuide {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(x, y, z, 1)
        return StereoCaptureGuide(origin: matrix_identity_float4x4, current: pose)
    }
}
