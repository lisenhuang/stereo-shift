import AVFoundation
import Foundation

struct SourceVideoMetadata {
    let durationSeconds: Double?
    let displaySize: CGSize?

    var summary: String {
        var parts: [String] = []
        if let durationSeconds {
            let total = Int(durationSeconds.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            parts.append(hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%02d:%02d", minutes, seconds))
        }
        if let displaySize {
            parts.append("\(Int(displaySize.width.rounded())) × \(Int(displaySize.height.rounded()))")
        }
        return parts.joined(separator: " • ")
    }

    static func load(from url: URL) async throws -> SourceVideoMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var displaySize: CGSize?
        if let track = try await asset.loadTracks(withMediaType: .video).first,
           let properties = try? await track.load(.naturalSize, .preferredTransform) {
            // Phone videos often store landscape pixels with a portrait transform.
            let bounds = CGRect(origin: .zero, size: properties.0).applying(properties.1)
            if bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 {
                displaySize = bounds.size
            }
        }
        return SourceVideoMetadata(durationSeconds: duration.isFinite && duration >= 0 ? duration : nil,
                                   displaySize: displaySize)
    }
}
