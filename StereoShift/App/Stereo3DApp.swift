import SwiftUI

@main
struct Stereo3DApp: App {
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(\.locale, selectedLocale)
        }
    }

    private var selectedLocale: Locale {
        let selected = AppLanguage(rawValue: appLanguageRawValue) ?? .system
        return selected.locale
    }
}
