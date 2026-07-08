import CoreVideo
import Foundation
import Metal

/// Parameters for one SBS render. Depth min/max are percentile bounds of the raw depth
/// map (computed on the CPU from a downsampled histogram); the GPU normalizes depth to
/// [0, 1] with them so every image uses the full disparity budget consistently.
struct MetalStereoParameters {
    var maxShift: Float
    var convergence: Float
    var depthMin: Float
    var depthMax: Float
    var depthGamma: Float = 1.0
}

final class MetalStereoRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let depthRefinePipeline: MTLComputePipelineState
    private let depthDilatePipeline: MTLComputePipelineState
    private let depthGaussianPipeline: MTLComputePipelineState
    private let stereoWarpPipeline: MTLComputePipelineState
    private let composeSBSPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    static let shared: MetalStereoRenderer? = {
        try? MetalStereoRenderer()
    }()

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        guard let library = device.makeDefaultLibrary() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        guard let depthRefineFn = library.makeFunction(name: "depthRefine"),
              let depthDilateFn = library.makeFunction(name: "depthDilateAxis"),
              let depthGaussianFn = library.makeFunction(name: "depthGaussianAxis"),
              let stereoWarpFn = library.makeFunction(name: "stereoWarp"),
              let composeFn = library.makeFunction(name: "composeSBS") else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        self.device = device
        self.commandQueue = queue
        self.depthRefinePipeline = try device.makeComputePipelineState(function: depthRefineFn)
        self.depthDilatePipeline = try device.makeComputePipelineState(function: depthDilateFn)
        self.depthGaussianPipeline = try device.makeComputePipelineState(function: depthGaussianFn)
        self.stereoWarpPipeline = try device.makeComputePipelineState(function: stereoWarpFn)
        self.composeSBSPipeline = try device.makeComputePipelineState(function: composeFn)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Produces an SBS stereo pair from an RGB image and its depth map using Metal GPU
    /// acceleration. Pipeline: joint-bilateral depth refine → separable max-dilate →
    /// separable Gaussian feather → iterative inverse warp × 2 → SBS compose.
    func makeSBS(
        from rgb: CVPixelBuffer,
        depth: CVPixelBuffer,
        parameters: MetalStereoParameters
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)
        let maxShift = max(0, parameters.maxShift)

        let sourceTexture = try makeTexture(from: rgb, pixelFormat: .bgra8Unorm)
        let rawDepthTexture = try makeTexture(from: depth, pixelFormat: depthTexturePixelFormat(for: depth))

        let depthA = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthB = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let leftTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let rightTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let sbsTexture = try makeEmptyTexture(width: width * 2, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        encodeDepthPreparation(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            rawDepth: rawDepthTexture,
            depthA: depthA,
            depthB: depthB,
            parameters: parameters,
            width: width,
            height: height
        )

        let edgeTaper = max(8, maxShift * parameters.convergence * 2)
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: depthA,
            output: leftTexture,
            direction: -1.0,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: edgeTaper,
            width: width,
            height: height
        )
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: depthA,
            output: rightTexture,
            direction: 1.0,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: edgeTaper,
            width: width,
            height: height
        )

        encodeComposeSBS(
            commandBuffer: commandBuffer,
            left: leftTexture,
            right: rightTexture,
            output: sbsTexture,
            width: width * 2,
            height: height
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        return try readTexture(sbsTexture, width: width * 2, height: height)
    }

    // MARK: - Motion-parallax preview

    /// A prepared context for the real-time motion-parallax preview. The expensive depth
    /// passes (refine → dilate → feather) run once at creation; each preview frame is
    /// then a single `stereoWarp` dispatch at an eye offset in [-1, 1], where -1 and +1
    /// reproduce the exported SBS left and right eyes exactly.
    final class ParallaxPreviewSession {
        let width: Int
        let height: Int
        let device: MTLDevice
        /// Holds the novel view written by the most recent `encodeNovelView` call.
        let outputTexture: MTLTexture

        private let renderer: MetalStereoRenderer
        private let sourceTexture: MTLTexture
        private let refinedDepthTexture: MTLTexture
        private let maxShift: Float
        private let convergence: Float
        private let edgeTaper: Float

        fileprivate init(
            renderer: MetalStereoRenderer,
            sourceTexture: MTLTexture,
            refinedDepthTexture: MTLTexture,
            outputTexture: MTLTexture,
            width: Int,
            height: Int,
            maxShift: Float,
            convergence: Float,
            edgeTaper: Float
        ) {
            self.renderer = renderer
            self.device = renderer.device
            self.sourceTexture = sourceTexture
            self.refinedDepthTexture = refinedDepthTexture
            self.outputTexture = outputTexture
            self.width = width
            self.height = height
            self.maxShift = maxShift
            self.convergence = convergence
            self.edgeTaper = edgeTaper
        }

        func makeCommandBuffer() -> MTLCommandBuffer? {
            renderer.commandQueue.makeCommandBuffer()
        }

        /// Encodes one novel view at `direction` (clamped to [-1, 1]) into `outputTexture`.
        func encodeNovelView(direction: Float, commandBuffer: MTLCommandBuffer) {
            renderer.encodeStereoWarp(
                commandBuffer: commandBuffer,
                source: sourceTexture,
                depth: refinedDepthTexture,
                output: outputTexture,
                direction: max(-1, min(1, direction)),
                maxShift: maxShift,
                convergence: convergence,
                edgeTaper: edgeTaper,
                width: width,
                height: height
            )
        }
    }

    /// Runs the depth preparation passes once (same parameters as `makeSBS`, so the
    /// preview matches the exported stereo geometry) and returns a session that renders
    /// novel views with a single warp dispatch per frame. The session owns copies of
    /// everything it needs; the pixel buffers are not retained past this call.
    func makeParallaxPreviewSession(
        rgb: CVPixelBuffer,
        depth: CVPixelBuffer,
        parameters: MetalStereoParameters
    ) throws -> ParallaxPreviewSession {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)
        let maxShift = max(0, parameters.maxShift)

        let wrappedSource = try makeTexture(from: rgb, pixelFormat: .bgra8Unorm)
        let rawDepthTexture = try makeTexture(from: depth, pixelFormat: depthTexturePixelFormat(for: depth))

        let depthA = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthB = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let ownedSource = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let outputTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        encodeDepthPreparation(
            commandBuffer: commandBuffer,
            source: wrappedSource,
            rawDepth: rawDepthTexture,
            depthA: depthA,
            depthB: depthB,
            parameters: parameters,
            width: width,
            height: height
        )

        // Copy the source into a texture the session owns so the caller's pixel buffer
        // (and its texture-cache wrapper) doesn't have to stay alive across preview frames.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: wrappedSource, to: ownedSource)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        return ParallaxPreviewSession(
            renderer: self,
            sourceTexture: ownedSource,
            refinedDepthTexture: depthA,
            outputTexture: outputTexture,
            width: width,
            height: height,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: max(8, maxShift * parameters.convergence * 2)
        )
    }

    // MARK: - Encoder helpers

    /// Encodes the shared depth preparation: joint-bilateral refine → separable
    /// max-dilate → separable Gaussian feather. The final depth lands in `depthA`;
    /// `depthB` is ping-pong scratch.
    private func encodeDepthPreparation(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        rawDepth: MTLTexture,
        depthA: MTLTexture,
        depthB: MTLTexture,
        parameters: MetalStereoParameters,
        width: Int,
        height: Int
    ) {
        let maxShift = max(0, parameters.maxShift)

        // The depth map comes from a ~518px model inference upscaled to full resolution,
        // so its edges are blurry and misaligned with image edges. The joint bilateral
        // window must span that upsampling blur.
        let refineRadius = max(3, min(10, width / 450))
        let refineStep = refineRadius > 5 ? 2 : 1
        encodeDepthRefine(
            commandBuffer: commandBuffer,
            source: source,
            depth: rawDepth,
            output: depthA,
            radius: refineRadius,
            sampleStep: refineStep,
            sigmaSpatial: Float(refineRadius) * 0.6,
            sigmaColor: 0.1,
            minDepth: parameters.depthMin,
            invRange: 1 / max(parameters.depthMax - parameters.depthMin, 0.0001),
            gamma: parameters.depthGamma,
            width: width,
            height: height
        )

        // Dilation must cover the disparity difference across a silhouette, so it scales
        // with maxShift. Horizontal dominates because disocclusions are horizontal.
        let dilateHRadius = max(2, min(48, Int((maxShift * 0.6).rounded())))
        let dilateHStep = dilateHRadius > 20 ? 2 : 1
        let dilateVRadius = max(1, min(6, Int((maxShift * 0.1).rounded())))
        encodeDepthDilate(commandBuffer: commandBuffer, input: depthA, output: depthB, axis: SIMD2<Int32>(1, 0), radius: dilateHRadius, sampleStep: dilateHStep, width: width, height: height)
        encodeDepthDilate(commandBuffer: commandBuffer, input: depthB, output: depthA, axis: SIMD2<Int32>(0, 1), radius: dilateVRadius, sampleStep: 1, width: width, height: height)

        let smoothSigma = max(1.0, min(6.0, maxShift * 0.15))
        let smoothRadius = min(15, Int((smoothSigma * 2.5).rounded(.up)))
        encodeDepthGaussian(commandBuffer: commandBuffer, input: depthA, output: depthB, axis: SIMD2<Int32>(1, 0), radius: smoothRadius, sigma: smoothSigma, width: width, height: height)
        encodeDepthGaussian(commandBuffer: commandBuffer, input: depthB, output: depthA, axis: SIMD2<Int32>(0, 1), radius: smoothRadius, sigma: smoothSigma, width: width, height: height)
    }

    private func encodeDepthRefine(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        depth: MTLTexture,
        output: MTLTexture,
        radius: Int,
        sampleStep: Int,
        sigmaSpatial: Float,
        sigmaColor: Float,
        minDepth: Float,
        invRange: Float,
        gamma: Float,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(depthRefinePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(depth, index: 1)
        encoder.setTexture(output, index: 2)
        var r = Int32(radius)
        var step = Int32(sampleStep)
        var sigS = sigmaSpatial
        var sigC = sigmaColor
        var minD = minDepth
        var invR = invRange
        var g = gamma
        encoder.setBytes(&r, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setBytes(&step, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBytes(&sigS, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&sigC, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&minD, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&invR, length: MemoryLayout<Float>.size, index: 5)
        encoder.setBytes(&g, length: MemoryLayout<Float>.size, index: 6)
        dispatchThreads(encoder: encoder, pipeline: depthRefinePipeline, width: width, height: height)
        encoder.endEncoding()
    }

    private func encodeDepthDilate(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        axis: SIMD2<Int32>,
        radius: Int,
        sampleStep: Int,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(depthDilatePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        var a = axis
        var r = Int32(radius)
        var step = Int32(sampleStep)
        encoder.setBytes(&a, length: MemoryLayout<SIMD2<Int32>>.size, index: 0)
        encoder.setBytes(&r, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBytes(&step, length: MemoryLayout<Int32>.size, index: 2)
        dispatchThreads(encoder: encoder, pipeline: depthDilatePipeline, width: width, height: height)
        encoder.endEncoding()
    }

    private func encodeDepthGaussian(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        axis: SIMD2<Int32>,
        radius: Int,
        sigma: Float,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(depthGaussianPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        var a = axis
        var r = Int32(radius)
        var s = sigma
        encoder.setBytes(&a, length: MemoryLayout<SIMD2<Int32>>.size, index: 0)
        encoder.setBytes(&r, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBytes(&s, length: MemoryLayout<Float>.size, index: 2)
        dispatchThreads(encoder: encoder, pipeline: depthGaussianPipeline, width: width, height: height)
        encoder.endEncoding()
    }

    private func encodeStereoWarp(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        depth: MTLTexture,
        output: MTLTexture,
        direction: Float,
        maxShift: Float,
        convergence: Float,
        edgeTaper: Float,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(stereoWarpPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(depth, index: 1)
        encoder.setTexture(output, index: 2)
        var dir = direction
        var shift = maxShift
        var conv = convergence
        var taper = edgeTaper
        encoder.setBytes(&dir, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shift, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&conv, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&taper, length: MemoryLayout<Float>.size, index: 3)
        dispatchThreads(encoder: encoder, pipeline: stereoWarpPipeline, width: width, height: height)
        encoder.endEncoding()
    }

    private func encodeComposeSBS(
        commandBuffer: MTLCommandBuffer,
        left: MTLTexture,
        right: MTLTexture,
        output: MTLTexture,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(composeSBSPipeline)
        encoder.setTexture(left, index: 0)
        encoder.setTexture(right, index: 1)
        encoder.setTexture(output, index: 2)
        dispatchThreads(encoder: encoder, pipeline: composeSBSPipeline, width: width, height: height)
        encoder.endEncoding()
    }

    private func dispatchThreads(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let threadGroupSize = MTLSize(
            width: min(pipeline.threadExecutionWidth, width),
            height: min(pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth, height),
            depth: 1
        )
        let gridSize = MTLSize(width: width, height: height, depth: 1)

        if device.supportsFamily(.apple4) {
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
        } else {
            let groups = MTLSize(
                width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
                height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadGroupSize)
        }
    }

    // MARK: - Texture helpers

    private func depthTexturePixelFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent8:
            return .r8Unorm
        case kCVPixelFormatType_OneComponent16Half:
            return .r16Float
        case kCVPixelFormatType_OneComponent32Float:
            return .r32Float
        default:
            return .bgra8Unorm
        }
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat) throws -> MTLTexture {
        guard let cache = textureCache else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        return texture
    }

    private func makeEmptyTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw StereoPipelineError.metalDeviceUnavailable
        }
        return texture
    }

    private func readTexture(_ texture: MTLTexture, width: Int, height: Int) throws -> CVPixelBuffer {
        let outputBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: MTLRegion(origin: .init(), size: .init(width: width, height: height, depth: 1)), mipmapLevel: 0)

        return outputBuffer
    }
}
