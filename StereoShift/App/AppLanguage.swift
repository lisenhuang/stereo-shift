import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case arabic
    case hindi
    case french
    case brazilianPortuguese
    case simplifiedChinese
    case japanese
    case korean

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return Self.systemLocale()
        case .english:
            return Locale(identifier: "en")
        case .spanish:
            return Locale(identifier: "es")
        case .arabic:
            return Locale(identifier: "ar")
        case .hindi:
            return Locale(identifier: "hi")
        case .french:
            return Locale(identifier: "fr")
        case .brazilianPortuguese:
            return Locale(identifier: "pt-BR")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .japanese:
            return Locale(identifier: "ja")
        case .korean:
            return Locale(identifier: "ko")
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .spanish:
            return "Español"
        case .arabic:
            return "العربية"
        case .hindi:
            return "हिन्दी"
        case .french:
            return "Français"
        case .brazilianPortuguese:
            return "Português (Brasil)"
        case .simplifiedChinese:
            return "简体中文"
        case .japanese:
            return "日本語"
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
        if preferred.hasPrefix("es") {
            return Locale(identifier: "es")
        }
        if preferred.hasPrefix("ar") {
            return Locale(identifier: "ar")
        }
        if preferred.hasPrefix("hi") {
            return Locale(identifier: "hi")
        }
        if preferred.hasPrefix("fr") {
            return Locale(identifier: "fr")
        }
        if preferred.hasPrefix("pt") {
            return Locale(identifier: "pt-BR")
        }
        if preferred.hasPrefix("ja") {
            return Locale(identifier: "ja")
        }
        if preferred.hasPrefix("ko") {
            return Locale(identifier: "ko")
        }
        return Locale(identifier: "en")
    }
}
