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
    case spatialImagePairUnavailable
    case spatialViewsUnavailable
    case spatialPickerUnavailable
    case embeddedDepthUnavailable
    case temporaryFileCreationFailed
    case photoLibraryAccessDenied
    case metalDeviceUnavailable
    case modelContractViolation(String)
    case depthOutputDegenerate
    case modelNotInstalled(String)
    case modelDownloadFailed(String)
    case modelChecksumMismatch
    case modelCompileFailed(String)
    case insufficientStorage(requiredBytes: Int64)
    case unsupportedDevice(String)
    case modelBusy
    case modelUpdateRefused(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Depth model is missing. Download it from Settings, or add the .mlmodelc to StereoShift/Resources, and try again."
        case let .modelContractViolation(reason):
            return "Depth model does not match the expected input/output contract: \(reason)"
        case .depthOutputDegenerate:
            return "Depth model produced a flat or invalid depth map."
        case let .modelNotInstalled(name):
            return "\(name) is not installed. Download it from Settings."
        case let .modelDownloadFailed(reason):
            return "Model download failed: \(reason)"
        case .modelChecksumMismatch:
            return "Downloaded model file failed verification."
        case let .modelCompileFailed(reason):
            return "Model could not be prepared on this device: \(reason)"
        case let .insufficientStorage(requiredBytes):
            let formatted = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            return "Not enough free space. About \(formatted) is required."
        case let .unsupportedDevice(reason):
            return "This model is not supported on this device: \(reason)"
        case .modelBusy:
            return "The depth model is busy. Wait for the current conversion to finish."
        case let .modelUpdateRefused(reason):
            return reason
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
        case .spatialImagePairUnavailable:
            return "Unable to extract left/right images from the selected spatial photo."
        case .spatialViewsUnavailable:
            return "Unable to extract left/right views from the selected spatial video. Please choose an original spatial video."
        case .spatialPickerUnavailable:
            return "Spatial-only picking requires iOS 18 or later."
        case .embeddedDepthUnavailable:
            return "This photo does not include usable embedded depth/disparity data."
        case .temporaryFileCreationFailed:
            return "Unable to create a temporary file."
        case .photoLibraryAccessDenied:
            return "Photo library permission is required to save output."
        case .metalDeviceUnavailable:
            return "Metal GPU is not available on this device."
        }
    }
}
