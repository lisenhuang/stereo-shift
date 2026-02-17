import CoreImage
import CoreVideo
import Foundation
import Vision

final class StereoRenderer {
    private struct RefinedServerPreset {
        let baselinePerEye: Float
        let depthShortSideCap: Int
        let bilateralDiameter: Int
        let bilateralSigmaColor: Float
        let bilateralSigmaSpace: Float
        let guidedDepthRefinementEnabled: Bool
        let depthEdgeFeatherEnabled: Bool
        let depthEdgeFeatherThreshold: Float
        let depthEdgeFeatherStrength: Float
        let edgeFilteringEnabled: Bool
        let cannyLowThreshold: Float
        let cannyHighThreshold: Float
        let edgeKernelSize: Int
        let dilationIterations: Int
        let dilationMaxRightOffset: Int
        let inpaintRadius: Int
        let inpaintPasses: Int
        let subpixelWarpEnabled: Bool
        let outputEdgeAntiAliasEnabled: Bool
        let outputEdgeAntiAliasThreshold: Float
        let outputEdgeAntiAliasStrength: Float
        let edgeSupersamplingEnabled: Bool
        let edgeSupersamplingShiftGradientThreshold: Float
        let edgeSupersamplingMaxBlend: Float

        static func forProfile(_ profile: StereoRenderProfile) -> RefinedServerPreset {
            switch profile {
            case .ultraFast:
                return RefinedServerPreset(
                    baselinePerEye: 35,
                    depthShortSideCap: 392,
                    bilateralDiameter: 3,
                    bilateralSigmaColor: 51,
                    bilateralSigmaSpace: 3,
                    guidedDepthRefinementEnabled: false,
                    depthEdgeFeatherEnabled: false,
                    depthEdgeFeatherThreshold: 0,
                    depthEdgeFeatherStrength: 0,
                    edgeFilteringEnabled: false,
                    cannyLowThreshold: 50,
                    cannyHighThreshold: 150,
                    edgeKernelSize: 3,
                    dilationIterations: 1,
                    dilationMaxRightOffset: 1,
                    inpaintRadius: 1,
                    inpaintPasses: 1,
                    subpixelWarpEnabled: false,
                    outputEdgeAntiAliasEnabled: false,
                    outputEdgeAntiAliasThreshold: 0,
                    outputEdgeAntiAliasStrength: 0,
                    edgeSupersamplingEnabled: false,
                    edgeSupersamplingShiftGradientThreshold: 0,
                    edgeSupersamplingMaxBlend: 0
                )
            case .quality:
                return RefinedServerPreset(
                    baselinePerEye: 35,
                    depthShortSideCap: 518,
                    bilateralDiameter: 9,
                    bilateralSigmaColor: 25.5,
                    bilateralSigmaSpace: 5,
                    guidedDepthRefinementEnabled: true,
                    depthEdgeFeatherEnabled: true,
                    depthEdgeFeatherThreshold: 0.03,
                    depthEdgeFeatherStrength: 0.5,
                    edgeFilteringEnabled: true,
                    cannyLowThreshold: 50,
                    cannyHighThreshold: 150,
                    edgeKernelSize: 5,
                    dilationIterations: 1,
                    dilationMaxRightOffset: 2,
                    inpaintRadius: 3,
                    inpaintPasses: 2,
                    subpixelWarpEnabled: false,
                    outputEdgeAntiAliasEnabled: true,
                    outputEdgeAntiAliasThreshold: 0.65,
                    outputEdgeAntiAliasStrength: 0.45,
                    edgeSupersamplingEnabled: true,
                    edgeSupersamplingShiftGradientThreshold: 0.55,
                    edgeSupersamplingMaxBlend: 0.9
                )
            }
        }
    }

    private let depthEstimator: DepthEstimator
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var kernelWarpIsHealthy = true
    private static let stereoWarpKernel: CIKernel? = {
        let source = """
        kernel vec4 stereoWarp(sampler colorImage, sampler depthImage, float direction, float maxShift, float minDepth, float invRange, float invertDepth, float gamma) {
            vec2 d = destCoord();
            vec4 colorExtent = samplerExtent(colorImage);
            float minX = colorExtent.x;
            float maxX = colorExtent.x + colorExtent.z - 1.0;
            float sum = 0.0;
            sum += sample(depthImage, d + vec2(-1.0, -1.0)).r;
            sum += sample(depthImage, d + vec2(0.0, -1.0)).r;
            sum += sample(depthImage, d + vec2(1.0, -1.0)).r;
            sum += sample(depthImage, d + vec2(-1.0, 0.0)).r;
            sum += sample(depthImage, d).r;
            sum += sample(depthImage, d + vec2(1.0, 0.0)).r;
            sum += sample(depthImage, d + vec2(-1.0, 1.0)).r;
            sum += sample(depthImage, d + vec2(0.0, 1.0)).r;
            sum += sample(depthImage, d + vec2(1.0, 1.0)).r;

            float depthValue = clamp(((sum / 9.0) - minDepth) * invRange, 0.0, 1.0);
            if (invertDepth > 0.5) {
                depthValue = 1.0 - depthValue;
            }
            depthValue = pow(depthValue, gamma);
            float shiftedX = clamp(d.x + (direction * depthValue * maxShift), minX, maxX);
            vec4 sampledColor = sample(colorImage, vec2(shiftedX, d.y));
            vec3 opaqueColor = sampledColor.rgb;
            if (sampledColor.a > 0.00001) {
                opaqueColor = sampledColor.rgb / sampledColor.a;
            }
            return vec4(opaqueColor, 1.0);
        }
        """

        guard let kernels = try? CIKernel.makeKernels(source: source) else {
            return nil
        }
        return kernels.first
    }()

    init(depthEstimator: DepthEstimator) {
        self.depthEstimator = depthEstimator
    }

    static func maxDisparity(forWidth width: Int) -> Float {
        maxDisparity(forWidth: width, tuning: .classic)
    }

    static func maxDisparity(forWidth width: Int, tuning: DepthTuning) -> Float {
        let scaled = 24 * (Float(width) / 720)
        let base = max(8, scaled)
        let cap: Float = tuning == .enhanced ? 140 : 56
        return min(base, cap)
    }

    func makeSBS(from image: CGImage, strength: Float) async throws -> CGImage {
        let options = Stereo3DOptions()
        let output = try await makeSBS(from: image, strength: strength, options: options)
        return output
    }

    func makeSBS(from image: CGImage, strength: Float, options: Stereo3DOptions) async throws -> CGImage {
        let rgbBuffer = try PixelBufferUtilities.makePixelBuffer(from: image)
        let depthBuffer = try await depthEstimator.predictDepth(
            pixelBuffer: rgbBuffer,
            model: options.depthModel,
            quality: options.depthQuality
        )
        let outputBuffer = try makeSBS(from: rgbBuffer, depth: depthBuffer, strength: strength, options: options)
        return try PixelBufferUtilities.makeCGImage(from: outputBuffer, context: ciContext)
    }

    func makeSBS(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float) throws -> CVPixelBuffer {
        try makeSBS(from: rgb, depth: depth, strength: strength, options: Stereo3DOptions())
    }

    func makeSBS(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float, options: Stereo3DOptions) throws -> CVPixelBuffer {
        if options.generationMethod == .serverLike {
            return try makeSBSServerLike(from: rgb, depth: depth, strength: strength, options: options)
        }

        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)
        let refinedDepth = try refineDepthBufferIfNeeded(
            depth: depth,
            guide: rgb,
            targetWidth: width,
            targetHeight: height,
            refinement: options.depthRefinement,
            tuning: options.depthTuning
        )

        if options.viewSynthesis == .inverseWarp,
           options.renderEngine == .ciKernel,
           kernelWarpIsHealthy,
           let accelerated = try makeSBSUsingKernel(from: rgb, depth: refinedDepth, strength: strength, tuning: options.depthTuning) {
            if isLikelyInvalidKernelOutput(accelerated, comparedTo: rgb) {
                kernelWarpIsHealthy = false
            } else {
                return accelerated
            }
        }

