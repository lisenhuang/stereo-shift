import CoreML
import CoreVideo
import Foundation

/// How a model's primary depth output is encoded at the Core ML boundary.
///
/// Every model StereoShift can run declares one of these (compiled in, never read from
/// the network), and `DepthOutputAdapter` turns whatever the model emits into the single
/// buffer shape the rest of the pipeline consumes: `kCVPixelFormatType_OneComponent16Half`,
/// model resolution, values in [0, 1], larger = nearer.
struct DepthOutputSpec: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A Grayscale16Half image feature. Consumed as-is (Depth Anything V2 Core ML port).
        case image16Half
        /// An `MLMultiArray` feature whose last two dimensions are height × width.
        case multiArray
    }

    enum Convention: Hashable, Sendable {
        /// `relu(inverse depth) / max` — already in [0, 1], larger = nearer (Depth Anything V2).
        case normalizedInverseDepth
        /// Strictly positive depth, larger = FARTHER, unbounded (Depth Anything 3 exp head).
        /// Converted with a reciprocal, never with `1 - x`.
        case depthPositive
        /// Unbounded inverse depth / disparity, larger = nearer, not normalized.
        case inverseDepthUnbounded
    }

    /// Name of the output feature carrying depth. Secondary outputs (e.g. `confidence`)
    /// are ignored, so a two-output model can never be read nondeterministically.
    let featureName: String
    let kind: Kind
    let convention: Convention
}

/// Per-model renderer constants. The defaults reproduce the values tuned for
/// Depth Anything V2, so existing output is unchanged unless a model overrides them.
struct DepthModelTuning: Hashable, Sendable {
    /// Gamma applied to normalized depth in the Metal refine (1 = linear).
    var depthGamma: Float = 1.0
    /// Frame-to-frame change in the 2%/98% depth bounds above which the video temporal
    /// EMA snaps instead of damping (scene cuts, objects entering the frame).
    var temporalJumpThreshold: Float = 0.12
    /// Depth range (hi − lo) at which disparity reaches full strength; shallower scenes
    /// get proportionally less shift so quantization noise never becomes visible wobble.
    var rangeConfidenceScale: Float = 0.25

    static let standard = DepthModelTuning()
}

/// Converts any declared model output into the pipeline's canonical raw depth buffer.
///
/// Post-adapter invariant (what `RawDepthMap.depth` always is): OneComponent16Half,
/// model resolution, [0, 1], larger = nearer, self-owned and Metal-compatible. This is
/// exactly what `StereoRenderer.metalDepthStats`, the Metal refine kernel and
/// `VideoProcessor.blendRawDepth` already assume, so none of them need to know which
/// model family produced the depth.
enum DepthOutputAdapter {
    /// Percentile of the converted sample used as the normalization scale. V2 divides by
    /// the true max inside its graph; a very high percentile keeps a handful of exp-head
    /// outliers from crushing the rest of the range for models that don't.
    static let normalizationPercentile = 0.999
    static let targetSampleCount = 4096
    /// Minimum 2%–98% spread (after normalization) below which a map is treated as
    /// degenerate. A flat map would otherwise render as garbage stereo with no error.
    static let minimumUsableRange: Float = 1e-3
    /// Floor for positive depth before the reciprocal; fp16 exp heads can underflow to 0.
    static let minimumPositiveDepth: Float = 1e-6

    // MARK: Provider entry point

    static func canonicalDepth(from provider: MLFeatureProvider, spec: DepthOutputSpec) throws -> CVPixelBuffer {
        switch spec.kind {
        case .image16Half:
            guard let image = imageFeature(named: spec.featureName, in: provider) else {
                throw StereoPipelineError.modelContractViolation(
                    "output \"\(spec.featureName)\" is not an image feature (outputs: \(provider.featureNames.sorted()))"
                )
            }
            return try canonicalDepth(fromImage: image, convention: spec.convention)
        case .multiArray:
            guard let array = multiArrayFeature(named: spec.featureName, in: provider) else {
                throw StereoPipelineError.modelContractViolation(
                    "output \"\(spec.featureName)\" is not a multi-array feature (outputs: \(provider.featureNames.sorted()))"
                )
            }
            return try canonicalDepth(fromArray: array, convention: spec.convention)
        }
    }

