import CoreVideo
import Foundation
import Metal

final class MetalStereoRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let depthMaxPipeline: MTLComputePipelineState
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

        guard let depthMaxFn = library.makeFunction(name: "depthMaxFilter"),
              let stereoWarpFn = library.makeFunction(name: "stereoWarpMetal"),
              let composeFn = library.makeFunction(name: "composeSBS") else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        self.device = device
        self.commandQueue = queue
        self.depthMaxPipeline = try device.makeComputePipelineState(function: depthMaxFn)
        self.stereoWarpPipeline = try device.makeComputePipelineState(function: stereoWarpFn)
        self.composeSBSPipeline = try device.makeComputePipelineState(function: composeFn)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Produces an SBS stereo pair from an RGB image and its depth map using Metal GPU acceleration.
    /// Matches the Spatial Media Toolkit pipeline: depth max filter → inverse warp × 2 → SBS compose.
    func makeSBS(
        from rgb: CVPixelBuffer,
        depth: CVPixelBuffer,
        maxShift: Float,
        depthFilterRadius: Float = 3.0,
        depthFilterIncrement: Float = 1.0
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)

        // Create textures from pixel buffers
        let sourceTexture = try makeTexture(from: rgb, pixelFormat: .bgra8Unorm, usage: [.shaderRead])
        let depthTexture = try makeTexture(from: depth, pixelFormat: .bgra8Unorm, usage: [.shaderRead])

        // Intermediate textures
        let filteredDepthTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .r32Float, usage: [.shaderRead, .shaderWrite])
        let leftTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let rightTexture = try makeEmptyTexture(width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        let sbsTexture = try makeEmptyTexture(width: width * 2, height: height, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StereoPipelineError.metalDeviceUnavailable
        }

        // Pass 1: Depth max filter — dilate foreground depth to prevent occlusion holes
        encodeDepthMaxFilter(
            commandBuffer: commandBuffer,
            inDepth: depthTexture,
            outDepth: filteredDepthTexture,
            radius: depthFilterRadius,
            increment: depthFilterIncrement,
            width: width,
            height: height
        )

        // Pass 2: Stereo warp left eye (direction = -1, shift source left for left eye)
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: filteredDepthTexture,
            output: leftTexture,
            direction: -1.0,
            maxShift: maxShift,
            width: width,
            height: height
        )

        // Pass 3: Stereo warp right eye (direction = +1, shift source right for right eye)
        encodeStereoWarp(
            commandBuffer: commandBuffer,
            source: sourceTexture,
            depth: filteredDepthTexture,
            output: rightTexture,
            direction: 1.0,
            maxShift: maxShift,
            width: width,
            height: height
        )

        // Pass 4: Compose SBS
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

        // Read back from SBS texture to CVPixelBuffer
        return try readTexture(sbsTexture, width: width * 2, height: height)
    }

    // MARK: - Encoder helpers

    private func encodeDepthMaxFilter(
        commandBuffer: MTLCommandBuffer,
        inDepth: MTLTexture,
        outDepth: MTLTexture,
        radius: Float,
        increment: Float,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(depthMaxPipeline)
        encoder.setTexture(inDepth, index: 0)
        encoder.setTexture(outDepth, index: 1)
        var r = radius
        var inc = increment
        encoder.setBytes(&r, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&inc, length: MemoryLayout<Float>.size, index: 1)
        dispatchThreads(encoder: encoder, pipeline: depthMaxPipeline, width: width, height: height)
        encoder.endEncoding()
    }

    private func encodeStereoWarp(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        depth: MTLTexture,
        output: MTLTexture,
        direction: Float,
        maxShift: Float,
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
        encoder.setBytes(&dir, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shift, length: MemoryLayout<Float>.size, index: 1)
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

    private func makeTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
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
