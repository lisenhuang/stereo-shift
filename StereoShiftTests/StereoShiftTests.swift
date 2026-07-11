import CoreGraphics
import CoreVideo
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

    @Test func fixedDepthModelUsesItsEntireInputCanvas() {
        let target = DepthEstimator.IntSize(width: 518, height: 392)
        let portrait = DepthEstimator.computeFixedModelSizing(width: 3024, height: 4032, target: target)
        let widescreen = DepthEstimator.computeFixedModelSizing(width: 3840, height: 2160, target: target)

        #expect(portrait.model.width == 518)
        #expect(portrait.model.height == 392)
        #expect(portrait.scaled.width == 518)
        #expect(portrait.scaled.height == 392)
        #expect(widescreen.scaled.width == 518)
        #expect(widescreen.scaled.height == 392)
    }

    @Test func flatDepthProducesTwoUnshiftedEyes() throws {
        let width = 48
        let height = 24
        let rgb = try makePatternBuffer(width: width, height: height)
        let depth = try makeConstantDepthBuffer(width: width, height: height, value: 128)
        let renderer = StereoRenderer(depthEstimator: DepthEstimator())
        var options = Stereo3DOptions()
        options.renderEngine = .metal
        options.renderProfile = .quality

        let output = try renderer.makeSBS(
            from: rgb,
            depth: depth,
            strength: 1,
            options: options
        )

        #expect(CVPixelBufferGetWidth(output) == width * 2)
        #expect(CVPixelBufferGetHeight(output) == height)
        #expect(try bothEyes(in: output, match: rgb))
    }

    @Test func cpuFallbackAcceptsHalfFloatDepth() throws {
        let width = 40
        let height = 20
        let rgb = try makePatternBuffer(width: width, height: height)
        let depth = try makeHalfFloatDepthBuffer(width: width, height: height)
        let renderer = StereoRenderer(depthEstimator: DepthEstimator())
        var options = Stereo3DOptions()
        options.renderEngine = .cpu
        options.renderProfile = .ultraFast

        let output = try renderer.makeSBS(
            from: rgb,
            depth: depth,
            strength: 0.8,
            options: options
        )

        #expect(CVPixelBufferGetWidth(output) == width * 2)
        #expect(CVPixelBufferGetHeight(output) == height)
    }

    @Test func modelInferencePreservesNativeHalfFloatDepth() async throws {
        let rgb = try makePatternBuffer(width: 320, height: 480)
        let depth = try await DepthEstimator().predictDepth(
            pixelBuffer: rgb,
            model: .depthAnythingV2SmallF16,
            quality: .quality
        )

        #expect(CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_OneComponent16Half)
        #expect(CVPixelBufferGetWidth(depth) == 518)
        #expect(CVPixelBufferGetHeight(depth) == 392)

        let range = halfFloatRange(in: depth)
        #expect(range.minimum.isFinite)
        #expect(range.maximum.isFinite)
        #expect(range.maximum > range.minimum)

        let renderer = StereoRenderer(depthEstimator: DepthEstimator())
        var options = Stereo3DOptions()
        options.renderEngine = .metal
        options.renderProfile = .quality
        let output = try renderer.makeSBS(
            from: rgb,
            depth: depth,
            strength: 0.8,
            options: options
        )
        #expect(CVPixelBufferGetWidth(output) == 640)
        #expect(CVPixelBufferGetHeight(output) == 480)
    }

    @Test func qualityWarpResolvesOcclusionsWithoutForegroundHalos() throws {
        let width = 160
        let height = 48
        let fixture = try makeOcclusionFixture(width: width, height: height)
        let renderer = StereoRenderer(depthEstimator: DepthEstimator())
        var options = Stereo3DOptions()
        options.renderEngine = .metal
        options.renderProfile = .quality

        let output = try renderer.makeSBS(
            from: fixture.rgb,
            depth: fixture.depth,
            strength: 1.5,
            options: options
        )

        let row = height / 2
        let leftGap = pixel(in: output, x: 60, y: row)
        let leftOverlap = pixel(in: output, x: 100, y: row)
        let rightOverlap = pixel(in: output, x: width + 59, y: row)
        let rightGap = pixel(in: output, x: width + 99, y: row)

        #expect(isBlue(leftGap))
        #expect(isBlue(rightGap))
        #expect(isRed(leftOverlap))
        #expect(isRed(rightOverlap))
    }

    private func makePatternBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(
            to: UInt8.self,
            capacity: bytesPerRow * height
        )
        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8((x * 5) % 256)
                row[offset + 1] = UInt8((y * 11) % 256)
                row[offset + 2] = UInt8(((x + y) * 3) % 256)
                row[offset + 3] = 255
            }
        }
        return buffer
    }

    private func makeConstantDepthBuffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        let buffer = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_OneComponent8
        )

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(
            to: UInt8.self,
            capacity: bytesPerRow * height
        )
        for y in 0..<height {
            pointer.advanced(by: y * bytesPerRow).initialize(repeating: value, count: width)
        }
        return buffer
    }

    private func makeHalfFloatDepthBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_OneComponent16Half
        )

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt16>.stride
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(
            to: UInt16.self,
            capacity: stride * height
        )
        for y in 0..<height {
            let row = pointer.advanced(by: y * stride)
            for x in 0..<width {
                row[x] = Float16(Float(x) / Float(max(width - 1, 1))).bitPattern
            }
        }
        return buffer
    }

    private func makeOcclusionFixture(width: Int, height: Int) throws -> (rgb: CVPixelBuffer, depth: CVPixelBuffer) {
        let rgb = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        let depth = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_OneComponent8
        )

        CVPixelBufferLockBaseAddress(rgb, [])
        CVPixelBufferLockBaseAddress(depth, [])
        defer {
            CVPixelBufferUnlockBaseAddress(depth, [])
            CVPixelBufferUnlockBaseAddress(rgb, [])
        }

        let rgbBPR = CVPixelBufferGetBytesPerRow(rgb)
        let depthBPR = CVPixelBufferGetBytesPerRow(depth)
        let rgbPointer = CVPixelBufferGetBaseAddress(rgb)!.bindMemory(
            to: UInt8.self,
            capacity: rgbBPR * height
        )
        let depthPointer = CVPixelBufferGetBaseAddress(depth)!.bindMemory(
            to: UInt8.self,
            capacity: depthBPR * height
        )

        for y in 0..<height {
            let rgbRow = rgbPointer.advanced(by: y * rgbBPR)
            let depthRow = depthPointer.advanced(by: y * depthBPR)
            for x in 0..<width {
                let foreground = (60..<100).contains(x)
                let offset = x * 4
                rgbRow[offset] = foreground ? 0 : 255
                rgbRow[offset + 1] = 0
                rgbRow[offset + 2] = foreground ? 255 : 0
                rgbRow[offset + 3] = 255
                depthRow[x] = foreground ? 255 : 0
            }
        }
        return (rgb, depth)
    }

    private func bothEyes(in output: CVPixelBuffer, match source: CVPixelBuffer) throws -> Bool {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(output, .readOnly)
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let outputBase = CVPixelBufferGetBaseAddress(output) else {
            return false
        }

        let sourceBPR = CVPixelBufferGetBytesPerRow(source)
        let outputBPR = CVPixelBufferGetBytesPerRow(output)
        let sourcePointer = sourceBase.bindMemory(to: UInt8.self, capacity: sourceBPR * height)
        let outputPointer = outputBase.bindMemory(to: UInt8.self, capacity: outputBPR * height)

        for y in 0..<height {
            let sourceRow = sourcePointer.advanced(by: y * sourceBPR)
            let outputRow = outputPointer.advanced(by: y * outputBPR)
            for x in 0..<width {
                let sourceOffset = x * 4
                let leftOffset = sourceOffset
                let rightOffset = (x + width) * 4
                for channel in 0..<4 {
                    if outputRow[leftOffset + channel] != sourceRow[sourceOffset + channel]
                        || outputRow[rightOffset + channel] != sourceRow[sourceOffset + channel] {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func halfFloatRange(in buffer: CVPixelBuffer) -> (minimum: Float, maximum: Float) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt16>.stride
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(
            to: UInt16.self,
            capacity: stride * height
        )
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude

        for y in 0..<height {
            let row = pointer.advanced(by: y * stride)
            for x in 0..<width {
                let value = Float(Float16(bitPattern: row[x]))
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }
        return (minimum, maximum)
    }

    private func pixel(in buffer: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(
            to: UInt8.self,
            capacity: bytesPerRow * CVPixelBufferGetHeight(buffer)
        )
        let offset = (y * bytesPerRow) + (x * 4)
        return (pointer[offset], pointer[offset + 1], pointer[offset + 2], pointer[offset + 3])
    }

    private func isBlue(_ pixel: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> Bool {
        pixel.b >= 240 && pixel.g <= 15 && pixel.r <= 15 && pixel.a == 255
    }

    private func isRed(_ pixel: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> Bool {
        pixel.b <= 15 && pixel.g <= 15 && pixel.r >= 240 && pixel.a == 255
    }
}
