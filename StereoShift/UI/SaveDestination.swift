import Foundation

enum SaveDestination: String, CaseIterable, Identifiable {
    case appGallery = "App Gallery"
    case photos = "Photos"

    var id: String { rawValue }

    var saveButtonTitle: String {
        switch self {
        case .appGallery:
            return "Save to App"
        case .photos:
            return "Save to Photos"
        }
    }
}
