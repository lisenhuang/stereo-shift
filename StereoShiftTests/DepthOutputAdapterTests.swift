import CoreML
import CoreVideo
import Testing
@testable import StereoShift

/// `DepthOutputAdapter` is the one place every model's output is normalized, so these
/// tests pin the invariant the whole Metal path relies on: OneComponent16Half, [0, 1],
/// larger = nearer, regardless of what the Core ML model emitted.
struct DepthOutputAdapterTests {
    private static let width = 8
    private static let height = 4

    // MARK: Helpers

    /// Row-major values → MLMultiArray with the given shape (last two dims = H × W).
    private static func makeArray(shape: [Int], dataType: MLMultiArrayDataType, values: (Int, Int) -> Float) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
        let leading = [NSNumber](repeating: 0, count: shape.count - 2)
        for y in 0..<height {
            for x in 0..<width {
                array[leading + [NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: values(x, y))
            }
        }
        return array
    }

    private static func readRow(_ buffer: CVPixelBuffer, y: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width)
        return (0..<width).map { Float(Float16(bitPattern: row[$0])) }
    }

    private static func make16HalfBuffer(values: (Int, Int) -> Float) throws -> CVPixelBuffer {
        let buffer = try PixelBufferUtilities.makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_OneComponent16Half)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width)
            for x in 0..<width {
                row[x] = Float16(values(x, y)).bitPattern
            }
        }
        return buffer
    }

    private static func isCanonical(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half
            && CVPixelBufferGetWidth(buffer) == width
            && CVPixelBufferGetHeight(buffer) == height
    }

    // MARK: Depth (larger = farther) → inverse depth (larger = nearer)

    @Test func positiveDepthRampBecomesNearestBrightest() throws {
        // Depth grows left → right, so the LEFT edge is nearest and must come out brightest.
        let array = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { x, _ in Float(x + 1) }
        let output = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .depthPositive)

        #expect(Self.isCanonical(output))
        let row = Self.readRow(output, y: 1)
        #expect(abs(row[0] - 1) < 0.002)
        for x in 1..<Self.width {
            #expect(row[x] < row[x - 1])
            #expect(row[x] >= 0 && row[x] <= 1)
        }
        // 1/8 relative to the nearest value 1/1.
        #expect(abs(row[Self.width - 1] - 0.125) < 0.002)
    }

    @Test func float16ArrayWithChannelDimensionIsAccepted() throws {
        let array = try Self.makeArray(shape: [1, 1, Self.height, Self.width], dataType: .float16) { x, _ in Float(x + 1) }
        let output = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .depthPositive)
        #expect(Self.isCanonical(output))
        let row = Self.readRow(output, y: 0)
        #expect(row[0] > row[Self.width - 1])
    }

    @Test func twoDimensionalArrayIsAccepted() throws {
        let array = try Self.makeArray(shape: [Self.height, Self.width], dataType: .double) { x, _ in Float(x + 1) }
        let output = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .depthPositive)
        #expect(Self.isCanonical(output))
    }

    @Test func nonFiniteDepthMapsToFarthest() throws {
        // Sky-like +inf depth must become 0 (farthest), never NaN in the buffer.
        let array = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { x, _ in
            x == Self.width - 1 ? Float.infinity : Float(x + 1)
        }
        let output = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .depthPositive)
        let row = Self.readRow(output, y: 2)
        #expect(row[Self.width - 1] == 0)
        #expect(row.allSatisfy { $0.isFinite })
    }

    @Test func unboundedInverseDepthIsScaledToUnitRange() throws {
        let array = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { x, _ in Float(x) * 10 }
        let output = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .inverseDepthUnbounded)
        let row = Self.readRow(output, y: 0)
        #expect(row[0] == 0)
        #expect(abs(row[Self.width - 1] - 1) < 0.002)
        for x in 1..<Self.width {
            #expect(row[x] > row[x - 1])
        }
    }

    // MARK: Degenerate output

    @Test func flatDepthMapThrows() throws {
        let array = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { _, _ in 3 }
        #expect(throws: StereoPipelineError.self) {
            _ = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .depthPositive)
        }
    }

    @Test func nonSingletonLeadingDimensionThrows() throws {
        let array = try MLMultiArray(shape: [2, Self.height, Self.width].map { NSNumber(value: $0) }, dataType: .float32)
        #expect(throws: StereoPipelineError.self) {
            _ = try DepthOutputAdapter.canonicalDepth(fromArray: array, convention: .depthPositive)
        }
    }

    // MARK: Image outputs

    @Test func grayscale16HalfPassthroughIsBitIdentical() throws {
        let source = try Self.make16HalfBuffer { x, y in Float(x + (y * Self.width)) / 64 }
        let output = try DepthOutputAdapter.canonicalDepth(fromImage: source, convention: .normalizedInverseDepth)

        #expect(Self.isCanonical(output))
        // A self-owned copy, not the model's reusable buffer.
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        #expect(CVPixelBufferGetBaseAddress(output) != CVPixelBufferGetBaseAddress(source))
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        for y in 0..<Self.height {
            #expect(Self.readRow(output, y: y) == Self.readRow(source, y: y))
        }
    }

    @Test func grayscale16HalfDepthIsInverted() throws {
        let source = try Self.make16HalfBuffer { x, _ in Float(x + 1) }
        let output = try DepthOutputAdapter.canonicalDepth(fromImage: source, convention: .depthPositive)
        let row = Self.readRow(output, y: 0)
        #expect(abs(row[0] - 1) < 0.002)
        #expect(row[Self.width - 1] < row[0])
    }

    // MARK: Feature selection

    @Test func providerPicksDepthOutputByName() throws {
        // A confidence tensor is flat; if the adapter picked it, the result would throw
        // as degenerate. Picking `depth` by name yields the ramp.
        let depth = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { x, _ in Float(x + 1) }
        let confidence = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { _, _ in 1.5 }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "confidence": MLFeatureValue(multiArray: confidence),
            "depth": MLFeatureValue(multiArray: depth)
        ])
        let spec = DepthOutputSpec(featureName: "depth", kind: .multiArray, convention: .depthPositive)
        let output = try DepthOutputAdapter.canonicalDepth(from: provider, spec: spec)
        let row = Self.readRow(output, y: 0)
        #expect(row[0] > row[Self.width - 1])
    }

    @Test func missingNamedOutputWithAmbiguousCandidatesThrows() throws {
        let a = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { x, _ in Float(x + 1) }
        let b = try Self.makeArray(shape: [1, Self.height, Self.width], dataType: .float32) { x, _ in Float(x + 2) }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "var_1": MLFeatureValue(multiArray: a),
            "var_2": MLFeatureValue(multiArray: b)
        ])
        let spec = DepthOutputSpec(featureName: "depth", kind: .multiArray, convention: .depthPositive)
        #expect(throws: StereoPipelineError.self) {
            _ = try DepthOutputAdapter.canonicalDepth(from: provider, spec: spec)
        }
    }

    @Test func modelTuningDefaultsMatchLegacyConstants() {
        let tuning = DepthModel.bundledDefault.tuning
        #expect(tuning.depthGamma == 1.0)
        #expect(tuning.temporalJumpThreshold == 0.12)
        #expect(tuning.rangeConfidenceScale == 0.25)
        #expect(DepthModel.bundledDefault.isBundled)
        #expect(DepthModel.bundledDefault.outputSpec.kind == .image16Half)
    }
}
