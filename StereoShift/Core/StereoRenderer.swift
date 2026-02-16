import CoreImage
import CoreVideo
import Foundation
import Vision

final class StereoRenderer {
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
            return try makeSBSServerLike(from: rgb, depth: depth, strength: strength)
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

    private func makeSBSServerLike(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)

        let sourceBytes = try bgraBytes(from: rgb)
        let depthMap = try serverNormalizedDepthMap(from: depth, targetWidth: width, targetHeight: height)

        // Matches the server baseline disparity (per-eye shift) at strength=1.0.
        let clampedStrength = max(0, min(1.5, strength))
        let baselinePerEye = max(0, Float(40) * clampedStrength)

        var left = [UInt8](repeating: 0, count: width * height * 4)
        var right = [UInt8](repeating: 0, count: width * height * 4)
        var leftMask = [UInt8](repeating: 0, count: width * height)
        var rightMask = [UInt8](repeating: 0, count: width * height)

        // Forward mapping (source -> destination) matches the server's hole-filling step.
        for y in 0..<height {
            for x in 0..<width {
                let srcIdx = (y * width) + x
                let shift = Int(depthMap[srcIdx] * baselinePerEye)

                let destXL = min(width - 1, x + shift)
                let destXR = max(0, x - shift)

                let p = pixel(sourceBytes, width: width, x: x, y: y)

                let leftIdx = (y * width) + destXL
                let rightIdx = (y * width) + destXR

                writePixel(p, into: &left, at: leftIdx)
                leftMask[leftIdx] = 1

                writePixel(p, into: &right, at: rightIdx)
                rightMask[rightIdx] = 1
            }
        }

        // Fill holes using the original image at the same coordinates.
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width) + x
                if leftMask[idx] == 0 {
                    writePixel(pixel(sourceBytes, width: width, x: x, y: y), into: &left, at: idx)
                    leftMask[idx] = 1
                }
                if rightMask[idx] == 0 {
                    writePixel(pixel(sourceBytes, width: width, x: x, y: y), into: &right, at: idx)
                    rightMask[idx] = 1
                }
            }
        }

        return try assembleSBS(left: left, right: right, width: width, height: height)
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
