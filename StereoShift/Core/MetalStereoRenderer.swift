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
    /// Region of the depth texture holding actual image content (origin u/v + size
    /// u/v). Anything outside is padding from model preprocessing and is never
    /// sampled. (0, 0, 1, 1) when the depth texture is already cropped.
    var depthCrop: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1)
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
    /// acceleration. Pipeline: joint-bilateral depth refine → per-eye directional
    /// max-dilate → per-eye Gaussian feather → occlusion-ordered scanline-search
    /// warp × 2 → SBS compose.
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

        let depthSharp = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthScratchB = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthScratchC = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthRight = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthLeft = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let leftTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let rightTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let sbsTexture = try makeEmptyTexture(width: width * 2, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        // The depth map comes from a ~518px model inference, so its edges are blurry
        // and misaligned with image edges. The joint bilateral window must span that
        // upsampling blur. Sampling stays in model space via `depthCrop`, so the
        // refine does the whole crop+upscale in one edge-aware step.
        let refineRadius = max(3, min(10, width / 450))
        let refineStep = refineRadius > 5 ? 2 : 1
        encodeDepthRefine(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: rawDepthTexture,
            output: depthSharp,
            radius: refineRadius,
            sampleStep: refineStep,
            sigmaSpatial: Float(refineRadius) * 0.6,
            sigmaColor: 0.1,
            minDepth: parameters.depthMin,
            invRange: 1 / max(parameters.depthMax - parameters.depthMin, 0.0001),
            gamma: parameters.depthGamma,
            depthCrop: parameters.depthCrop,
            width: width,
            height: height
        )

        // The warp's scanline search handles disocclusions itself, so dilation only
        // needs to push near depth across the silhouette's transition band — the
        // model-to-output upsample residual plus the anti-aliased color fringe — not
        // the full disocclusion width. It is DIRECTIONAL per eye: the right eye's
        // disocclusions trail to the right of foreground objects, the left eye's to
        // the left, so near depth is grown only toward that side. The clean side of
        // every silhouette keeps true background parallax, and keeping the radius
        // small keeps the fringe strip that rides along with the foreground narrow.
        let modelScale = Float(width) / 518
        let dilateHRadius = max(2, min(20, Int(min(modelScale * 2, maxShift * 0.5).rounded())))
        let dilateVRadius = max(1, min(6, dilateHRadius / 2))
        // Light feather: just enough to anti-alias dilated depth steps so the warp's
        // sub-step refinement lands smoothly, without smearing depth across edges.
        let smoothSigma: Float = 1.2
        let smoothRadius = 3

        // Right eye (warp direction +1): grow near depth rightward.
        encodeDepthDilate(commandBuffer: commandBuffer, input: depthSharp, output: depthScratchB, axis: SIMD2<Int32>(1, 0), radius: dilateHRadius, sampleStep: 1, dirSign: 1, width: width, height: height)
        encodeDepthDilate(commandBuffer: commandBuffer, input: depthScratchB, output: depthScratchC, axis: SIMD2<Int32>(0, 1), radius: dilateVRadius, sampleStep: 1, dirSign: 0, width: width, height: height)
        encodeDepthGaussian(commandBuffer: commandBuffer, input: depthScratchC, output: depthScratchB, axis: SIMD2<Int32>(1, 0), radius: smoothRadius, sigma: smoothSigma, width: width, height: height)
        encodeDepthGaussian(commandBuffer: commandBuffer, input: depthScratchB, output: depthRight, axis: SIMD2<Int32>(0, 1), radius: smoothRadius, sigma: smoothSigma, width: width, height: height)

        // Left eye (warp direction -1): grow near depth leftward.
        encodeDepthDilate(commandBuffer: commandBuffer, input: depthSharp, output: depthScratchB, axis: SIMD2<Int32>(1, 0), radius: dilateHRadius, sampleStep: 1, dirSign: -1, width: width, height: height)
        encodeDepthDilate(commandBuffer: commandBuffer, input: depthScratchB, output: depthScratchC, axis: SIMD2<Int32>(0, 1), radius: dilateVRadius, sampleStep: 1, dirSign: 0, width: width, height: height)
        encodeDepthGaussian(commandBuffer: commandBuffer, input: depthScratchC, output: depthScratchB, axis: SIMD2<Int32>(1, 0), radius: smoothRadius, sigma: smoothSigma, width: width, height: height)
        encodeDepthGaussian(commandBuffer: commandBuffer, input: depthScratchB, output: depthLeft, axis: SIMD2<Int32>(0, 1), radius: smoothRadius, sigma: smoothSigma, width: width, height: height)

        let edgeTaper = max(8, maxShift * parameters.convergence * 2)
        // Half-pixel scan steps up to a bounded iteration count; the warp refines
        // each hit below the step size, so coarser steps on extreme shifts stay clean.
        let warpStepSize = max(0.5, maxShift / 192)
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: depthLeft,
            output: leftTexture,
            direction: -1.0,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: edgeTaper,
            stepSize: warpStepSize,
            width: width,
            height: height
        )
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: depthRight,
            output: rightTexture,
            direction: 1.0,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: edgeTaper,
            stepSize: warpStepSize,
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

    // MARK: - Encoder helpers

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
        depthCrop: SIMD4<Float>,
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
        var crop = depthCrop
        encoder.setBytes(&r, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setBytes(&step, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBytes(&sigS, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&sigC, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&minD, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&invR, length: MemoryLayout<Float>.size, index: 5)
        encoder.setBytes(&g, length: MemoryLayout<Float>.size, index: 6)
        encoder.setBytes(&crop, length: MemoryLayout<SIMD4<Float>>.size, index: 7)
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
        dirSign: Int32,
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
        var sign = dirSign
        encoder.setBytes(&a, length: MemoryLayout<SIMD2<Int32>>.size, index: 0)
        encoder.setBytes(&r, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBytes(&step, length: MemoryLayout<Int32>.size, index: 2)
        encoder.setBytes(&sign, length: MemoryLayout<Int32>.size, index: 3)
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
        stepSize: Float,
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
        var step = stepSize
        encoder.setBytes(&dir, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shift, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&conv, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&taper, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&step, length: MemoryLayout<Float>.size, index: 4)
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
