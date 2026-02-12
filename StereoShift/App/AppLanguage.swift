import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case korean

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return Self.systemLocale()
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .korean:
            return Locale(identifier: "ko")
        }
    }

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        case .korean:
            return "한국어"
        }
    }

    private static func systemLocale() -> Locale {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else {
            return Locale(identifier: "en")
        }

        if preferred.hasPrefix("zh") {
            return Locale(identifier: "zh-Hans")
        }
        if preferred.hasPrefix("ko") {
            return Locale(identifier: "ko")
        }
        return Locale(identifier: "en")
    }
}
