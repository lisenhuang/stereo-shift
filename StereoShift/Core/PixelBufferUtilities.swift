import CoreImage
import CoreVideo
import Foundation

enum PixelBufferUtilities {
    static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    static func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw StereoPipelineError.pixelBufferCreationFailed(status)
        }

        return pixelBuffer
    }

    static func makePixelBuffer(from cgImage: CGImage, pixelFormat: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw StereoPipelineError.unsupportedPixelFormat
        }

        let width = cgImage.width
        let height = cgImage.height
        let pixelBuffer = try makePixelBuffer(width: width, height: height, pixelFormat: pixelFormat)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw StereoPipelineError.graphicsContextCreationFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    static func makeCGImage(from pixelBuffer: CVPixelBuffer, context: CIContext = sharedCIContext) throws -> CGImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw StereoPipelineError.cgImageCreationFailed
        }
        return cgImage
    }

    static func resize(
        _ pixelBuffer: CVPixelBuffer,
        to size: CGSize,
        context: CIContext = sharedCIContext,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) throws -> CVPixelBuffer {
        let destinationWidth = max(Int(size.width.rounded()), 1)
        let destinationHeight = max(Int(size.height.rounded()), 1)
        let destination = try makePixelBuffer(width: destinationWidth, height: destinationHeight, pixelFormat: kCVPixelFormatType_32BGRA)

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(destinationWidth) / sourceImage.extent.width
        let sy = CGFloat(destinationHeight) / sourceImage.extent.height
        let scaled = sourceImage
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: destinationWidth, height: destinationHeight))

        context.render(scaled, to: destination, bounds: CGRect(x: 0, y: 0, width: destinationWidth, height: destinationHeight), colorSpace: colorSpace)
        return destination
    }
}
