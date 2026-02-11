import CoreVideo
import Foundation

enum StereoPipelineError: LocalizedError {
    case modelNotFound
    case modelInputNotFound
    case modelOutputNotFound
    case unsupportedModelOutput
    case invalidDepthArrayShape
    case noVideoTrack
    case readerSetupFailed
    case writerSetupFailed
    case writerAppendFailed
    case processingCancelled
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferBaseAddressUnavailable
    case graphicsContextCreationFailed
    case cgImageCreationFailed
    case unsupportedPixelFormat
    case exportFailed
    case mediaDecodingFailed
    case photoPickerDataUnavailable
    case photoDecodingFailed
    case temporaryFileCreationFailed
    case photoLibraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Depth model is missing. Add DepthAnythingV2SmallF32.mlpackage to StereoShift/Resources and try again."
        case .modelInputNotFound:
            return "Model input could not be resolved."
        case .modelOutputNotFound:
            return "Model output could not be resolved."
        case .unsupportedModelOutput:
            return "Model produced an unsupported depth output format."
        case .invalidDepthArrayShape:
            return "Depth output shape is invalid."
        case .noVideoTrack:
            return "The selected file does not contain a video track."
        case .readerSetupFailed:
            return "Unable to read the selected video."
        case .writerSetupFailed:
            return "Unable to create the output video writer."
        case .writerAppendFailed:
            return "Failed while writing a video frame."
        case .processingCancelled:
            return "Processing was cancelled."
        case let .pixelBufferCreationFailed(code):
            return "Pixel buffer creation failed with status \(code)."
        case .pixelBufferBaseAddressUnavailable:
            return "Unable to access pixel buffer memory."
        case .graphicsContextCreationFailed:
            return "Unable to create graphics context."
        case .cgImageCreationFailed:
            return "Unable to create CGImage."
        case .unsupportedPixelFormat:
            return "Unsupported pixel format."
        case .exportFailed:
            return "Video export failed."
        case .mediaDecodingFailed:
            return "Unable to decode selected media."
        case .photoPickerDataUnavailable:
            return "No media data was returned from the picker."
        case .photoDecodingFailed:
            return "Unable to decode photo data."
        case .temporaryFileCreationFailed:
            return "Unable to create a temporary file."
        case .photoLibraryAccessDenied:
            return "Photo library permission is required to save output."
        }
    }
}
