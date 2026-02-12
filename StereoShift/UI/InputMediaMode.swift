import Foundation

enum InputMediaMode: String, CaseIterable, Identifiable {
    case regular2D = "2D"
    case spatial = "Spatial"

    var id: String { rawValue }
}
