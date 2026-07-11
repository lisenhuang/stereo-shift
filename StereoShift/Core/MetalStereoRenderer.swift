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
    var renderProfile: StereoRenderProfile = .ultraFast
}

final class MetalStereoRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let depthRefinePipeline: MTLComputePipelineState
    private let depthDilatePipeline: MTLComputePipelineState
    private let depthGaussianPipeline: MTLComputePipelineState
    private let stereoWarpPipeline: MTLComputePipelineState
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
              let stereoWarpFn = library.makeFunction(name: "stereoWarp") else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        self.device = device
        self.commandQueue = queue
        self.depthRefinePipeline = try device.makeComputePipelineState(function: depthRefineFn)
        self.depthDilatePipeline = try device.makeComputePipelineState(function: depthDilateFn)
        self.depthGaussianPipeline = try device.makeComputePipelineState(function: depthGaussianFn)
        self.stereoWarpPipeline = try device.makeComputePipelineState(function: stereoWarpFn)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Produces an SBS stereo pair from an RGB image and its depth map using Metal GPU
    /// acceleration. Pipeline: joint-bilateral depth refine → profile-specific occlusion
    /// handling → iterative inverse warp × 2 directly into the SBS output.
    func makeSBS(
        from rgb: CVPixelBuffer,
        depth: CVPixelBuffer,
        parameters: MetalStereoParameters
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)
        let maxShift = max(0, parameters.maxShift)
        let highQuality = parameters.renderProfile == .quality

        let sourceTexture = try makeTexture(from: rgb, pixelFormat: .bgra8Unorm)
        let rawDepthTexture = try makeTexture(from: depth, pixelFormat: depthTexturePixelFormat(for: depth))

        let depthA = try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let depthB = highQuality
            ? nil
            : try makeEmptyTexture(width: width, height: height, pixelFormat: .r16Float, usage: [.shaderRead, .shaderWrite])
        let outputBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: width * 2,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        let sbsTexture = try makeTexture(from: outputBuffer, pixelFormat: .bgra8Unorm)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        // The filter radius is measured in native model-depth texels, not output pixels.
        // Quality therefore always gathers 25 distinct depth samples (fast: 9), reaching
        // the same semantic edge neighborhood without a high-resolution phase pattern.
        let refineRadius = highQuality ? 2 : 1
        encodeDepthRefine(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: rawDepthTexture,
            output: depthA,
            radius: refineRadius,
            sigmaSpatial: highQuality ? 1.35 : 0.9,
            sigmaColor: highQuality ? 0.14 : 0.1,
            minDepth: parameters.depthMin,
            invRange: 1 / max(parameters.depthMax - parameters.depthMin, 0.0001),
            gamma: parameters.depthGamma,
            width: width,
            height: height
        )

        if let depthB {
            // The video-oriented fast path keeps the inexpensive conservative support
            // map. Quality mode instead warps with the edge-aligned refined depth and
            // resolves foreground/background roots in the warp shader itself.
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

        let edgeTaper = max(8, maxShift * parameters.convergence * 2)
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: depthA,
            output: sbsTexture,
            direction: -1.0,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: edgeTaper,
            iterations: highQuality ? 5 : 3,
            outputXOffset: 0,
            width: width,
            height: height
        )
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: depthA,
            output: sbsTexture,
            direction: 1.0,
            maxShift: maxShift,
            convergence: parameters.convergence,
            edgeTaper: edgeTaper,
            iterations: highQuality ? 5 : 3,
            outputXOffset: width,
            width: width,
            height: height
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        return outputBuffer
    }

    // MARK: - Encoder helpers

    private func encodeDepthRefine(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        depth: MTLTexture,
        output: MTLTexture,
        radius: Int,
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
        var sigS = sigmaSpatial
        var sigC = sigmaColor
        var minD = minDepth
        var invR = invRange
        var g = gamma
        encoder.setBytes(&r, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setBytes(&sigS, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&sigC, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&minD, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&invR, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&g, length: MemoryLayout<Float>.size, index: 5)
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
        iterations: Int,
        outputXOffset: Int,
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
        var iterationCount = Int32(max(1, min(6, iterations)))
        var xOffset = UInt32(max(0, outputXOffset))
        encoder.setBytes(&dir, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shift, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&conv, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&taper, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&iterationCount, length: MemoryLayout<Int32>.size, index: 4)
        encoder.setBytes(&xOffset, length: MemoryLayout<UInt32>.size, index: 5)
        dispatchThreads(encoder: encoder, pipeline: stereoWarpPipeline, width: width, height: height)
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
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw StereoPipelineError.metalDeviceUnavailable
        }
        return texture
    }

}
