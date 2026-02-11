import Foundation

enum SaveDestination: String, CaseIterable, Identifiable {
    case appGallery = "In-App Gallary"
    case photos = "Photos"

    var id: String { rawValue }

    var saveButtonTitle: String {
        switch self {
        case .appGallery:
            return "Save to In-App Gallary"
        case .photos:
            return "Save to Photos"
        }
    }
}
