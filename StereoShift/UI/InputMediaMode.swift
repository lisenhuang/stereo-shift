import Foundation
import SwiftUI

enum InputMediaMode: String, CaseIterable, Identifiable {
    case regular2D
    case spatial

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .regular2D:
            return "2D"
        case .spatial:
            return "Spatial"
        }
    }
}