    /// Checks a loaded model against its declared spec so a wrong file fails loudly at
    /// load/install time instead of producing inverted or flat stereo later.
    static func validateContract(model: MLModel, spec: DepthOutputSpec) throws {
        let description = model.modelDescription
        let imageInputs = description.inputDescriptionsByName.values.filter { $0.type == .image }
        guard imageInputs.count == 1,
              let constraint = imageInputs.first?.imageConstraint,
              constraint.pixelsWide > 0, constraint.pixelsHigh > 0 else {
            throw StereoPipelineError.modelContractViolation(
                "expected exactly one fixed-size image input (found \(imageInputs.count))"
            )
        }

        guard let output = description.outputDescriptionsByName[spec.featureName] else {
            throw StereoPipelineError.modelContractViolation(
                "output \"\(spec.featureName)\" not found (outputs: \(description.outputDescriptionsByName.keys.sorted()))"
            )
        }

        switch spec.kind {
        case .image16Half:
            guard output.type == .image else {
                throw StereoPipelineError.modelContractViolation("output \"\(spec.featureName)\" is not an image")
            }
            guard output.imageConstraint?.pixelFormatType == kCVPixelFormatType_OneComponent16Half else {
                throw StereoPipelineError.modelContractViolation("output \"\(spec.featureName)\" is not Grayscale16Half")
            }
        case .multiArray:
            guard output.type == .multiArray else {
                throw StereoPipelineError.modelContractViolation("output \"\(spec.featureName)\" is not a multi-array")
            }
        }
    }

    // MARK: Image outputs

    static func canonicalDepth(fromImage image: CVPixelBuffer, convention: DepthOutputSpec.Convention) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(image)
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width > 0, height > 0 else {
            throw StereoPipelineError.invalidDepthArrayShape
        }

        // Fast path (Depth Anything V2): already canonical. Hand the renderer a
        // self-owned copy — Core ML output buffers are reused between predictions and
        // are not guaranteed to be Metal-cache friendly.
        if format == kCVPixelFormatType_OneComponent16Half, convention == .normalizedInverseDepth {
            return try copyPixelBuffer(image)
        }

