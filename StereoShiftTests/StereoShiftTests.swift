import CoreGraphics
import Testing
@testable import StereoShift

struct StereoShiftTests {
    @Test func processingSizeRespects720pLimit() async throws {
        let size = VideoProcessor.processingSize(for: CGSize(width: 1920, height: 1080), maxDimension: 720)

        #expect(size.width == 720)
        #expect(size.height == 404)
    }

    @Test func disparityScalesWithResolution() async throws {
        let reference = StereoRenderer.maxDisparity(forWidth: 720)
        let larger = StereoRenderer.maxDisparity(forWidth: 1280)
        let minimum = StereoRenderer.maxDisparity(forWidth: 120)

        #expect(reference == 24)
        #expect(larger > reference)
        #expect(larger <= 56)
        #expect(minimum >= 8)
    }
}
