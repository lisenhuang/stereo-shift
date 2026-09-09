import CoreImage
import CoreML
import Foundation

/// Depth straight from the model, in model-output space — not letterbox-cropped, not
/// upscaled, not quantized to 8-bit. Every model reaches this shape through
/// `DepthOutputAdapter`: OneComponent16Half, values in [0, 1], larger = nearer. The
/// Metal renderer consumes it directly so depth keeps full precision and the
/// joint-bilateral refine does a single edge-aware upsample to full resolution.
struct RawDepthMap: @unchecked Sendable {
    /// Model-output-space depth buffer. Larger value = closer to the camera.
    let depth: CVPixelBuffer
    /// Region of `depth` corresponding to the source image, in depth pixel
    /// coordinates with a top-left origin (letterbox padding excluded).
    let contentRect: CGRect
    /// Pixel size of the source image the depth was predicted from.
    let originalWidth: Int
    let originalHeight: Int
    /// Model that produced this map (drives per-model tuning and output labelling).
    let sourceModel: DepthModel
    /// Wall-clock seconds spent in `MLModel.prediction` for this map (0 when derived
    /// from other maps, e.g. temporal blending).
    let inferenceSeconds: Double

    init(
        depth: CVPixelBuffer,
        contentRect: CGRect,
        originalWidth: Int,
        originalHeight: Int,
        sourceModel: DepthModel = .bundledDefault,
        inferenceSeconds: Double = 0
    ) {
        self.depth = depth
        self.contentRect = contentRect
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.sourceModel = sourceModel
        self.inferenceSeconds = inferenceSeconds
    }

    /// `contentRect` expressed in normalized depth-texture coordinates
    /// (origin u/v + size u/v), ready for the GPU.
    var normalizedCrop: SIMD4<Float> {
        let width = Float(max(CVPixelBufferGetWidth(depth), 1))
        let height = Float(max(CVPixelBufferGetHeight(depth), 1))
        let x = Float(contentRect.origin.x) / width
        let y = Float(contentRect.origin.y) / height
        let w = Float(contentRect.width) / width
        let h = Float(contentRect.height) / height
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else {
            return SIMD4<Float>(0, 0, 1, 1)
        }
        return SIMD4<Float>(
            max(0, min(1, x)),
            max(0, min(1, y)),
            max(0, min(1, w)),
            max(0, min(1, h))
        )
    }
}

/// Timing of the most recent prediction, for the Settings benchmark and video ETA.
struct DepthInferenceStats: Sendable {
    let model: DepthModel
    let seconds: Double
    let computeUnits: MLComputeUnits
    let timestamp: Date
}

/// Result of `DepthEstimator.benchmark(model:iterations:)`.
struct DepthBenchmarkResult: Sendable {
    let model: DepthModel
    let iterations: Int
    let loadSeconds: Double
    let firstInferenceSeconds: Double
    let medianInferenceSeconds: Double
    let computeUnits: MLComputeUnits
}