        var values = [Float](repeating: 0, count: width * height)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)

        switch format {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width)
                let dest = y * width
                for x in 0..<width {
                    values[dest + x] = Float(Float16(bitPattern: row[x]))
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: width)
                let dest = y * width
                for x in 0..<width {
                    values[dest + x] = Float(row[x]) / 255
                }
            }
        case kCVPixelFormatType_32BGRA:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: width * 4)
                let dest = y * width
                for x in 0..<width {
                    let offset = x * 4
                    values[dest + x] = ((0.299 * Float(row[offset + 2])) + (0.587 * Float(row[offset + 1])) + (0.114 * Float(row[offset]))) / 255
                }
            }
        default:
            throw StereoPipelineError.unsupportedModelOutput
        }

        return try makeCanonicalBuffer(values: &values, width: width, height: height, convention: convention)
    }

    // MARK: Multi-array outputs

    static func canonicalDepth(fromArray array: MLMultiArray, convention: DepthOutputSpec.Convention) throws -> CVPixelBuffer {
        let shape = array.shape.map { Int(truncating: $0) }
        guard shape.count >= 2 else {
            throw StereoPipelineError.invalidDepthArrayShape
        }
        // Leading dimensions (batch, channel) must be singleton: (1, H, W), (1, 1, H, W) or (H, W).
        guard shape.dropLast(2).allSatisfy({ $0 == 1 }) else {
            throw StereoPipelineError.invalidDepthArrayShape
        }

        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 0, height > 0 else {
            throw StereoPipelineError.invalidDepthArrayShape
        }
        let strides = array.strides.map { Int(truncating: $0) }
        let rowStride = strides[shape.count - 2]
        let columnStride = strides[shape.count - 1]

        var values = [Float](repeating: 0, count: width * height)
        let dataType = array.dataType
        array.withUnsafeBytes { raw in
            switch dataType {
            case .float16:
                let pointer = raw.bindMemory(to: UInt16.self)
                for y in 0..<height {
                    let rowBase = y * rowStride
                    let dest = y * width
                    for x in 0..<width {
                        values[dest + x] = Float(Float16(bitPattern: pointer[rowBase + (x * columnStride)]))
                    }
                }
            case .float32:
                let pointer = raw.bindMemory(to: Float.self)
                for y in 0..<height {
                    let rowBase = y * rowStride
                    let dest = y * width
                    for x in 0..<width {
                        values[dest + x] = pointer[rowBase + (x * columnStride)]
                    }
                }
            case .double:
                let pointer = raw.bindMemory(to: Double.self)
                for y in 0..<height {
                    let rowBase = y * rowStride
                    let dest = y * width
                    for x in 0..<width {
                        values[dest + x] = Float(pointer[rowBase + (x * columnStride)])
                    }
                }
            case .int32:
                let pointer = raw.bindMemory(to: Int32.self)
                for y in 0..<height {
                    let rowBase = y * rowStride
                    let dest = y * width
                    for x in 0..<width {
                        values[dest + x] = Float(pointer[rowBase + (x * columnStride)])
                    }
                }
            case .int8:
                let pointer = raw.bindMemory(to: Int8.self)
                for y in 0..<height {
                    let rowBase = y * rowStride
                    let dest = y * width
                    for x in 0..<width {
                        values[dest + x] = Float(pointer[rowBase + (x * columnStride)])
                    }
                }
            @unknown default:
                break
            }
        }

        return try makeCanonicalBuffer(values: &values, width: width, height: height, convention: convention)
    }

    // MARK: Shared conversion

    /// Applies the convention, scales robustly, checks for a degenerate map and writes
    /// a OneComponent16Half buffer. `values` is row-major width × height.
    static func makeCanonicalBuffer(
        values: inout [Float],
        width: Int,
        height: Int,
        convention: DepthOutputSpec.Convention
    ) throws -> CVPixelBuffer {
        let count = width * height
        guard values.count == count, count > 0 else {
            throw StereoPipelineError.invalidDepthArrayShape
        }

        switch convention {
        case .normalizedInverseDepth:
            break
        case .inverseDepthUnbounded:
            for index in 0..<count {
                let value = values[index]
                values[index] = value.isFinite ? max(value, 0) : .nan
            }
        case .depthPositive:
            // Reciprocal, NOT `1 - x`: linear inversion of depth compresses foreground
            // separation and exaggerates the background, which is what made the
            // February 2026 Depth Anything 3 experiment look flat and washed out.
            for index in 0..<count {
                let value = values[index]
                values[index] = value.isFinite ? 1 / max(value, minimumPositiveDepth) : .nan
            }
        }

        // Deterministic strided sample (no full sort) for the scale and the sanity check.
        let step = max(1, count / targetSampleCount)
        var sample: [Float] = []
        sample.reserveCapacity((count / step) + 1)
        var index = 0
        while index < count {
            let value = values[index]
            if value.isFinite {
                sample.append(value)
            }
            index += step
        }
        guard sample.count >= 4 else {
            throw StereoPipelineError.depthOutputDegenerate
        }
        sample.sort()

        let scale: Float
        switch convention {
        case .normalizedInverseDepth:
            scale = 1
        case .inverseDepthUnbounded, .depthPositive:
            scale = sample[percentileIndex(normalizationPercentile, count: sample.count)]
        }
        guard scale.isFinite, scale > 0 else {
            throw StereoPipelineError.depthOutputDegenerate
        }
        let inverseScale = 1 / scale

        let low = min(1, max(0, sample[percentileIndex(0.02, count: sample.count)] * inverseScale))
        let high = min(1, max(0, sample[percentileIndex(0.98, count: sample.count)] * inverseScale))
        guard high - low >= minimumUsableRange else {
            throw StereoPipelineError.depthOutputDegenerate
        }

        let output = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_OneComponent16Half
        )
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let base = CVPixelBufferGetBaseAddress(output) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width)
            let source = y * width
            for x in 0..<width {
                let value = values[source + x]
                let normalized = value.isFinite ? min(1, max(0, value * inverseScale)) : 0
                row[x] = Float16(normalized).bitPattern
            }
        }

        return output
    }

    static func copyPixelBuffer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let copy = try PixelBufferUtilities.makePixelBuffer(width: width, height: height, pixelFormat: format)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let copyBase = CVPixelBufferGetBaseAddress(copy) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let copyBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = min(sourceBytesPerRow, copyBytesPerRow)
        for y in 0..<height {
            memcpy(
                copyBase.advanced(by: y * copyBytesPerRow),
                sourceBase.advanced(by: y * sourceBytesPerRow),
                rowBytes
            )
        }
        return copy
    }

    // MARK: Helpers

    private static func percentileIndex(_ percentile: Double, count: Int) -> Int {
        max(0, min(count - 1, Int((Double(count - 1) * percentile).rounded(.down))))
    }

    private static func imageFeature(named name: String, in provider: MLFeatureProvider) -> CVPixelBuffer? {
        if let image = provider.featureValue(for: name)?.imageBufferValue {
            return image
        }
        // Tolerate a renamed output only when it is unambiguous.
        let images = provider.featureNames.compactMap { provider.featureValue(for: $0)?.imageBufferValue }
        return images.count == 1 ? images[0] : nil
    }

    private static func multiArrayFeature(named name: String, in provider: MLFeatureProvider) -> MLMultiArray? {
        if let array = provider.featureValue(for: name)?.multiArrayValue {
            return array
        }
        let arrays = provider.featureNames.compactMap { provider.featureValue(for: $0)?.multiArrayValue }
        return arrays.count == 1 ? arrays[0] : nil
    }
}
