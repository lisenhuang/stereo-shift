import Foundation

enum SaveDestination: String, CaseIterable, Identifiable {
    case appGallery = "In-App Gallaey"
    case photos = "Photos"

    var id: String { rawValue }

    var saveButtonTitle: String {
        switch self {
        case .appGallery:
            return "Save to In-App Gallaey"
        case .photos:
            return "Save to Photos"
        }
    }
}
