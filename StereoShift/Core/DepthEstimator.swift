import CoreImage
import CoreML
import Foundation

actor DepthEstimator {
    struct IntSize {
        var width: Int
        var height: Int
    }

    private struct PreprocessMetadata {
        let modelSize: IntSize
        let contentRect: CGRect
    }

    private let longSideMultiple: Int = 14

    private var loadedModels: [DepthModel: MLModel] = [:]
    private var loadedComputeUnits: [DepthModel: MLComputeUnits] = [:]
    private var compiledModelURLs: [URL: URL] = [:]
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func predictDepth(pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        try await predictDepth(
            pixelBuffer: pixelBuffer,
            model: .depthAnythingV2SmallF16,
            quality: .quality
        )
    }

    func predictDepth(pixelBuffer: CVPixelBuffer, model: DepthModel, quality: DepthQuality) async throws -> CVPixelBuffer {
        let depthModel = model
        var model = try loadModel(depthModel)
        let prepared = try preprocess(pixelBuffer, depthModel: depthModel, model: model, quality: quality)
        var rawDepth = try await predictRawDepth(prepared.pixelBuffer, model: model)

        // Some accelerator/runtime combinations can complete successfully while returning
        // an all-zero image. The packaged model normalizes every useful prediction to a
        // non-zero maximum, so retry once on CPU instead of silently generating flat 3D.
        if !hasUsableDepthSignal(rawDepth), loadedComputeUnits[depthModel] != .cpuOnly {
            model = try loadCPUModel(depthModel)
            rawDepth = try await predictRawDepth(prepared.pixelBuffer, model: model)
        }

        rawDepth = try invertDepthIfNeeded(rawDepth, model: depthModel)
        let depth = try postprocess(depth: rawDepth, metadata: prepared.metadata)
        return depth
    }

    private func predictRawDepth(_ pixelBuffer: CVPixelBuffer, model: MLModel) async throws -> CVPixelBuffer {
        let provider = try featureProvider(for: pixelBuffer, model: model)
        let prediction = try await Task.detached(priority: .userInitiated) {
            try model.prediction(from: provider)
        }.value
        return try depthOutput(from: prediction)
    }

    private func invertDepthIfNeeded(_ depth: CVPixelBuffer, model: DepthModel) throws -> CVPixelBuffer {
        // Only Depth Anything v2 Small F16 is packaged. Keep hook for future model variants.
        _ = model
        return depth
    }

    private func loadModel(_ depthModel: DepthModel) throws -> MLModel {
        if let model = loadedModels[depthModel] {
            return model
        }

        guard let modelURL = try locateModelURL(depthModel) else {
            throw StereoPipelineError.modelNotFound
        }

        var lastError: Error?

        for computeUnits in preferredComputeUnitOrder {
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = computeUnits
                let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
                loadedModels[depthModel] = loadedModel
                loadedComputeUnits[depthModel] = computeUnits
                return loadedModel
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw StereoPipelineError.modelNotFound
    }

    private func loadCPUModel(_ depthModel: DepthModel) throws -> MLModel {
        guard let modelURL = try locateModelURL(depthModel) else {
            throw StereoPipelineError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        loadedModels[depthModel] = model
        loadedComputeUnits[depthModel] = .cpuOnly
        return model
    }

    private func hasUsableDepthSignal(_ depth: CVPixelBuffer) -> Bool {
        let sourceWidth = CVPixelBufferGetWidth(depth)
        let sourceHeight = CVPixelBufferGetHeight(depth)
        guard sourceWidth > 0, sourceHeight > 0 else { return false }

        let width = min(32, sourceWidth)
        let height = min(32, sourceHeight)
        guard let analysis = try? PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_OneComponent8
        ) else { return false }

        let image = CIImage(cvPixelBuffer: depth)
        let scaled = image
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / max(image.extent.width, 1),
                y: CGFloat(height) / max(image.extent.height, 1)
            ))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        ciContext.render(
            scaled,
            to: analysis,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceGray()
        )

        CVPixelBufferLockBaseAddress(analysis, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(analysis, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(analysis) else { return false }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(analysis)
        let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width where row[x] > 1 {
                return true
            }
        }
        return false
    }

    private var preferredComputeUnitOrder: [MLComputeUnits] {
#if targetEnvironment(macCatalyst)
        return computeUnitOrderForMacRuntime
#else
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return computeUnitOrderForMacRuntime
        }
        let devices = availableComputeDevices
        var order: [MLComputeUnits] = []
        if devices.hasNeuralEngine {
            order.append(.cpuAndNeuralEngine)
        }
        if devices.hasGPU {
            order.append(.cpuAndGPU)
        }
        order.append(.cpuOnly)
        return order
#endif
    }

    private var computeUnitOrderForMacRuntime: [MLComputeUnits] {
        let devices = availableComputeDevices
        if devices.hasGPU {
            return [.cpuAndGPU, .cpuOnly]
        }
        return [.cpuOnly]
    }

    private var availableComputeDevices: (hasNeuralEngine: Bool, hasGPU: Bool) {
        if #available(iOS 17.0, macOS 14.0, *) {
            var hasNeuralEngine = false
            var hasGPU = false

            for device in MLModel.availableComputeDevices {
                switch device {
                case .neuralEngine:
                    hasNeuralEngine = true
                case .gpu:
                    hasGPU = true
                case .cpu:
                    break
                @unknown default:
                    break
                }
            }

            return (hasNeuralEngine, hasGPU)
        }
        return (false, false)
    }

    private func locateModelURL(_ depthModel: DepthModel) throws -> URL? {
        let candidateNames = Set(depthModel.resourceNameCandidates)

        for name in depthModel.resourceNameCandidates {
            if let direct = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                return direct
            }
            if let subdirectory = Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Resources") {
                return subdirectory
            }
        }

        for name in depthModel.resourceNameCandidates {
            if let packageURL = Bundle.main.url(forResource: name, withExtension: "mlpackage")
                ?? Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Resources") {
                let compiled = try compilePackageIfNeeded(at: packageURL)
                return compiled
            }
        }

        guard let resourcesURL = Bundle.main.resourceURL else {
            return nil
        }

        let enumerator = FileManager.default.enumerator(at: resourcesURL, includingPropertiesForKeys: nil)
        var mlpackageURL: URL?

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "mlmodelc" {
                let name = url.deletingPathExtension().lastPathComponent
                if candidateNames.contains(name) {
                    return url
                }
            }
            if mlpackageURL == nil, url.pathExtension == "mlpackage" {
                let name = url.deletingPathExtension().lastPathComponent
                if candidateNames.contains(name) {
                    mlpackageURL = url
                }
            }
        }

        if let mlpackageURL {
            return try compilePackageIfNeeded(at: mlpackageURL)
        }

        return nil
    }

    private func compilePackageIfNeeded(at packageURL: URL) throws -> URL {
        if let compiledModelURL = compiledModelURLs[packageURL] {
            return compiledModelURL
        }
        let compiled = try MLModel.compileModel(at: packageURL)
        compiledModelURLs[packageURL] = compiled
        return compiled
    }

    private func featureProvider(for pixelBuffer: CVPixelBuffer, model: MLModel) throws -> MLFeatureProvider {
        guard let inputName = imageInputName(for: model) else {
            throw StereoPipelineError.modelInputNotFound
        }

        let value = MLFeatureValue(pixelBuffer: pixelBuffer)
        return try MLDictionaryFeatureProvider(dictionary: [inputName: value])
    }

    private func depthOutput(from provider: MLFeatureProvider) throws -> CVPixelBuffer {
        for name in provider.featureNames {
            if let imageBuffer = provider.featureValue(for: name)?.imageBufferValue {
                return imageBuffer
            }
        }

        for name in provider.featureNames {
            if let array = provider.featureValue(for: name)?.multiArrayValue {
                return try pixelBuffer(from: array)
            }
        }

        throw StereoPipelineError.modelOutputNotFound
    }

    private func pixelBuffer(from array: MLMultiArray) throws -> CVPixelBuffer {
        let shape = array.shape.map { Int(truncating: $0) }
        guard shape.count >= 2 else {
            throw StereoPipelineError.invalidDepthArrayShape
        }

        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        let strides = array.strides.map { Int(truncating: $0) }
        let rowStride = strides[shape.count - 2]
        let columnStride = strides[shape.count - 1]

        var values = [Float](repeating: 0, count: width * height)
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude

        for y in 0..<height {
            for x in 0..<width {
                let linearIndex = (y * rowStride) + (x * columnStride)
                let value = valueFromMultiArray(array, linearIndex: linearIndex)
                values[(y * width) + x] = value
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
            }
        }

        // Depth Anything v3 (and other depth models that output MLMultiArray) can produce occasional
        // extreme outliers. Using raw min/max can collapse useful depth contrast (especially for
        // Float32 models) and make results look worse than Float16. Use percentile clipping to
        // stabilize normalization.
        var normalizedMin = minValue
        var normalizedMax = maxValue

        if values.count > 0 {
            // Deterministic sampling for performance (avoids sorting the full depth map).
            let targetSamples = 4096
            let step = max(1, values.count / max(1, targetSamples))
            var sample: [Float] = []
            sample.reserveCapacity(min(targetSamples, values.count))

            var i = 0
            while i < values.count {
                sample.append(values[i])
                i += step
            }

            if sample.count >= 4 {
                sample.sort()
                // Float32 models tend to exhibit larger outliers than Float16. Use a wider clip.
                let lowPercentile: Double = array.dataType == .float32 ? 0.005 : 0.01
                let highPercentile: Double = array.dataType == .float32 ? 0.995 : 0.99
                let lowIndex = max(0, min(sample.count - 1, Int((Double(sample.count - 1) * lowPercentile).rounded(.down))))
                let highIndex = max(0, min(sample.count - 1, Int((Double(sample.count - 1) * highPercentile).rounded(.down))))
                let low = sample[lowIndex]
                let high = sample[highIndex]

                if low.isFinite, high.isFinite, high > low {
                    normalizedMin = low
                    normalizedMax = high
                }
            }
        }

        let range = max(normalizedMax - normalizedMin, 0.0001)
        let pixelBuffer = try PixelBufferUtilities.makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_OneComponent8)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let value = values[(y * width) + x]
                let clipped = max(normalizedMin, min(normalizedMax, value))
                let normalized = (clipped - normalizedMin) / range
                row[x] = UInt8(max(0, min(255, Int((normalized * 255).rounded()))))
            }
        }

        return pixelBuffer
    }

    private func valueFromMultiArray(_ array: MLMultiArray, linearIndex: Int) -> Float {
        switch array.dataType {
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            return Float(pointer[linearIndex])
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            return pointer[linearIndex]
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            return Float(Float16(bitPattern: pointer[linearIndex]))
        case .int32:
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
            return Float(pointer[linearIndex])
        case .int8:
            let pointer = array.dataPointer.bindMemory(to: Int8.self, capacity: array.count)
            return Float(pointer[linearIndex])
        @unknown default:
            return 0
        }
    }

    private func preprocess(
        _ sourcePixelBuffer: CVPixelBuffer,
        depthModel: DepthModel,
        model: MLModel,
        quality: DepthQuality
    ) throws -> (pixelBuffer: CVPixelBuffer, metadata: PreprocessMetadata) {
        let sourceWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourcePixelBuffer)

        let sourceShortSide = min(max(sourceWidth, 1), max(sourceHeight, 1))
        let desiredShortSide = min(quality.shortSide, sourceShortSide)
        let effectiveShortSide = max(longSideMultiple, Self.roundDown(desiredShortSide, multiple: longSideMultiple))

        let modelSizes: (model: IntSize, scaled: IntSize)
        if let fixedInput = modelInputSize(for: model) {
            modelSizes = Self.computeFixedModelSizing(width: sourceWidth, height: sourceHeight, target: fixedInput)
        } else {
            modelSizes = Self.computeModelSizing(
                width: sourceWidth,
                height: sourceHeight,
                shortSide: effectiveShortSide,
                longMultiple: longSideMultiple
            )
        }

        let modelPixelBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: modelSizes.model.width,
            height: modelSizes.model.height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
        let sx = CGFloat(modelSizes.scaled.width) / sourceImage.extent.width
        let sy = CGFloat(modelSizes.scaled.height) / sourceImage.extent.height
        let scaled = sourceImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // No model-specific preprocessing needed for the packaged model.

        let offsetX = CGFloat(modelSizes.model.width - modelSizes.scaled.width) * 0.5
        let offsetY = CGFloat(modelSizes.model.height - modelSizes.scaled.height) * 0.5
        let translated = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        let rendered = translated.cropped(to: CGRect(x: 0, y: 0, width: modelSizes.model.width, height: modelSizes.model.height))

        ciContext.render(
            rendered,
            to: modelPixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: modelSizes.model.width, height: modelSizes.model.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let metadata = PreprocessMetadata(
            modelSize: modelSizes.model,
            contentRect: CGRect(
                x: offsetX,
                y: offsetY,
                width: CGFloat(modelSizes.scaled.width),
                height: CGFloat(modelSizes.scaled.height)
            )
        )

        return (modelPixelBuffer, metadata)
    }

    private func postprocess(depth rawDepth: CVPixelBuffer, metadata: PreprocessMetadata) throws -> CVPixelBuffer {
        let rawWidth = CVPixelBufferGetWidth(rawDepth)
        let rawHeight = CVPixelBufferGetHeight(rawDepth)

        let sx = CGFloat(rawWidth) / CGFloat(metadata.modelSize.width)
        let sy = CGFloat(rawHeight) / CGFloat(metadata.modelSize.height)

        let mappedRect = CGRect(
            x: metadata.contentRect.origin.x * sx,
            y: metadata.contentRect.origin.y * sy,
            width: metadata.contentRect.width * sx,
            height: metadata.contentRect.height * sy
        ).integral

        if CVPixelBufferGetPixelFormatType(rawDepth) == kCVPixelFormatType_OneComponent16Half,
           mappedRect.origin == .zero,
           Int(mappedRect.width) == rawWidth,
           Int(mappedRect.height) == rawHeight {
            // The packaged fixed-size model takes this path. Preserve its Float16 bits
            // exactly and avoid an unnecessary Core Image round-trip/allocation.
            return rawDepth
        }

        let depthImage = CIImage(cvPixelBuffer: rawDepth)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        let cropped = depthImage.cropped(to: mappedRect)
        let originNormalized = cropped.transformed(
            by: CGAffineTransform(translationX: -mappedRect.origin.x, y: -mappedRect.origin.y)
        )

        // Keep the depth map at native model resolution. Metal samples it in normalized
        // coordinates while refining against the full-resolution RGB guide, so upscaling
        // here only adds blur and creates a very large temporary buffer for high-MP photos.
        // Half-float output also preserves the model's precision instead of quantizing it
        // through an 8-bit BGRA buffer before the GPU sees it.
        let outputWidth = max(1, Int(mappedRect.width.rounded()))
        let outputHeight = max(1, Int(mappedRect.height.rounded()))
        let outputScaleX = CGFloat(outputWidth) / max(mappedRect.width, 1)
        let outputScaleY = CGFloat(outputHeight) / max(mappedRect.height, 1)

        let resized = originNormalized
            .transformed(by: CGAffineTransform(scaleX: outputScaleX, y: outputScaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        let outputBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: outputWidth,
            height: outputHeight,
            pixelFormat: kCVPixelFormatType_OneComponent16Half
        )

        ciContext.render(
            resized,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceGray()
        )

        return outputBuffer
    }

    private static func computeModelSizing(width: Int, height: Int, shortSide: Int, longMultiple: Int) -> (model: IntSize, scaled: IntSize) {
        let sourceWidth = max(width, 1)
        let sourceHeight = max(height, 1)

        if sourceWidth <= sourceHeight {
            let scaledWidth = shortSide
            let scaledHeight = Int((Double(sourceHeight) * Double(shortSide) / Double(sourceWidth)).rounded())
            let modelHeight = roundUp(scaledHeight, multiple: longMultiple)
            return (
                model: IntSize(width: scaledWidth, height: modelHeight),
                scaled: IntSize(width: scaledWidth, height: scaledHeight)
            )
        } else {
            let scaledHeight = shortSide
            let scaledWidth = Int((Double(sourceWidth) * Double(shortSide) / Double(sourceHeight)).rounded())
            let modelWidth = roundUp(scaledWidth, multiple: longMultiple)
            return (
                model: IntSize(width: modelWidth, height: scaledHeight),
                scaled: IntSize(width: scaledWidth, height: scaledHeight)
            )
        }
    }

    private static func roundUp(_ value: Int, multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        let remainder = value % multiple
        if remainder == 0 { return value }
        return value + (multiple - remainder)
    }

    private static func roundDown(_ value: Int, multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        return value - (value % multiple)
    }

    static func computeFixedModelSizing(width: Int, height: Int, target: IntSize) -> (model: IntSize, scaled: IntSize) {
        _ = width
        _ = height

        // The packaged Depth Anything V2 model has a fixed 518x392 input and was
        // converted/evaluated with images stretched to that canvas. Letterboxing wastes
        // a large fraction of the model's spatial resolution (especially for portraits)
        // and introduces artificial black borders into the depth prediction.
        let fixedSize = IntSize(width: max(target.width, 1), height: max(target.height, 1))
        return (model: fixedSize, scaled: fixedSize)
    }

    private func imageInputName(for model: MLModel) -> String? {
        if let imageName = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key {
            return imageName
        }
        return model.modelDescription.inputDescriptionsByName.keys.first
    }

    private func modelInputSize(for model: MLModel) -> IntSize? {
        guard
            let inputName = imageInputName(for: model),
            let featureDescription = model.modelDescription.inputDescriptionsByName[inputName],
            featureDescription.type == .image,
            let constraint = featureDescription.imageConstraint
        else {
            return nil
        }

        let width = constraint.pixelsWide
        let height = constraint.pixelsHigh
        guard width > 0, height > 0 else {
            return nil
        }

        return IntSize(width: width, height: height)
    }
}
