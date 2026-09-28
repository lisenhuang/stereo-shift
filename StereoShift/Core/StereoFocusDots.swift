import CoreGraphics
import CoreVideo
import Foundation

enum StereoFocusDots {
    struct Layout {
        let stripHeight: Int
        let dotDiameter: CGFloat
        let leftCenterX: CGFloat
        let rightCenterX: CGFloat

        init(width: Int, height: Int) {
            let eyeWidth = CGFloat(width) / 2
            let referenceSize = min(eyeWidth, CGFloat(height))
            // Even padding keeps video output compatible with H.264 encoders.
            stripHeight = max(2, Int((referenceSize * 0.08 / 2).rounded()) * 2)
            dotDiameter = referenceSize * 0.025
            leftCenterX = eyeWidth / 2
            rightCenterX = eyeWidth * 1.5
        }
    }

    static func outputHeight(width: Int, height: Int, enabled: Bool) -> Int {
        height + (enabled ? Layout(width: width, height: height).stripHeight : 0)
    }

    static func addingIfEnabled(to source: CVPixelBuffer, enabled: Bool) throws -> CVPixelBuffer {
        guard enabled else { return source }
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw StereoPipelineError.unsupportedPixelFormat
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let layout = Layout(width: width, height: height)
        let output = try PixelBufferUtilities.makePixelBuffer(
            width: width,
            height: height + layout.stripHeight,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let outputBase = CVPixelBufferGetBaseAddress(output) else {
            throw StereoPipelineError.pixelBufferBaseAddressUnavailable
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let outputStride = CVPixelBufferGetBytesPerRow(output)

        // BGRA rows start at the top. Copy the original pixels below the new strip.
        for row in 0..<height {
            memcpy(
                outputBase.advanced(by: (row + layout.stripHeight) * outputStride),
                sourceBase.advanced(by: row * sourceStride),
                width * 4
            )
        }

        // The context only spans the strip, so drawing cannot cover the views.
        guard let context = CGContext(
            data: outputBase,
            width: width,
            height: layout.stripHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputStride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw StereoPipelineError.graphicsContextCreationFailed
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: layout.stripHeight))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for centerX in [layout.leftCenterX, layout.rightCenterX] {
            context.fillEllipse(in: CGRect(
                x: centerX - layout.dotDiameter / 2,
                y: (CGFloat(layout.stripHeight) - layout.dotDiameter) / 2,
                width: layout.dotDiameter,
                height: layout.dotDiameter
            ))
        }
        return output
    }
}
