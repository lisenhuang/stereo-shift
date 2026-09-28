import CoreGraphics
import CoreVideo
import Testing
@testable import StereoShift

struct StereoFocusDotsTests {
    @Test func disabledKeepsOriginalBuffer() throws {
        let source = try makeSource(width: 400, height: 100)
        let output = try StereoFocusDots.addingIfEnabled(to: source, enabled: false)
        #expect(output === source)
        #expect(Stereo3DOptions().focusDotsEnabled == false)
    }

    @Test(arguments: [CGSize(width: 800, height: 200), CGSize(width: 400, height: 400)])
    func dotsStayAboveUnchangedViews(size: CGSize) throws {
        let width = Int(size.width)
        let height = Int(size.height)
        let source = try makeSource(width: width, height: height)
        let output = try StereoFocusDots.addingIfEnabled(to: source, enabled: true)
        let stripHeight = 16
        #expect(CVPixelBufferGetWidth(output) == width)
        #expect(CVPixelBufferGetHeight(output) == height + stripHeight)
        #expect(StereoFocusDots.outputHeight(width: width, height: height, enabled: true) == height + stripHeight)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(output, .readOnly)
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let sourceBase = try #require(CVPixelBufferGetBaseAddress(source))
        let outputBase = try #require(CVPixelBufferGetBaseAddress(output))
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        for row in 0..<height {
            #expect(memcmp(sourceBase.advanced(by: row * sourceStride),
                           outputBase.advanced(by: (row + stripHeight) * outputStride), width * 4) == 0)
        }
        func pixel(x: Int, y: Int) -> UInt32 {
            outputBase.advanced(by: y * outputStride + x * 4).load(as: UInt32.self)
        }
        #expect(pixel(x: width / 4, y: stripHeight / 2) == 0xFFFFFFFF)
        #expect(pixel(x: width * 3 / 4, y: stripHeight / 2) == 0xFFFFFFFF)
        #expect(pixel(x: width / 2, y: stripHeight / 2) == 0xFF000000)
        #expect(pixel(x: width / 4, y: 0) == 0xFF000000)
        #expect(pixel(x: width / 4, y: stripHeight - 1) == 0xFF000000)
    }

    @Test func geometryScalesWithResolution() {
        let small = StereoFocusDots.Layout(width: 800, height: 200)
        let large = StereoFocusDots.Layout(width: 2400, height: 600)
        #expect(large.dotDiameter == small.dotDiameter * 3)
        #expect(large.stripHeight == small.stripHeight * 3)
        #expect(large.leftCenterX == small.leftCenterX * 3)
        #expect(large.rightCenterX == small.rightCenterX * 3)
        for height in [2, 124, 202, 718, 1080] {
            #expect(StereoFocusDots.outputHeight(width: 1280, height: height, enabled: true) % 2 == 0)
        }
    }

    @Test func spatialPhotoUsesOptionalStrip() throws {
        let source = try makeSource(width: 200, height: 100)
        let eye = try PixelBufferUtilities.makeCGImage(from: source)
        let pair = StereoImagePair(left: eye, right: eye)
        let plain = try SpatialMediaConverter.makeSBSImage(from: pair)
        let decorated = try SpatialMediaConverter.makeSBSImage(from: pair, focusDotsEnabled: true)
        #expect(plain.width == 400)
        #expect(plain.height == 100)
        #expect(decorated.width == 400)
        #expect(decorated.height == 108)
    }

    private func makeSource(width: Int, height: Int) throws -> CVPixelBuffer {
        let source = try PixelBufferUtilities.makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(source, [])
        defer { CVPixelBufferUnlockBaseAddress(source, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(source))
        let stride = CVPixelBufferGetBytesPerRow(source)
        for row in 0..<height {
            let pixels = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
            for column in 0..<width {
                pixels[column] = 0xFF000000 | UInt32(row % 256) << 8 | UInt32(column % 256)
            }
        }
        return source
    }
}