        switch options.viewSynthesis {
        case .inverseWarp:
            return try makeSBSUsingCPUInverseWarp(from: rgb, depth: refinedDepth, strength: strength, tuning: options.depthTuning)
        case .forwardWarp:
            return try makeSBSUsingCPUForwardWarp(from: rgb, depth: refinedDepth, strength: strength, tuning: options.depthTuning)
        }
    }

    func makeSBS(
        from rgb: CVPixelBuffer,
        depth: CVPixelBuffer,
        strength: Float,
        tuning: DepthTuning,
        engine: StereoRenderEngine
    ) throws -> CVPixelBuffer {
        var options = Stereo3DOptions()
        options.depthTuning = tuning
        options.renderEngine = engine
        return try makeSBS(from: rgb, depth: depth, strength: strength, options: options)
    }

    private func makeSBSUsingCPUInverseWarp(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float, tuning: DepthTuning) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)

        let sourceBytes = try bgraBytes(from: rgb)
        let depthMap = try normalizedDepthMap(from: depth, targetWidth: width, targetHeight: height, tuning: tuning)

        let clampedStrength = max(0, min(1.5, strength))
        let disparityScale = clampedStrength * Self.maxDisparity(forWidth: width, tuning: tuning)
        let disparity = depthMap.map { $0 * disparityScale }

        var left = [UInt8](repeating: 0, count: width * height * 4)
        var right = [UInt8](repeating: 0, count: width * height * 4)
        var leftMask = [UInt8](repeating: 0, count: width * height)
        var rightMask = [UInt8](repeating: 0, count: width * height)

        // Inverse warping from a single RGB frame + depth map to synthetic left/right views.
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width) + x
                let halfShift = disparity[idx] * 0.5

                if let sample = bilinearSample(from: sourceBytes, width: width, height: height, x: Float(x) + halfShift, y: Float(y)) {
                    writePixel(sample, into: &left, at: idx)
                    leftMask[idx] = 1
                }

                if let sample = bilinearSample(from: sourceBytes, width: width, height: height, x: Float(x) - halfShift, y: Float(y)) {
                    writePixel(sample, into: &right, at: idx)
                    rightMask[idx] = 1
                }
            }
        }

        fillHolesHorizontally(bytes: &left, mask: &leftMask, width: width, height: height)
        fillHolesHorizontally(bytes: &right, mask: &rightMask, width: width, height: height)
        if tuning == .enhanced {
            fillHolesVertically(bytes: &left, mask: &leftMask, width: width, height: height)
            fillHolesVertically(bytes: &right, mask: &rightMask, width: width, height: height)
        }

        return try assembleSBS(left: left, right: right, width: width, height: height)
    }

    private func makeSBSUsingCPUForwardWarp(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float, tuning: DepthTuning) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)

        let sourceBytes = try bgraBytes(from: rgb)
        let depthMap = try normalizedDepthMap(from: depth, targetWidth: width, targetHeight: height, tuning: tuning)

        let clampedStrength = max(0, min(1.5, strength))
        let disparityScale = clampedStrength * Self.maxDisparity(forWidth: width, tuning: tuning)

        var left = [UInt8](repeating: 0, count: width * height * 4)
        var right = [UInt8](repeating: 0, count: width * height * 4)
        var leftMask = [UInt8](repeating: 0, count: width * height)
        var rightMask = [UInt8](repeating: 0, count: width * height)
        var leftZ = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)
        var rightZ = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let srcIdx = (y * width) + x
                let z = depthMap[srcIdx]
                let halfShift = z * disparityScale * 0.5
                let srcPixel = pixel(sourceBytes, width: width, x: x, y: y)

                let destXL = Int((Float(x) - halfShift).rounded())
                if destXL >= 0, destXL < width {
                    let destIdx = (y * width) + destXL
                    if z > leftZ[destIdx] {
                        writePixel(srcPixel, into: &left, at: destIdx)
                        leftMask[destIdx] = 1
                        leftZ[destIdx] = z
                    }
                }

                let destXR = Int((Float(x) + halfShift).rounded())
                if destXR >= 0, destXR < width {
                    let destIdx = (y * width) + destXR
                    if z > rightZ[destIdx] {
                        writePixel(srcPixel, into: &right, at: destIdx)
                        rightMask[destIdx] = 1
                        rightZ[destIdx] = z
                    }
                }
            }
        }

        fillHolesHorizontally(bytes: &left, mask: &leftMask, width: width, height: height)
        fillHolesHorizontally(bytes: &right, mask: &rightMask, width: width, height: height)
        if tuning == .enhanced {
            fillHolesVertically(bytes: &left, mask: &leftMask, width: width, height: height)
            fillHolesVertically(bytes: &right, mask: &rightMask, width: width, height: height)
        }

        return try assembleSBS(left: left, right: right, width: width, height: height)
    }

    private func makeSBSServerLike(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float, options: Stereo3DOptions) throws -> CVPixelBuffer {
        let preset = RefinedServerPreset.forProfile(options.renderProfile)
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)
        let (depthProcessWidth, depthProcessHeight) = serverDepthProcessingSize(
            width: width,
            height: height,
            shortSideCap: min(options.depthQuality.shortSide, preset.depthShortSideCap)
        )

        let normalizedDepthInput: CVPixelBuffer
        if preset.guidedDepthRefinementEnabled {
            normalizedDepthInput = try refineDepthBufferIfNeeded(
                depth: depth,
                guide: rgb,
                targetWidth: depthProcessWidth,
                targetHeight: depthProcessHeight,
                refinement: .guidedFilter,
                tuning: .enhanced
            )
        } else {
            normalizedDepthInput = depth
        }

        let sourceBytes = try bgraBytes(from: rgb)
        var depthMap = try serverNormalizedDepthMap(
            from: normalizedDepthInput,
            targetWidth: depthProcessWidth,
            targetHeight: depthProcessHeight
        )
        depthMap = bilateralFilter(
            depthMap: depthMap,
            width: depthProcessWidth,
            height: depthProcessHeight,
            diameter: preset.bilateralDiameter,
            sigmaColor: preset.bilateralSigmaColor,
            sigmaSpace: preset.bilateralSigmaSpace
        )
        if preset.edgeFilteringEnabled {
            let edgeMask = cannyEdgeMask(
                depthMap: depthMap,
                width: depthProcessWidth,
                height: depthProcessHeight,
                lowThreshold: preset.cannyLowThreshold,
                highThreshold: preset.cannyHighThreshold
            )
            depthMap = smoothDepthAtEdges(
                depthMap: depthMap,
                edgeMask: edgeMask,
                width: depthProcessWidth,
                height: depthProcessHeight,
                kernelSize: preset.edgeKernelSize
            )
        }

        if depthProcessWidth != width || depthProcessHeight != height {
            depthMap = resizeDepthMap(
                depthMap,
                sourceWidth: depthProcessWidth,
                sourceHeight: depthProcessHeight,
                targetWidth: width,
                targetHeight: height
            )
        }
        if preset.depthEdgeFeatherEnabled {
            depthMap = featherDepthDiscontinuities(
                depthMap: depthMap,
                width: width,
                height: height,
                threshold: preset.depthEdgeFeatherThreshold,
                maxBlend: preset.depthEdgeFeatherStrength
            )
        }

        // Matches the server baseline disparity (per-eye shift) at strength=1.0.
        let clampedStrength = max(0, min(1.5, strength))
        let baselinePerEye = max(0, preset.baselinePerEye * clampedStrength)

        var left = [UInt8](repeating: 0, count: width * height * 4)
        var right = [UInt8](repeating: 0, count: width * height * 4)
        var leftMask = [UInt8](repeating: 0, count: width * height)
        var rightMask = [UInt8](repeating: 0, count: width * height)
        var leftZBuffer = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)
        var rightZBuffer = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)

        if preset.subpixelWarpEnabled {
            forwardWarpWithSubpixelShift(
                sourceBytes: sourceBytes,
                depthMap: depthMap,
                width: width,
                height: height,
                baselinePerEye: baselinePerEye,
                left: &left,
                right: &right,
                leftMask: &leftMask,
                rightMask: &rightMask,
                leftZBuffer: &leftZBuffer,
                rightZBuffer: &rightZBuffer
            )
        } else {
            forwardWarpWithIntegerShift(
                sourceBytes: sourceBytes,
                depthMap: depthMap,
                width: width,
                height: height,
                baselinePerEye: baselinePerEye,
                left: &left,
                right: &right,
                leftMask: &leftMask,
                rightMask: &rightMask,
                leftZBuffer: &leftZBuffer,
                rightZBuffer: &rightZBuffer
            )
        }

        for _ in 0..<preset.dilationIterations {
            asymmetricHorizontalDilationFill(
                bytes: &left,
                mask: &leftMask,
                width: width,
                height: height,
                maxRightOffset: preset.dilationMaxRightOffset
            )
            asymmetricHorizontalDilationFill(
                bytes: &right,
                mask: &rightMask,
                width: width,
                height: height,
                maxRightOffset: preset.dilationMaxRightOffset
            )
        }

        if leftMask.contains(0) {
            inpaintHolesTeleaLike(
                bytes: &left,
                mask: &leftMask,
                width: width,
                height: height,
                radius: preset.inpaintRadius,
                maxPasses: preset.inpaintPasses
            )
        }
        if rightMask.contains(0) {
            inpaintHolesTeleaLike(
                bytes: &right,
                mask: &rightMask,
                width: width,
                height: height,
                radius: preset.inpaintRadius,
                maxPasses: preset.inpaintPasses
            )
        }

        fillRemainingHolesWithSource(
            bytes: &left,
            mask: &leftMask,
            sourceBytes: sourceBytes,
            width: width,
            height: height
        )
        fillRemainingHolesWithSource(
            bytes: &right,
            mask: &rightMask,
            sourceBytes: sourceBytes,
            width: width,
            height: height
        )

        if preset.edgeSupersamplingEnabled {
            supersampleWarpEdges(
                bytes: &left,
                width: width,
                height: height,
                sourceBytes: sourceBytes,
                depthMap: depthMap,
                baselinePerEye: baselinePerEye,
                direction: -1,
                shiftGradientThreshold: preset.edgeSupersamplingShiftGradientThreshold,
                maxBlend: preset.edgeSupersamplingMaxBlend
            )
            supersampleWarpEdges(
                bytes: &right,
                width: width,
                height: height,
                sourceBytes: sourceBytes,
                depthMap: depthMap,
                baselinePerEye: baselinePerEye,
                direction: 1,
                shiftGradientThreshold: preset.edgeSupersamplingShiftGradientThreshold,
                maxBlend: preset.edgeSupersamplingMaxBlend
            )
        }

        if preset.outputEdgeAntiAliasEnabled {
            let shiftMap = depthMap.map { max(0, min(1, $0)) * baselinePerEye }
            // More AA is useful at higher strengths where integer shifts can look jaggier.
            let dynamicBlend = min(1, preset.outputEdgeAntiAliasStrength * (0.75 + (0.25 * clampedStrength)))
            antiAliasWarpEdges(
                bytes: &left,
                width: width,
                height: height,
                shiftMap: shiftMap,
                gradientThreshold: preset.outputEdgeAntiAliasThreshold,
                maxBlend: dynamicBlend
            )
            antiAliasWarpEdges(
                bytes: &right,
                width: width,
                height: height,
                shiftMap: shiftMap,
                gradientThreshold: preset.outputEdgeAntiAliasThreshold,
                maxBlend: dynamicBlend
            )
        }

        return try assembleSBS(left: left, right: right, width: width, height: height)
    }

    private func forwardWarpWithIntegerShift(
        sourceBytes: [UInt8],
        depthMap: [Float],
        width: Int,
        height: Int,
        baselinePerEye: Float,
        left: inout [UInt8],
        right: inout [UInt8],
        leftMask: inout [UInt8],
        rightMask: inout [UInt8],
        leftZBuffer: inout [Float],
        rightZBuffer: inout [Float]
    ) {
        // Fast integer-shift path keeps runtime low.
        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = (y * width) + x
                let depthValue = max(0, min(1, depthMap[sourceIndex]))
                let shift = Int(depthValue * baselinePerEye)

                let leftX = min(width - 1, x + shift)
                let rightX = max(0, x - shift)

                let sourcePixel = pixel(sourceBytes, width: width, x: x, y: y)
                let leftIndex = (y * width) + leftX
                let rightIndex = (y * width) + rightX

                if depthValue > leftZBuffer[leftIndex] {
                    writePixel(sourcePixel, into: &left, at: leftIndex)
                    leftMask[leftIndex] = 1
                    leftZBuffer[leftIndex] = depthValue
                }

                if depthValue > rightZBuffer[rightIndex] {
                    writePixel(sourcePixel, into: &right, at: rightIndex)
                    rightMask[rightIndex] = 1
                    rightZBuffer[rightIndex] = depthValue
                }
            }
        }
    }

    private func forwardWarpWithSubpixelShift(
        sourceBytes: [UInt8],
        depthMap: [Float],
        width: Int,
        height: Int,
        baselinePerEye: Float,
        left: inout [UInt8],
        right: inout [UInt8],
        leftMask: inout [UInt8],
        rightMask: inout [UInt8],
        leftZBuffer: inout [Float],
        rightZBuffer: inout [Float]
    ) {
        // Higher-quality path: subpixel splat to reduce stair-stepping on object edges.
        let pixelCount = width * height
        var leftSumB = [Float](repeating: 0, count: pixelCount)
        var leftSumG = [Float](repeating: 0, count: pixelCount)
        var leftSumR = [Float](repeating: 0, count: pixelCount)
        var leftSumA = [Float](repeating: 0, count: pixelCount)
        var leftWeights = [Float](repeating: 0, count: pixelCount)

        var rightSumB = [Float](repeating: 0, count: pixelCount)
        var rightSumG = [Float](repeating: 0, count: pixelCount)
        var rightSumR = [Float](repeating: 0, count: pixelCount)
        var rightSumA = [Float](repeating: 0, count: pixelCount)
        var rightWeights = [Float](repeating: 0, count: pixelCount)

        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = (y * width) + x
                let depthValue = max(0, min(1, depthMap[sourceIndex]))
                let shift = depthValue * baselinePerEye
                let sourcePixel = pixel(sourceBytes, width: width, x: x, y: y)

                splatPixelLinear(
                    pixel: sourcePixel,
                    depthValue: depthValue,
                    targetX: Float(x) + shift,
                    y: y,
                    width: width,
                    sumB: &leftSumB,
                    sumG: &leftSumG,
                    sumR: &leftSumR,
                    sumA: &leftSumA,
                    weights: &leftWeights,
                    zBuffer: &leftZBuffer,
                    mask: &leftMask
                )

                splatPixelLinear(
                    pixel: sourcePixel,
                    depthValue: depthValue,
                    targetX: Float(x) - shift,
                    y: y,
                    width: width,
                    sumB: &rightSumB,
                    sumG: &rightSumG,
                    sumR: &rightSumR,
                    sumA: &rightSumA,
                    weights: &rightWeights,
                    zBuffer: &rightZBuffer,
                    mask: &rightMask
                )
            }
        }

        resolveSplatAccumulation(
            bytes: &left,
            mask: leftMask,
            sumB: leftSumB,
            sumG: leftSumG,
            sumR: leftSumR,
            sumA: leftSumA,
            weights: leftWeights
        )
        resolveSplatAccumulation(
            bytes: &right,
            mask: rightMask,
            sumB: rightSumB,
            sumG: rightSumG,
            sumR: rightSumR,
            sumA: rightSumA,
            weights: rightWeights
        )
    }

    private func splatPixelLinear(
        pixel: (UInt8, UInt8, UInt8, UInt8),
        depthValue: Float,
        targetX: Float,
        y: Int,
        width: Int,
        sumB: inout [Float],
        sumG: inout [Float],
        sumR: inout [Float],
        sumA: inout [Float],
        weights: inout [Float],
        zBuffer: inout [Float],
        mask: inout [UInt8]
    ) {
        let clampedX = max(0, min(Float(width - 1), targetX))
        let lowerX = Int(floor(clampedX))
        let upperX = min(width - 1, lowerX + 1)
        let upperWeight = clampedX - Float(lowerX)
        let lowerWeight = 1 - upperWeight

        blendSplatContribution(
            pixel: pixel,
            depthValue: depthValue,
            x: lowerX,
            y: y,
            width: width,
            weight: lowerWeight,
            sumB: &sumB,
            sumG: &sumG,
            sumR: &sumR,
            sumA: &sumA,
            weights: &weights,
            zBuffer: &zBuffer,
            mask: &mask
        )

        if upperX != lowerX {
            blendSplatContribution(
                pixel: pixel,
                depthValue: depthValue,
                x: upperX,
                y: y,
                width: width,
                weight: upperWeight,
                sumB: &sumB,
                sumG: &sumG,
                sumR: &sumR,
                sumA: &sumA,
                weights: &weights,
                zBuffer: &zBuffer,
                mask: &mask
            )
        }
    }

    private func blendSplatContribution(
        pixel: (UInt8, UInt8, UInt8, UInt8),
        depthValue: Float,
        x: Int,
        y: Int,
        width: Int,
        weight: Float,
        sumB: inout [Float],
        sumG: inout [Float],
        sumR: inout [Float],
        sumA: inout [Float],
        weights: inout [Float],
        zBuffer: inout [Float],
        mask: inout [UInt8]
    ) {
        guard weight > 0.00001 else { return }

        let index = (y * width) + x
        let depthDelta = depthValue - zBuffer[index]

        if depthDelta > 0.0005 {
            zBuffer[index] = depthValue
            weights[index] = weight
            sumB[index] = Float(pixel.0) * weight
            sumG[index] = Float(pixel.1) * weight
            sumR[index] = Float(pixel.2) * weight
            sumA[index] = Float(pixel.3) * weight
            mask[index] = 1
            return
        }

        if abs(depthDelta) <= 0.02 {
            weights[index] += weight
            sumB[index] += Float(pixel.0) * weight
            sumG[index] += Float(pixel.1) * weight
            sumR[index] += Float(pixel.2) * weight
            sumA[index] += Float(pixel.3) * weight
            mask[index] = 1
        }
    }

    private func resolveSplatAccumulation(
        bytes: inout [UInt8],
        mask: [UInt8],
        sumB: [Float],
        sumG: [Float],
        sumR: [Float],
        sumA: [Float],
        weights: [Float]
    ) {
        for index in mask.indices where mask[index] == 1 {
            let weight = max(0.00001, weights[index])
            let offset = index * 4
            bytes[offset] = UInt8(max(0, min(255, Int((sumB[index] / weight).rounded()))))
            bytes[offset + 1] = UInt8(max(0, min(255, Int((sumG[index] / weight).rounded()))))
            bytes[offset + 2] = UInt8(max(0, min(255, Int((sumR[index] / weight).rounded()))))
            bytes[offset + 3] = UInt8(max(0, min(255, Int((sumA[index] / weight).rounded()))))
        }
    }

    private func assembleSBS(left: [UInt8], right: [UInt8], width: Int, height: Int) throws -> CVPixelBuffer {
        var sbs = [UInt8](repeating: 0, count: width * 2 * height * 4)
        let destinationWidth = width * 2

        for y in 0..<height {
            let leftRowStart = y * width * 4
            let rightRowStart = leftRowStart
            let destinationRowStart = y * destinationWidth * 4

            sbs[destinationRowStart..<(destinationRowStart + (width * 4))] = left[leftRowStart..<(leftRowStart + (width * 4))]
            sbs[(destinationRowStart + (width * 4))..<(destinationRowStart + (destinationWidth * 4))] = right[rightRowStart..<(rightRowStart + (width * 4))]
        }

        let outputBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: destinationWidth,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let rowSize = destinationWidth * 4
        let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        for y in 0..<height {
            let rowStart = y * rowSize
            let destinationRow = pointer.advanced(by: y * bytesPerRow)
            sbs.withUnsafeBufferPointer { buffer in
                guard let source = buffer.baseAddress?.advanced(by: rowStart) else { return }
                destinationRow.assign(from: source, count: rowSize)
            }
        }

        return outputBuffer
    }

    private func makeSBSUsingKernel(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float, tuning: DepthTuning) throws -> CVPixelBuffer? {
        guard let kernel = Self.stereoWarpKernel else {
            return nil
        }

        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)
        let clampedStrength = max(0, min(1.5, strength))
        let maxShift = CGFloat(clampedStrength * Self.maxDisparity(forWidth: width, tuning: tuning) * 0.5)
        let depthImage = try prepareDepthImageForKernel(from: depth, targetWidth: width, targetHeight: height)
        let stats = try depthStatistics(from: depthImage, width: width, height: height, tuning: tuning)
        let range = max(stats.max - stats.min, 0.0001)
        let invRange = CGFloat(1 / range)
        let invertDepth = stats.shouldInvert ? CGFloat(1) : CGFloat(0)
        let gamma = tuning == .enhanced ? CGFloat(0.78) : CGFloat(1)

        let colorImage = CIImage(cvPixelBuffer: rgb)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let roiInset = maxShift + 2

        guard let left = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in
                rect.insetBy(dx: -roiInset, dy: 0)
            },
            arguments: [colorImage, depthImage, CGFloat(1), maxShift, CGFloat(stats.min), invRange, invertDepth, gamma]
        ) else {
            return nil
        }

        guard let right = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in
                rect.insetBy(dx: -roiInset, dy: 0)
            },
            arguments: [colorImage, depthImage, CGFloat(-1), maxShift, CGFloat(stats.min), invRange, invertDepth, gamma]
        ) else {
            return nil
        }

        let canvasExtent = CGRect(x: 0, y: 0, width: width * 2, height: height)
        let canvas = CIImage(color: .black).cropped(to: canvasExtent)
        let rightPlaced = right.transformed(by: CGAffineTransform(translationX: CGFloat(width), y: 0))
        let combined = rightPlaced.composited(over: left.composited(over: canvas))

        let outputBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: width * 2,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        ciContext.render(combined, to: outputBuffer, bounds: canvasExtent, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Force Core Image GPU work to be materialized before the writer consumes the buffer.
        CVPixelBufferLockBaseAddress(outputBuffer, .readOnly)
        CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly)
        return outputBuffer
    }

    private func isLikelyInvalidKernelOutput(_ output: CVPixelBuffer, comparedTo source: CVPixelBuffer) -> Bool {
        guard
            let sourceLuma = approximateLuma(of: source),
            let outputLuma = approximateLuma(of: output)
        else {
            return false
        }

        return sourceLuma > 0.04 && outputLuma < 0.003
    }

    private func approximateLuma(of pixelBuffer: CVPixelBuffer) -> Float? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        let sampleColumns = 8
        let sampleRows = 8
        let xStep = max(1, width / sampleColumns)
        let yStep = max(1, height / sampleRows)

        var sum: Float = 0
        var count = 0

        var y = 0
        while y < height {
            let row = pointer.advanced(by: y * bytesPerRow)
            var x = 0
            while x < width {
                let offset = x * 4
                let b = Float(row[offset]) / 255
                let g = Float(row[offset + 1]) / 255
                let r = Float(row[offset + 2]) / 255
                let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
                sum += luma
                count += 1
                x += xStep
            }
            y += yStep
        }

        guard count > 0 else {
            return nil
        }
        return sum / Float(count)
    }

    private func prepareDepthImageForKernel(from depthBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) throws -> CIImage {
        let preparedDepth: CVPixelBuffer

        if CVPixelBufferGetWidth(depthBuffer) == targetWidth && CVPixelBufferGetHeight(depthBuffer) == targetHeight {
            preparedDepth = depthBuffer
        } else {
            preparedDepth = try PixelBufferUtilities.resize(
                depthBuffer,
                to: CGSize(width: targetWidth, height: targetHeight),
                context: ciContext
            )
        }

        let extent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let format = CVPixelBufferGetPixelFormatType(preparedDepth)
        let image = CIImage(cvPixelBuffer: preparedDepth).cropped(to: extent)
        if format == kCVPixelFormatType_OneComponent8 {
            return image
        }

        return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
    }

    private func depthStatistics(from depthImage: CIImage, width: Int, height: Int, tuning: DepthTuning) throws -> (min: Float, max: Float, shouldInvert: Bool) {
        let analysisWidth = max(24, min(160, width))
        let analysisHeight = max(24, min(160, height))
        let sx = CGFloat(analysisWidth) / max(CGFloat(width), 1)
        let sy = CGFloat(analysisHeight) / max(CGFloat(height), 1)
        let sampled = depthImage
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: analysisWidth, height: analysisHeight))

        let analysisBuffer = try PixelBufferUtilities.makePixelBuffer(
            width: analysisWidth,
            height: analysisHeight,
            pixelFormat: kCVPixelFormatType_OneComponent8
        )
        ciContext.render(
            sampled,
            to: analysisBuffer,
            bounds: CGRect(x: 0, y: 0, width: analysisWidth, height: analysisHeight),
            colorSpace: CGColorSpaceCreateDeviceGray()
        )

        CVPixelBufferLockBaseAddress(analysisBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(analysisBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(analysisBuffer) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(analysisBuffer)
        let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * analysisHeight)

        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        var histogram = [Int](repeating: 0, count: 256)

        var borderSum: Float = 0
        var borderCount = 0
        var centerSum: Float = 0
        var centerCount = 0

        let centerXStart = analysisWidth / 4
        let centerXEnd = max(centerXStart + 1, (analysisWidth * 3) / 4)
        let centerYStart = analysisHeight / 4
        let centerYEnd = max(centerYStart + 1, (analysisHeight * 3) / 4)

        for y in 0..<analysisHeight {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<analysisWidth {
                let value = Float(row[x]) / 255
                histogram[Int(row[x])] += 1
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)

                if x == 0 || y == 0 || x == analysisWidth - 1 || y == analysisHeight - 1 {
                    borderSum += value
                    borderCount += 1
                }

                if x >= centerXStart, x < centerXEnd, y >= centerYStart, y < centerYEnd {
                    centerSum += value
                    centerCount += 1
                }
            }
        }

        if !minValue.isFinite || !maxValue.isFinite {
            minValue = 0
            maxValue = 1
        }

        if tuning == .enhanced {
            let totalCount = analysisWidth * analysisHeight
            let lowTarget = max(0, Int((Double(totalCount) * 0.02).rounded(.down)))
            let highTarget = min(totalCount, Int((Double(totalCount) * 0.98).rounded(.down)))

            let (lowBin, highBin) = histogramPercentiles(histogram, lowTarget: lowTarget, highTarget: highTarget)
            let lowValue = Float(lowBin) / 255
            let highValue = Float(highBin) / 255
            if highValue > lowValue {
                minValue = lowValue
                maxValue = highValue
            }
        }

        let borderMean = borderSum / Float(max(borderCount, 1))
        let centerMean = centerSum / Float(max(centerCount, 1))
        return (min: minValue, max: maxValue, shouldInvert: borderMean > centerMean)
    }

    private func normalizedDepthMap(from depthBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int, tuning: DepthTuning) throws -> [Float] {
        let preparedDepth: CVPixelBuffer

        if CVPixelBufferGetWidth(depthBuffer) == targetWidth && CVPixelBufferGetHeight(depthBuffer) == targetHeight {
            preparedDepth = depthBuffer
        } else {
            preparedDepth = try PixelBufferUtilities.resize(depthBuffer, to: CGSize(width: targetWidth, height: targetHeight), context: ciContext)
        }

        CVPixelBufferLockBaseAddress(preparedDepth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(preparedDepth, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(preparedDepth) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let width = CVPixelBufferGetWidth(preparedDepth)
        let height = CVPixelBufferGetHeight(preparedDepth)
        let format = CVPixelBufferGetPixelFormatType(preparedDepth)

        var map = [Float](repeating: 0, count: width * height)
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        var histogram = [Int](repeating: 0, count: 256)

        if format == kCVPixelFormatType_OneComponent8 {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(preparedDepth)
            let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

            for y in 0..<height {
                let row = pointer.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let value = Float(row[x]) / 255
                    histogram[Int(row[x])] += 1
                    map[(y * width) + x] = value
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
            }
        } else {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(preparedDepth)
            let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

            for y in 0..<height {
                let row = pointer.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let offset = x * 4
                    let b = Float(row[offset]) / 255
                    let g = Float(row[offset + 1]) / 255
                    let r = Float(row[offset + 2]) / 255
                    let value = (0.299 * r) + (0.587 * g) + (0.114 * b)
                    let bin = max(0, min(255, Int((value * 255).rounded())))
                    histogram[bin] += 1
                    map[(y * width) + x] = value
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
            }
        }

        if tuning == .enhanced {
            let totalCount = width * height
            let lowTarget = max(0, Int((Double(totalCount) * 0.02).rounded(.down)))
            let highTarget = min(totalCount, Int((Double(totalCount) * 0.98).rounded(.down)))

            let (lowBin, highBin) = histogramPercentiles(histogram, lowTarget: lowTarget, highTarget: highTarget)
            let lowValue = Float(lowBin) / 255
            let highValue = Float(highBin) / 255
            if highValue > lowValue {
                minValue = lowValue
                maxValue = highValue
            }
        }

        let range = max(maxValue - minValue, 0.0001)
        for index in map.indices {
            let clipped = max(minValue, min(maxValue, map[index]))
            map[index] = (clipped - minValue) / range
        }

        boxBlur(&map, width: width, height: height)

        let borderMean = meanBorderDepth(map, width: width, height: height)
        let centerMean = meanCenterDepth(map, width: width, height: height)

        // If borders appear "closer" than the center, flip depth orientation heuristically.
        if borderMean > centerMean {
            for index in map.indices {
                map[index] = 1 - map[index]
            }
        }

        if tuning == .enhanced {
            for index in map.indices {
                map[index] = pow(max(0, min(1, map[index])), 0.78)
            }
        }

        return map
    }

    private func serverNormalizedDepthMap(from depthBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) throws -> [Float] {
        let preparedDepth: CVPixelBuffer
        if CVPixelBufferGetWidth(depthBuffer) == targetWidth && CVPixelBufferGetHeight(depthBuffer) == targetHeight {
            preparedDepth = depthBuffer
        } else {
            // This produces BGRA, which is fine for extracting grayscale depth values.
            preparedDepth = try PixelBufferUtilities.resize(depthBuffer, to: CGSize(width: targetWidth, height: targetHeight), context: ciContext)
        }

        CVPixelBufferLockBaseAddress(preparedDepth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(preparedDepth, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(preparedDepth) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let width = CVPixelBufferGetWidth(preparedDepth)
        let height = CVPixelBufferGetHeight(preparedDepth)
        let format = CVPixelBufferGetPixelFormatType(preparedDepth)

        var map = [Float](repeating: 0, count: width * height)
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude

        if format == kCVPixelFormatType_OneComponent8 {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(preparedDepth)
            let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let value = Float(row[x]) / 255
                    map[(y * width) + x] = value
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
            }
        } else {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(preparedDepth)
            let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let offset = x * 4
                    let b = Float(row[offset]) / 255
                    let g = Float(row[offset + 1]) / 255
                    let r = Float(row[offset + 2]) / 255
                    let value = (0.299 * r) + (0.587 * g) + (0.114 * b)
                    map[(y * width) + x] = value
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
            }
        }

        let range = max(maxValue - minValue, 0.000001)
        for index in map.indices {
            map[index] = max(0, min(1, (map[index] - minValue) / range))
        }

        return map
    }

    private func refineDepthBufferIfNeeded(
        depth: CVPixelBuffer,
        guide: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        refinement: DepthRefinement,
        tuning: DepthTuning
    ) throws -> CVPixelBuffer {
        if refinement == .none {
            if CVPixelBufferGetWidth(depth) == targetWidth, CVPixelBufferGetHeight(depth) == targetHeight {
                return depth
            }
            return try PixelBufferUtilities.resize(depth, to: CGSize(width: targetWidth, height: targetHeight), context: ciContext)
        }

        let extent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let guideImage = CIImage(cvPixelBuffer: guide).cropped(to: extent)
        var workingDepthImage = try prepareDepthImageForKernel(from: depth, targetWidth: targetWidth, targetHeight: targetHeight)
            .cropped(to: extent)

        let wantsGuidedFilter = refinement == .guidedFilter || refinement == .guidedFilterAndPersonMask
        let wantsPersonMask = refinement == .personMask || refinement == .guidedFilterAndPersonMask

        if wantsGuidedFilter {
            if let guided = guidedDepthImage(depthImage: workingDepthImage, guideImage: guideImage, width: targetWidth, tuning: tuning) {
                workingDepthImage = guided.cropped(to: extent)
            }
        }

        if wantsPersonMask {
            if let personMask = try? makePersonMask(from: guide, targetWidth: targetWidth, targetHeight: targetHeight) {
                var maskImage = CIImage(cvPixelBuffer: personMask).cropped(to: extent)

                // Expand the foreground region slightly so edges are less likely to halo.
                if let dilated = CIFilter(
                    name: "CIMorphologyMaximum",
                    parameters: [
                        kCIInputImageKey: maskImage,
                        kCIInputRadiusKey: CGFloat(3)
                    ]
                )?.outputImage {
                    maskImage = dilated.cropped(to: extent)
                }

                let blurRadius = CGFloat(max(6, min(18, targetWidth / 90)))
                let blurred = workingDepthImage
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                    .cropped(to: extent)

                if let blended = CIFilter(
                    name: "CIBlendWithMask",
                    parameters: [
                        kCIInputImageKey: workingDepthImage,
                        kCIInputBackgroundImageKey: blurred,
                        kCIInputMaskImageKey: maskImage
                    ]
                )?.outputImage {
                    workingDepthImage = blended.cropped(to: extent)
                }
            }
        }

        let output = try PixelBufferUtilities.makePixelBuffer(
            width: targetWidth,
            height: targetHeight,
            pixelFormat: kCVPixelFormatType_OneComponent8
        )
        ciContext.render(workingDepthImage, to: output, bounds: extent, colorSpace: CGColorSpaceCreateDeviceGray())
        return output
    }

    private func guidedDepthImage(depthImage: CIImage, guideImage: CIImage, width: Int, tuning: DepthTuning) -> CIImage? {
        guard let filter = CIFilter(name: "CIGuidedFilter") else {
            return nil
        }

        let radius = CGFloat(max(4, min(20, width / 120)))
        let epsilon: CGFloat = tuning == .enhanced ? 0.0025 : 0.005

        filter.setValue(depthImage, forKey: kCIInputImageKey)
        filter.setValue(guideImage, forKey: "inputGuideImage")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(epsilon, forKey: "inputEpsilon")
        return filter.outputImage
    }

    private func makePersonMask(from guide: CVPixelBuffer, targetWidth: Int, targetHeight: Int) throws -> CVPixelBuffer? {
        if #available(iOS 15.0, macOS 12.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8

            let handler = VNImageRequestHandler(cvPixelBuffer: guide, orientation: .up, options: [:])
            try handler.perform([request])

            guard let observation = request.results?.first as? VNPixelBufferObservation else {
                return nil
            }

            let maskBuffer = observation.pixelBuffer
            if CVPixelBufferGetWidth(maskBuffer) == targetWidth, CVPixelBufferGetHeight(maskBuffer) == targetHeight {
                return maskBuffer
            }

            let maskExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            let maskImage = CIImage(cvPixelBuffer: maskBuffer)
            let sx = CGFloat(targetWidth) / max(maskImage.extent.width, 1)
            let sy = CGFloat(targetHeight) / max(maskImage.extent.height, 1)
            let scaled = maskImage
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: maskExtent)

            let output = try PixelBufferUtilities.makePixelBuffer(
                width: targetWidth,
                height: targetHeight,
                pixelFormat: kCVPixelFormatType_OneComponent8
            )
            ciContext.render(scaled, to: output, bounds: maskExtent, colorSpace: CGColorSpaceCreateDeviceGray())
            return output
        }

        return nil
    }

    private func bgraBytes(from pixelBuffer: CVPixelBuffer) throws -> [UInt8] {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let source: CVPixelBuffer
        if format == kCVPixelFormatType_32BGRA {
            source = pixelBuffer
        } else {
            source = try PixelBufferUtilities.resize(pixelBuffer, to: CGSize(width: width, height: height), context: ciContext)
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(source) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let pointer = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        var output = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            let sourceRow = pointer.advanced(by: y * bytesPerRow)
            let destinationStart = y * width * 4
            for x in 0..<width {
                let sourceOffset = x * 4
                let destinationOffset = destinationStart + sourceOffset
                output[destinationOffset] = sourceRow[sourceOffset]
                output[destinationOffset + 1] = sourceRow[sourceOffset + 1]
                output[destinationOffset + 2] = sourceRow[sourceOffset + 2]
                output[destinationOffset + 3] = sourceRow[sourceOffset + 3]
            }
        }

        return output
    }

    private func bilinearSample(
        from bytes: [UInt8],
        width: Int,
        height: Int,
        x: Float,
        y: Float
    ) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard x >= 0, y >= 0, x <= Float(width - 1), y <= Float(height - 1) else {
            return nil
        }

        let x0 = Int(floor(x))
        let x1 = min(x0 + 1, width - 1)
        let y0 = Int(floor(y))
        let y1 = min(y0 + 1, height - 1)

        let fx = x - Float(x0)
        let fy = y - Float(y0)

        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy

        let p00 = pixel(bytes, width: width, x: x0, y: y0)
        let p10 = pixel(bytes, width: width, x: x1, y: y0)
        let p01 = pixel(bytes, width: width, x: x0, y: y1)
        let p11 = pixel(bytes, width: width, x: x1, y: y1)

        let b = (Float(p00.0) * w00) + (Float(p10.0) * w10) + (Float(p01.0) * w01) + (Float(p11.0) * w11)
        let g = (Float(p00.1) * w00) + (Float(p10.1) * w10) + (Float(p01.1) * w01) + (Float(p11.1) * w11)
        let r = (Float(p00.2) * w00) + (Float(p10.2) * w10) + (Float(p01.2) * w01) + (Float(p11.2) * w11)
        let a = (Float(p00.3) * w00) + (Float(p10.3) * w10) + (Float(p01.3) * w01) + (Float(p11.3) * w11)

        return (
            UInt8(max(0, min(255, Int(b.rounded())))),
            UInt8(max(0, min(255, Int(g.rounded())))),
            UInt8(max(0, min(255, Int(r.rounded())))),
            UInt8(max(0, min(255, Int(a.rounded()))))
        )
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let offset = ((y * width) + x) * 4
        return (
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3]
        )
    }

    private func writePixel(_ pixel: (UInt8, UInt8, UInt8, UInt8), into destination: inout [UInt8], at index: Int) {
        let offset = index * 4
        destination[offset] = pixel.0
        destination[offset + 1] = pixel.1
        destination[offset + 2] = pixel.2
        destination[offset + 3] = pixel.3
    }

    private func serverDepthProcessingSize(width: Int, height: Int, shortSideCap: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (max(width, 1), max(height, 1)) }
        let shortSide = min(width, height)
        let cap = max(32, shortSideCap)
        guard shortSide > cap else {
            return (width, height)
        }

        let scale = Float(cap) / Float(shortSide)
        let scaledWidth = max(1, Int((Float(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Float(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    private func resizeDepthMap(
        _ depthMap: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [Float] {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return depthMap
        }
        if sourceWidth == targetWidth, sourceHeight == targetHeight {
            return depthMap
        }

        var output = [Float](repeating: 0, count: targetWidth * targetHeight)
        let scaleX = Float(sourceWidth) / Float(targetWidth)
        let scaleY = Float(sourceHeight) / Float(targetHeight)

        for y in 0..<targetHeight {
            let fy = (Float(y) + 0.5) * scaleY - 0.5
            let y0 = max(0, min(sourceHeight - 1, Int(floor(fy))))
            let y1 = min(sourceHeight - 1, y0 + 1)
            let wy = max(0, min(1, fy - Float(y0)))

            for x in 0..<targetWidth {
                let fx = (Float(x) + 0.5) * scaleX - 0.5
                let x0 = max(0, min(sourceWidth - 1, Int(floor(fx))))
                let x1 = min(sourceWidth - 1, x0 + 1)
                let wx = max(0, min(1, fx - Float(x0)))

                let v00 = depthMap[(y0 * sourceWidth) + x0]
                let v10 = depthMap[(y0 * sourceWidth) + x1]
                let v01 = depthMap[(y1 * sourceWidth) + x0]
                let v11 = depthMap[(y1 * sourceWidth) + x1]

                let top = (v00 * (1 - wx)) + (v10 * wx)
                let bottom = (v01 * (1 - wx)) + (v11 * wx)
                output[(y * targetWidth) + x] = (top * (1 - wy)) + (bottom * wy)
            }
        }

        return output
    }

    private func bilateralFilter(
        depthMap: [Float],
        width: Int,
        height: Int,
        diameter: Int,
        sigmaColor: Float,
        sigmaSpace: Float
    ) -> [Float] {
        guard width > 0, height > 0 else { return depthMap }

        let kernelSize = max(1, diameter | 1)
        let radius = kernelSize / 2
        let colorSigmaNormalized = max(0.0001, sigmaColor / 255)
        let colorDenominator = 2 * colorSigmaNormalized * colorSigmaNormalized
        let spaceSigma = max(0.0001, sigmaSpace)
        let spaceDenominator = 2 * spaceSigma * spaceSigma

        var spatialWeights = [Float](repeating: 0, count: kernelSize * kernelSize)
        for ky in -radius...radius {
            for kx in -radius...radius {
                let index = (ky + radius) * kernelSize + (kx + radius)
                let distanceSquared = Float((kx * kx) + (ky * ky))
                spatialWeights[index] = expf(-distanceSquared / spaceDenominator)
            }
        }

        var output = depthMap
        for y in 0..<height {
            for x in 0..<width {
                let centerIndex = (y * width) + x
                let centerValue = depthMap[centerIndex]

                var weightedSum: Float = 0
                var totalWeight: Float = 0

                let yStart = max(0, y - radius)
                let yEnd = min(height - 1, y + radius)
                let xStart = max(0, x - radius)
                let xEnd = min(width - 1, x + radius)

                for ny in yStart...yEnd {
                    let ky = ny - y + radius
                    for nx in xStart...xEnd {
                        let kx = nx - x + radius
                        let neighborIndex = (ny * width) + nx
                        let neighborValue = depthMap[neighborIndex]
                        let diff = neighborValue - centerValue
                        let colorWeight = expf(-(diff * diff) / colorDenominator)
                        let spatialWeight = spatialWeights[(ky * kernelSize) + kx]
                        let weight = colorWeight * spatialWeight
                        weightedSum += neighborValue * weight
                        totalWeight += weight
                    }
                }

                if totalWeight > 0 {
                    output[centerIndex] = weightedSum / totalWeight
                } else {
                    output[centerIndex] = centerValue
                }
            }
        }

        return output
    }

    private func cannyEdgeMask(
        depthMap: [Float],
        width: Int,
        height: Int,
        lowThreshold: Float,
        highThreshold: Float
    ) -> [UInt8] {
        guard width > 2, height > 2 else {
            return [UInt8](repeating: 0, count: width * height)
        }

        let low = max(0, lowThreshold)
        let high = max(low, highThreshold)
        var state = [UInt8](repeating: 0, count: width * height)

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let tl = depthMap[((y - 1) * width) + (x - 1)] * 255
                let tc = depthMap[((y - 1) * width) + x] * 255
                let tr = depthMap[((y - 1) * width) + (x + 1)] * 255
                let ml = depthMap[(y * width) + (x - 1)] * 255
                let mr = depthMap[(y * width) + (x + 1)] * 255
                let bl = depthMap[((y + 1) * width) + (x - 1)] * 255
                let bc = depthMap[((y + 1) * width) + x] * 255
                let br = depthMap[((y + 1) * width) + (x + 1)] * 255

                let gx = (-tl + tr) + (-2 * ml + 2 * mr) + (-bl + br)
                let gy = (-tl - 2 * tc - tr) + (bl + 2 * bc + br)
                let magnitude = sqrtf((gx * gx) + (gy * gy))
                let index = (y * width) + x

                if magnitude >= high {
                    state[index] = 2
                } else if magnitude >= low {
                    state[index] = 1
                }
            }
        }

        var edgeMask = [UInt8](repeating: 0, count: width * height)
        var stack = [Int]()
        stack.reserveCapacity((width * height) / 16)

        for index in state.indices where state[index] == 2 {
            edgeMask[index] = 1
            stack.append(index)
        }

        while let current = stack.popLast() {
            let y = current / width
            let x = current % width

            let yStart = max(1, y - 1)
            let yEnd = min(height - 2, y + 1)
            let xStart = max(1, x - 1)
            let xEnd = min(width - 2, x + 1)

            for ny in yStart...yEnd {
                for nx in xStart...xEnd {
                    let neighbor = (ny * width) + nx
                    if edgeMask[neighbor] == 0, state[neighbor] == 1 {
                        edgeMask[neighbor] = 1
                        stack.append(neighbor)
                    }
                }
            }
        }

        return edgeMask
    }

    private func smoothDepthAtEdges(
        depthMap: [Float],
        edgeMask: [UInt8],
        width: Int,
        height: Int,
        kernelSize: Int
    ) -> [Float] {
        guard width > 0, height > 0 else { return depthMap }

        let clampedKernel = max(1, kernelSize | 1)
        let radius = clampedKernel / 2
        guard radius > 0 else { return depthMap }

        var output = depthMap

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                guard edgeMask[index] == 1 else {
                    continue
                }

                var sum: Float = 0
                var count: Float = 0
                let yStart = max(0, y - radius)
                let yEnd = min(height - 1, y + radius)
                let xStart = max(0, x - radius)
                let xEnd = min(width - 1, x + radius)

                for ny in yStart...yEnd {
                    for nx in xStart...xEnd {
                        sum += depthMap[(ny * width) + nx]
                        count += 1
                    }
                }

                if count > 0 {
                    output[index] = sum / count
                }
            }
        }

        return output
    }

    private func asymmetricHorizontalDilationFill(
        bytes: inout [UInt8],
        mask: inout [UInt8],
        width: Int,
        height: Int,
        maxRightOffset: Int
    ) {
        let sourceBytes = bytes
        let sourceMask = mask
        let maxOffset = max(0, maxRightOffset)

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                guard sourceMask[index] == 0 else {
                    continue
                }

                for offset in 0...maxOffset {
                    let nx = x + offset
                    if nx >= width {
                        break
                    }
                    let neighborIndex = (y * width) + nx
                    guard sourceMask[neighborIndex] == 1 else {
                        continue
                    }

                    let sourceOffset = neighborIndex * 4
                    let destinationOffset = index * 4
                    bytes[destinationOffset] = sourceBytes[sourceOffset]
                    bytes[destinationOffset + 1] = sourceBytes[sourceOffset + 1]
                    bytes[destinationOffset + 2] = sourceBytes[sourceOffset + 2]
                    bytes[destinationOffset + 3] = sourceBytes[sourceOffset + 3]
                    mask[index] = 1
                    break
                }
            }
        }
    }

    private func inpaintHolesTeleaLike(
        bytes: inout [UInt8],
        mask: inout [UInt8],
        width: Int,
        height: Int,
        radius: Int,
        maxPasses: Int
    ) {
        let clampedRadius = max(1, radius)
        let radiusSquared = clampedRadius * clampedRadius
        let clampedPasses = max(1, maxPasses)

        for _ in 0..<clampedPasses {
            var didFillAny = false
            let sourceBytes = bytes
            let sourceMask = mask

            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width) + x
                    guard sourceMask[index] == 0 else {
                        continue
                    }

                    var sumB: Float = 0
                    var sumG: Float = 0
                    var sumR: Float = 0
                    var sumA: Float = 0
                    var sumWeight: Float = 0

                    let yStart = max(0, y - clampedRadius)
                    let yEnd = min(height - 1, y + clampedRadius)
                    let xStart = max(0, x - clampedRadius)
                    let xEnd = min(width - 1, x + clampedRadius)

                    for ny in yStart...yEnd {
                        for nx in xStart...xEnd {
                            let dx = nx - x
                            let dy = ny - y
                            let distanceSquared = (dx * dx) + (dy * dy)
                            if distanceSquared == 0 || distanceSquared > radiusSquared {
                                continue
                            }

                            let neighborIndex = (ny * width) + nx
                            guard sourceMask[neighborIndex] == 1 else {
                                continue
                            }

                            let weight = 1 / (1 + sqrtf(Float(distanceSquared)))
                            let sourceOffset = neighborIndex * 4
                            sumB += Float(sourceBytes[sourceOffset]) * weight
                            sumG += Float(sourceBytes[sourceOffset + 1]) * weight
                            sumR += Float(sourceBytes[sourceOffset + 2]) * weight
                            sumA += Float(sourceBytes[sourceOffset + 3]) * weight
                            sumWeight += weight
                        }
                    }

                    guard sumWeight > 0 else {
                        continue
                    }

                    let destinationOffset = index * 4
                    bytes[destinationOffset] = UInt8(max(0, min(255, Int((sumB / sumWeight).rounded()))))
                    bytes[destinationOffset + 1] = UInt8(max(0, min(255, Int((sumG / sumWeight).rounded()))))
                    bytes[destinationOffset + 2] = UInt8(max(0, min(255, Int((sumR / sumWeight).rounded()))))
                    bytes[destinationOffset + 3] = UInt8(max(0, min(255, Int((sumA / sumWeight).rounded()))))
                    mask[index] = 1
                    didFillAny = true
                }
            }

            if !didFillAny {
                break
            }
        }
    }

    private func fillRemainingHolesWithSource(
        bytes: inout [UInt8],
        mask: inout [UInt8],
        sourceBytes: [UInt8],
        width: Int,
        height: Int
    ) {
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                guard mask[index] == 0 else {
                    continue
                }
                let sourceOffset = index * 4
                bytes[sourceOffset] = sourceBytes[sourceOffset]
                bytes[sourceOffset + 1] = sourceBytes[sourceOffset + 1]
                bytes[sourceOffset + 2] = sourceBytes[sourceOffset + 2]
                bytes[sourceOffset + 3] = sourceBytes[sourceOffset + 3]
                mask[index] = 1
            }
        }
    }

    private func supersampleWarpEdges(
        bytes: inout [UInt8],
        width: Int,
        height: Int,
        sourceBytes: [UInt8],
        depthMap: [Float],
        baselinePerEye: Float,
        direction: Float,
        shiftGradientThreshold: Float,
        maxBlend: Float
    ) {
        guard width > 2, height > 2 else { return }
        guard depthMap.count == width * height else { return }
        guard sourceBytes.count == width * height * 4 else { return }

        let safeThreshold = max(0.0001, shiftGradientThreshold)
        let safeMaxBlend = max(0, min(1, maxBlend))
        guard safeMaxBlend > 0 else { return }

        // 2x2 jitter around the inverse-warp sample point reduces jaggies without large supersampled buffers.
        let jitter: Float = min(0.5, max(0.25, baselinePerEye * 0.00715))
        let halfThreshold = safeThreshold * 2

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = (y * width) + x
                let gx = abs(depthMap[index + 1] - depthMap[index - 1]) * baselinePerEye
                let gy = abs(depthMap[index + width] - depthMap[index - width]) * baselinePerEye
                let edgeScore = max(gx, gy)
                guard edgeScore > safeThreshold else {
                    continue
                }

                let depthValue = max(0, min(1, depthMap[index]))
                let shift = depthValue * baselinePerEye
                let sourceX = Float(x) + (direction * shift)
                let sourceY = Float(y)

                var sumB: Float = 0
                var sumG: Float = 0
                var sumR: Float = 0
                var sumA: Float = 0
                var count: Float = 0

                let positions: [(Float, Float)] = [
                    (sourceX - jitter, sourceY - jitter),
                    (sourceX + jitter, sourceY - jitter),
                    (sourceX - jitter, sourceY + jitter),
                    (sourceX + jitter, sourceY + jitter)
                ]

                for (sx, sy) in positions {
                    if let sample = bilinearSample(from: sourceBytes, width: width, height: height, x: sx, y: sy) {
                        sumB += Float(sample.0)
                        sumG += Float(sample.1)
                        sumR += Float(sample.2)
                        sumA += Float(sample.3)
                        count += 1
                    }
                }

                guard count > 0 else {
                    continue
                }

                let inv = 1 / count
                let targetB = sumB * inv
                let targetG = sumG * inv
                let targetR = sumR * inv
                let targetA = sumA * inv

                let normalized = min(1, (edgeScore - safeThreshold) / halfThreshold)
                let blend = safeMaxBlend * (0.25 + (0.75 * normalized))

                let offset = index * 4
                let oldB = Float(bytes[offset])
                let oldG = Float(bytes[offset + 1])
                let oldR = Float(bytes[offset + 2])
                let oldA = Float(bytes[offset + 3])

                bytes[offset] = UInt8(max(0, min(255, Int(((oldB * (1 - blend)) + (targetB * blend)).rounded()))))
                bytes[offset + 1] = UInt8(max(0, min(255, Int(((oldG * (1 - blend)) + (targetG * blend)).rounded()))))
                bytes[offset + 2] = UInt8(max(0, min(255, Int(((oldR * (1 - blend)) + (targetR * blend)).rounded()))))
                bytes[offset + 3] = UInt8(max(0, min(255, Int(((oldA * (1 - blend)) + (targetA * blend)).rounded()))))
            }
        }
    }

    private func featherDepthDiscontinuities(
        depthMap: [Float],
        width: Int,
        height: Int,
        threshold: Float,
        maxBlend: Float
    ) -> [Float] {
        guard width > 2, height > 2 else { return depthMap }

        let source = depthMap
        var output = depthMap
        let safeThreshold = max(0.0001, threshold)
        let safeMaxBlend = max(0, min(1, maxBlend))

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = (y * width) + x
                let gx = abs(source[index + 1] - source[index - 1])
                let gy = abs(source[index + width] - source[index - width])
                let edgeScore = max(gx, gy)
                guard edgeScore > safeThreshold else {
                    continue
                }

                let normalized = min(1, (edgeScore - safeThreshold) / (safeThreshold * 2))
                let blend = safeMaxBlend * (0.35 + (0.65 * normalized))
                guard blend > 0 else {
                    continue
                }

                // 3x3 gaussian-like smoothing only near strong depth discontinuities.
                var weightedSum: Float = 0
                var totalWeight: Float = 0
                for ky in -1...1 {
                    for kx in -1...1 {
                        let sampleIndex = ((y + ky) * width) + (x + kx)
                        let wx: Float = (kx == 0) ? 2 : 1
                        let wy: Float = (ky == 0) ? 2 : 1
                        let weight = wx * wy
                        weightedSum += source[sampleIndex] * weight
                        totalWeight += weight
                    }
                }

                guard totalWeight > 0 else {
                    continue
                }

                let blurred = weightedSum / totalWeight
                output[index] = (source[index] * (1 - blend)) + (blurred * blend)
            }
        }

        return output
    }

    private func antiAliasWarpEdges(
        bytes: inout [UInt8],
        width: Int,
        height: Int,
        shiftMap: [Float],
        gradientThreshold: Float,
        maxBlend: Float
    ) {
        guard width > 2, height > 2 else { return }
        guard shiftMap.count == width * height else { return }

        let source = bytes
        let rowStride = width * 4
        let safeThreshold = max(0.0001, gradientThreshold)
        let safeMaxBlend = max(0, min(1, maxBlend))

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = (y * width) + x
                let gx = abs(shiftMap[index + 1] - shiftMap[index - 1])
                let gy = abs(shiftMap[index + width] - shiftMap[index - width])
                let edgeScore = max(gx, gy)
                guard edgeScore > safeThreshold else {
                    continue
                }

                let normalized = min(1, (edgeScore - safeThreshold) / (safeThreshold * 2))
                let blend = safeMaxBlend * (0.3 + (0.7 * normalized))
                guard blend > 0 else {
                    continue
                }

                let offset = (y * rowStride) + (x * 4)
                let leftOffset = offset - 4
                let rightOffset = offset + 4
                let upOffset = offset - rowStride
                let downOffset = offset + rowStride

                for channel in 0..<4 {
                    let center = Float(source[offset + channel])
                    let blurred =
                        (center * 4) +
                        Float(source[leftOffset + channel]) +
                        Float(source[rightOffset + channel]) +
                        Float(source[upOffset + channel]) +
                        Float(source[downOffset + channel])
                    let averaged = blurred / 8
                    let mixed = (center * (1 - blend)) + (averaged * blend)
                    bytes[offset + channel] = UInt8(max(0, min(255, Int(mixed.rounded()))))
                }
            }
        }
    }

    private func fillHolesHorizontally(bytes: inout [UInt8], mask: inout [UInt8], width: Int, height: Int) {
        for y in 0..<height {
            var lastValidOffset: Int?

            for x in 0..<width {
                let index = (y * width) + x
                let offset = index * 4
                if mask[index] == 1 {
                    lastValidOffset = offset
                } else if let lastValidOffset {
                    bytes[offset] = bytes[lastValidOffset]
                    bytes[offset + 1] = bytes[lastValidOffset + 1]
                    bytes[offset + 2] = bytes[lastValidOffset + 2]
                    bytes[offset + 3] = bytes[lastValidOffset + 3]
                    mask[index] = 1
                }
            }

            lastValidOffset = nil
            for x in stride(from: width - 1, through: 0, by: -1) {
                let index = (y * width) + x
                let offset = index * 4
                if mask[index] == 1 {
                    lastValidOffset = offset
                } else if let lastValidOffset {
                    bytes[offset] = bytes[lastValidOffset]
                    bytes[offset + 1] = bytes[lastValidOffset + 1]
                    bytes[offset + 2] = bytes[lastValidOffset + 2]
                    bytes[offset + 3] = bytes[lastValidOffset + 3]
                    mask[index] = 1
                }
            }
        }
    }

    private func fillHolesVertically(bytes: inout [UInt8], mask: inout [UInt8], width: Int, height: Int) {
        for x in 0..<width {
            var lastValidOffset: Int?

            for y in 0..<height {
                let index = (y * width) + x
                let offset = index * 4
                if mask[index] == 1 {
                    lastValidOffset = offset
                } else if let lastValidOffset {
                    bytes[offset] = bytes[lastValidOffset]
                    bytes[offset + 1] = bytes[lastValidOffset + 1]
                    bytes[offset + 2] = bytes[lastValidOffset + 2]
                    bytes[offset + 3] = bytes[lastValidOffset + 3]
                    mask[index] = 1
                }
            }

            lastValidOffset = nil
            for y in stride(from: height - 1, through: 0, by: -1) {
                let index = (y * width) + x
                let offset = index * 4
                if mask[index] == 1 {
                    lastValidOffset = offset
                } else if let lastValidOffset {
                    bytes[offset] = bytes[lastValidOffset]
                    bytes[offset + 1] = bytes[lastValidOffset + 1]
                    bytes[offset + 2] = bytes[lastValidOffset + 2]
                    bytes[offset + 3] = bytes[lastValidOffset + 3]
                    mask[index] = 1
                }
            }
        }
    }

    private func histogramPercentiles(_ histogram: [Int], lowTarget: Int, highTarget: Int) -> (low: Int, high: Int) {
        var lowBin = 0
        var highBin = 255

        var cumulative = 0
        for bin in 0..<histogram.count {
            cumulative += histogram[bin]
            if cumulative >= lowTarget {
                lowBin = bin
                break
            }
        }

        cumulative = 0
        for bin in 0..<histogram.count {
            cumulative += histogram[bin]
            if cumulative >= highTarget {
                highBin = bin
                break
            }
        }

        if highBin < lowBin {
            return (low: lowBin, high: lowBin)
        }

        return (low: lowBin, high: highBin)
    }

    private func boxBlur(_ map: inout [Float], width: Int, height: Int) {
        guard width > 2, height > 2 else { return }

        var horizontal = map
        for y in 0..<height {
            for x in 0..<width {
                let left = map[(y * width) + max(x - 1, 0)]
                let center = map[(y * width) + x]
                let right = map[(y * width) + min(x + 1, width - 1)]
                horizontal[(y * width) + x] = (left + center + right) / 3
            }
        }

        for y in 0..<height {
            for x in 0..<width {
                let top = horizontal[(max(y - 1, 0) * width) + x]
                let center = horizontal[(y * width) + x]
                let bottom = horizontal[(min(y + 1, height - 1) * width) + x]
                map[(y * width) + x] = (top + center + bottom) / 3
            }
        }
    }

    private func meanBorderDepth(_ map: [Float], width: Int, height: Int) -> Float {
        guard width > 2, height > 2 else {
            return map.reduce(0, +) / Float(max(map.count, 1))
        }

        var sum: Float = 0
        var count: Int = 0

        for y in 0..<height {
            for x in 0..<width {
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                    sum += map[(y * width) + x]
                    count += 1
                }
            }
        }

        return sum / Float(max(count, 1))
    }

    private func meanCenterDepth(_ map: [Float], width: Int, height: Int) -> Float {
        let xStart = width / 4
        let xEnd = (width * 3) / 4
        let yStart = height / 4
        let yEnd = (height * 3) / 4

        var sum: Float = 0
        var count = 0

        for y in yStart..<max(yEnd, yStart + 1) {
            for x in xStart..<max(xEnd, xStart + 1) {
                sum += map[(y * width) + x]
                count += 1
            }
        }

        return sum / Float(max(count, 1))
    }
}
