import SwiftUI

@main
struct Stereo3DApp: App {
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage("appTheme") private var appThemeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(\.locale, selectedLocale)
                .preferredColorScheme(selectedTheme.colorScheme)
        }
    }

    private var selectedLocale: Locale {
        let selected = AppLanguage(rawValue: appLanguageRawValue) ?? .system
        return selected.locale
    }

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: appThemeRawValue) ?? .system
    }
}
