import CoreImage
import CoreVideo
import Foundation

final class StereoRenderer {
    private let depthEstimator: DepthEstimator
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(depthEstimator: DepthEstimator) {
        self.depthEstimator = depthEstimator
    }

    static func maxDisparity(forWidth width: Int) -> Float {
        let scaled = 24 * (Float(width) / 720)
        return min(max(8, scaled), 56)
    }

    func makeSBS(from image: CGImage, strength: Float) async throws -> CGImage {
        let rgbBuffer = try PixelBufferUtilities.makePixelBuffer(from: image)
        let depthBuffer = try await depthEstimator.predictDepth(pixelBuffer: rgbBuffer)
        let outputBuffer = try makeSBS(from: rgbBuffer, depth: depthBuffer, strength: strength)
        return try PixelBufferUtilities.makeCGImage(from: outputBuffer, context: ciContext)
    }

    func makeSBS(from rgb: CVPixelBuffer, depth: CVPixelBuffer, strength: Float) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(rgb)
        let height = CVPixelBufferGetHeight(rgb)

        let sourceBytes = try bgraBytes(from: rgb)
        let depthMap = try normalizedDepthMap(from: depth, targetWidth: width, targetHeight: height)

        let clampedStrength = max(0, min(1.5, strength))
        let disparityScale = clampedStrength * Self.maxDisparity(forWidth: width)
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

    private func normalizedDepthMap(from depthBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) throws -> [Float] {
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

        let range = max(maxValue - minValue, 0.0001)
        for index in map.indices {
            map[index] = (map[index] - minValue) / range
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

        return map
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