actor DepthEstimator {
    private struct IntSize {
        var width: Int
        var height: Int
    }

    private struct PreprocessMetadata {
        let originalSize: IntSize
        let modelSize: IntSize
        let contentRect: CGRect
    }

    private struct LoadedModel {
        let model: MLModel
        let computeUnits: MLComputeUnits
        let url: URL
    }

    private struct RawPrediction {
        let depth: CVPixelBuffer
        let metadata: PreprocessMetadata
        let inferenceSeconds: Double
    }

    private let longSideMultiple: Int = 14

    private var loadedModels: [DepthModel: LoadedModel] = [:]
    private var loadingTasks: [DepthModel: Task<LoadedModel, Error>] = [:]
    private var compiledModelURLs: [URL: URL] = [:]
    private var inFlightPredictions = 0
    private var lastInference: DepthInferenceStats?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Prediction API

    func predictDepth(pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        try await predictDepth(
            pixelBuffer: pixelBuffer,
            model: .bundledDefault,
            quality: .quality
        )
    }

    /// Full-resolution 8-bit depth for the CPU/CIKernel fallback paths.
    func predictDepth(pixelBuffer: CVPixelBuffer, model: DepthModel, quality: DepthQuality) async throws -> CVPixelBuffer {
        let raw = try await predictRawDepthBuffer(pixelBuffer: pixelBuffer, model: model, quality: quality)
        let depth = try postprocess(depth: raw.depth, metadata: raw.metadata)
        return depth
    }

    /// Returns depth in model-output space together with the rect that maps it back
    /// onto the source image. Preferred over `predictDepth` on the Metal path: it
    /// skips the full-resolution 8-bit postprocess entirely.
    func predictRawDepth(pixelBuffer: CVPixelBuffer, model: DepthModel, quality: DepthQuality) async throws -> RawDepthMap {
        let raw = try await predictRawDepthBuffer(pixelBuffer: pixelBuffer, model: model, quality: quality)

        let rawWidth = CVPixelBufferGetWidth(raw.depth)
        let rawHeight = CVPixelBufferGetHeight(raw.depth)
        let sx = CGFloat(rawWidth) / CGFloat(max(raw.metadata.modelSize.width, 1))
        let sy = CGFloat(rawHeight) / CGFloat(max(raw.metadata.modelSize.height, 1))
        let contentRect = CGRect(
            x: raw.metadata.contentRect.origin.x * sx,
            y: raw.metadata.contentRect.origin.y * sy,
            width: raw.metadata.contentRect.width * sx,
            height: raw.metadata.contentRect.height * sy
        )

        return RawDepthMap(
            depth: raw.depth,
            contentRect: contentRect,
            originalWidth: raw.metadata.originalSize.width,
            originalHeight: raw.metadata.originalSize.height,
            sourceModel: model,
            inferenceSeconds: raw.inferenceSeconds
        )
    }

    // MARK: - Model lifecycle API

    /// Loads (and validates) a model ahead of first use so the first photo or frame
    /// does not pay the load + Neural Engine compile cost.
    func preload(_ model: DepthModel) async throws {
        _ = try await loadModel(model)
    }

    func isLoaded(_ model: DepthModel) -> Bool {
        loadedModels[model] != nil
    }

    func unload(_ model: DepthModel) {
        loadedModels[model] = nil
    }

    func unloadAll() {
        loadedModels.removeAll()
    }

    /// Memory-pressure hook: drops downloaded models when no prediction is running.
    /// The bundled model is small and stays resident.
    func unloadIfIdle() {
        guard inFlightPredictions == 0 else { return }
        loadedModels = loadedModels.filter { $0.key.isBundled }
    }

    func lastInferenceStats() -> DepthInferenceStats? {
        lastInference
    }

    /// Loads the model, runs a warm-up prediction and `iterations` timed predictions on
    /// a synthetic image. Used at install time (contract + warm-up) and by the Settings
    /// benchmark. Refuses to run while a conversion is using the estimator.
    func benchmark(model: DepthModel, iterations: Int = 5) async throws -> DepthBenchmarkResult {
        guard inFlightPredictions == 0 else {
            throw StereoPipelineError.modelBusy
        }

        let clock = ContinuousClock()
        let loadStart = clock.now
        let loaded = try await loadModel(model)
        let loadSeconds = Self.seconds(clock.now - loadStart)
        // A conversion may have started while the load was suspended; do not run the
        // timed predictions alongside it.
        guard inFlightPredictions == 0 else {
            throw StereoPipelineError.modelBusy
        }

        let input = try Self.makeSyntheticInput(width: 512, height: 384)
        let first = try await predictRawDepthBuffer(pixelBuffer: input, model: model, quality: .quality)

        var timings: [Double] = []
        for _ in 0..<max(1, iterations) {
            let raw = try await predictRawDepthBuffer(pixelBuffer: input, model: model, quality: .quality)
            timings.append(raw.inferenceSeconds)
        }
        timings.sort()

        return DepthBenchmarkResult(
            model: model,
            iterations: timings.count,
            loadSeconds: loadSeconds,
            firstInferenceSeconds: first.inferenceSeconds,
            medianInferenceSeconds: timings[timings.count / 2],
            computeUnits: loaded.computeUnits
        )
    }

    // MARK: - Prediction internals

    private func predictRawDepthBuffer(
        pixelBuffer: CVPixelBuffer,
        model depthModel: DepthModel,
        quality: DepthQuality
    ) async throws -> RawPrediction {
        let loaded = try await loadModel(depthModel)
        let prepared = try preprocess(pixelBuffer, depthModel: depthModel, model: loaded.model, quality: quality)
        let provider = try featureProvider(for: prepared.pixelBuffer, model: loaded.model)

        inFlightPredictions += 1
        defer { inFlightPredictions -= 1 }

        let clock = ContinuousClock()
        let start = clock.now
        let model = loaded.model
        let prediction = try await Task.detached(priority: .userInitiated) {
            try model.prediction(from: provider)
        }.value
        let inferenceSeconds = Self.seconds(clock.now - start)

        // Every model family lands in the same buffer shape here; nothing downstream
        // needs to know whether the model emitted an image or a multi-array, or
        // whether it predicts disparity or depth.
        let rawDepth = try DepthOutputAdapter.canonicalDepth(from: prediction, spec: depthModel.outputSpec)

        lastInference = DepthInferenceStats(
            model: depthModel,
            seconds: inferenceSeconds,
            computeUnits: loaded.computeUnits,
            timestamp: Date()
        )
        return RawPrediction(depth: rawDepth, metadata: prepared.metadata, inferenceSeconds: inferenceSeconds)
    }

    // MARK: - Loading

    private func loadModel(_ depthModel: DepthModel) async throws -> LoadedModel {
        if let loaded = loadedModels[depthModel] {
            return loaded
        }
        if let task = loadingTasks[depthModel] {
            return try await task.value
        }

        let task = Task<LoadedModel, Error> {
            try await self.performLoad(depthModel)
        }
        loadingTasks[depthModel] = task
        defer { loadingTasks[depthModel] = nil }

        let loaded = try await task.value
        loadedModels[depthModel] = loaded
        return loaded
    }

    private func performLoad(_ depthModel: DepthModel) async throws -> LoadedModel {
        guard let modelURL = try locateModelURL(depthModel) else {
            if depthModel.isBundled {
                throw StereoPipelineError.modelNotFound
            }
            throw StereoPipelineError.modelNotInstalled(depthModel.displayName)
        }

        // Single-resident policy for downloaded models: a 0.35B ViT-L must never share
        // memory with another download. The bundled model may stay resident.
        if !depthModel.isBundled {
            for key in loadedModels.keys where !key.isBundled && key != depthModel {
                loadedModels[key] = nil
            }
        }

        var lastError: Error?
        for computeUnits in computeUnitOrder(for: depthModel) {
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = computeUnits
                let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
                // A contract mismatch is a wrong file, not a compute-unit problem.
                try DepthOutputAdapter.validateContract(model: model, spec: depthModel.outputSpec)
                return LoadedModel(model: model, computeUnits: computeUnits, url: modelURL)
            } catch let error as StereoPipelineError {
                throw error
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw StereoPipelineError.modelNotFound
    }

    private func computeUnitOrder(for depthModel: DepthModel) -> [MLComputeUnits] {
        var order = preferredComputeUnitOrder
        if let preferred = depthModel.preferredComputeUnits {
            order.removeAll { $0 == preferred }
            order.insert(preferred, at: 0)
        }
        return order
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

    /// Resolution order: user-installed model (Application Support) → compiled model
    /// in the bundle → package in the bundle (compiled on first use) → bundle scan.
    private func locateModelURL(_ depthModel: DepthModel) throws -> URL? {
        if let installed = DepthModelLibrary.installedCompiledModelURL(for: depthModel) {
            return installed
        }

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

    // MARK: - Pre/post-processing

    private func featureProvider(for pixelBuffer: CVPixelBuffer, model: MLModel) throws -> MLFeatureProvider {
        guard let inputName = imageInputName(for: model) else {
            throw StereoPipelineError.modelInputNotFound
        }

        let value = MLFeatureValue(pixelBuffer: pixelBuffer)
        return try MLDictionaryFeatureProvider(dictionary: [inputName: value])
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
            originalSize: IntSize(width: sourceWidth, height: sourceHeight),
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

        let depthImage = CIImage(cvPixelBuffer: rawDepth)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        let cropped = depthImage.cropped(to: mappedRect)
        let originNormalized = cropped.transformed(
            by: CGAffineTransform(translationX: -mappedRect.origin.x, y: -mappedRect.origin.y)
        )

        let outputWidth = metadata.originalSize.width
        let outputHeight = metadata.originalSize.height
        let outputScaleX = CGFloat(outputWidth) / max(mappedRect.width, 1)
        let outputScaleY = CGFloat(outputHeight) / max(mappedRect.height, 1)

        let resized = originNormalized
            .transformed(by: CGAffineTransform(scaleX: outputScaleX, y: outputScaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        let outputBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: outputWidth,
            height: outputHeight,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        ciContext.render(
            resized,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
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

    private static func computeFixedModelSizing(width: Int, height: Int, target: IntSize) -> (model: IntSize, scaled: IntSize) {
        // Aspect-fill stretch: every model pixel carries image content. Letterboxing
        // wasted up to ~45% of the fixed 518×392 input on padding for portrait shots
        // and fed the model black bars that contaminate depth near the content edge.
        // The model tolerates the aspect distortion, and the depth map is stretched
        // back over the source frame by the inverse mapping, so geometry round-trips.
        // Works for any fixed input size, square (504×504) included.
        let targetSize = IntSize(width: max(target.width, 1), height: max(target.height, 1))
        return (model: targetSize, scaled: targetSize)
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

    // MARK: - Helpers

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + (Double(components.attoseconds) / 1e18)
    }

    /// A BGRA test card (smooth gradient plus a bright disc) for warm-up and benchmarks.
    /// Not a polarity reference — that needs a real photo with known near/far regions.
    private static func makeSyntheticInput(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try PixelBufferUtilities.makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let centerX = Double(width) * 0.5
        let centerY = Double(height) * 0.55
        let radius = Double(min(width, height)) * 0.22

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: width * 4)
            for x in 0..<width {
                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                let inDisc = (dx * dx) + (dy * dy) < radius * radius
                let shade = UInt8(40 + (Double(y) / Double(max(height - 1, 1))) * 150)
                let offset = x * 4
                row[offset] = inDisc ? 230 : shade          // B
                row[offset + 1] = inDisc ? 200 : shade      // G
                row[offset + 2] = inDisc ? 120 : shade      // R
                row[offset + 3] = 255                       // A
            }
        }
        return buffer
    }
}
