import Foundation
import Photos

enum PhotoLibrarySaver {
    static func saveImageFile(at url: URL) async throws {
        try await requestAddOnlyAuthorizationIfNeeded()
        try await performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    static func saveVideoFile(at url: URL) async throws {
        try await requestAddOnlyAuthorizationIfNeeded()
        try await performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    private static func requestAddOnlyAuthorizationIfNeeded() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited {
            return
        }

        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }

        guard status == .authorized || status == .limited else {
            throw StereoPipelineError.photoLibraryAccessDenied
        }
    }

    private static func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: StereoPipelineError.exportFailed)
                }
            }
        }
    }
}
