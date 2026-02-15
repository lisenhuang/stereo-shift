import SwiftUI

struct HomeView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case photo
        case video

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .photo:
                return "Photo"
            case .video:
                return "Video"
            }
        }
    }

    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage("appTheme") private var appThemeRawValue = AppTheme.system.rawValue
    @StateObject private var pipeline = StereoPipeline()
    @StateObject private var galleryLibrary = AppGalleryLibrary()
    @StateObject private var galleryWebServer = GalleryWebServer()
    @StateObject private var subscriptionManager = SubscriptionManager()
    @State private var mode: Mode = .photo
    @State private var inputMode: InputMediaMode = .regular2D
    @State private var strength: Float = 0.9
    @State private var sbsLayoutEnabled = true
    @State private var isProcessing = false
    @State private var showVideoSubscriptionSheet = false
    private let bottomAnchorID = "content-bottom-anchor"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        modePicker
                        inputModePicker

                        if mode == .photo {
                            PhotoFlowView(
                                pipeline: pipeline,
                                inputMode: $inputMode,
                                strength: $strength,
                                sbsLayoutEnabled: $sbsLayoutEnabled,
                                galleryLibrary: galleryLibrary,
                                onGenerated: {
                                    scrollToBottom(using: proxy)
                                },
                                onProcessingStateChanged: { processing in
                                    isProcessing = processing
                                }
                            )
                        } else if mode == .video {
                            VideoFlowView(
                                pipeline: pipeline,
                                inputMode: $inputMode,
                                strength: $strength,
                                sbsLayoutEnabled: $sbsLayoutEnabled,
                                subscriptionManager: subscriptionManager,
                                galleryLibrary: galleryLibrary,
                                onRequireSubscription: {
                                    showVideoSubscriptionSheet = true
                                },
                                onGenerated: {
                                    scrollToBottom(using: proxy)
                                },
                                onProcessingStateChanged: { processing in
                                    isProcessing = processing
                                }
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .navigationTitle("StereoShift")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        themeMenu
                        languageMenu

                        NavigationLink {
                            GalleryView(galleryLibrary: galleryLibrary, webServer: galleryWebServer)
                                .navigationTitle("In-App Gallery")
                        } label: {
                            Label("Gallery", systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(isProcessing)
                    }
                }
                .sheet(isPresented: $showVideoSubscriptionSheet) {
                    VideoSubscriptionPaywallView(subscriptionManager: subscriptionManager)
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2D to 3D Side-by-Side")
                .font(.title2.bold())
            Text("Create left-right stereo photos and videos offline, or split spatial media directly into SBS.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var modePicker: some View {
        Picker("Mode", selection: modeSelection) {
            ForEach(Mode.allCases) { mode in
                Text(mode.titleKey).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isProcessing)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var inputModePicker: some View {
        Picker("Input", selection: $inputMode) {
            ForEach(InputMediaMode.allCases) { inputMode in
                Text(inputMode.titleKey).tag(inputMode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isProcessing)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var modeSelection: Binding<Mode> {
        Binding {
            mode
        } set: { newValue in
            guard newValue == .video else {
                mode = newValue
                return
            }

            if subscriptionManager.canAccessVideo {
                mode = .video
                return
            }

            if !subscriptionManager.hasResolvedEntitlements {
                Task { @MainActor in
                    await subscriptionManager.refreshEntitlements()
                    if subscriptionManager.canAccessVideo {
                        mode = .video
                    } else {
                        showVideoSubscriptionSheet = true
                    }
                }
                return
            }

            showVideoSubscriptionSheet = true
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var selectedLanguageBinding: Binding<AppLanguage> {
        Binding {
            AppLanguage(rawValue: appLanguageRawValue) ?? .system
        } set: { value in
            appLanguageRawValue = value.rawValue
        }
    }

    private var selectedThemeBinding: Binding<AppTheme> {
        Binding {
            AppTheme(rawValue: appThemeRawValue) ?? .system
        } set: { value in
            appThemeRawValue = value.rawValue
        }
    }

    private var themeMenu: some View {
        Menu {
            Picker("Theme", selection: selectedThemeBinding) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayNameKey).tag(theme)
                }
            }
        } label: {
            Label("Theme", systemImage: "circle.lefthalf.filled")
        }
        .disabled(isProcessing)
    }

    private var languageMenu: some View {
        Menu {
            Picker("Language", selection: selectedLanguageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            }
        } label: {
            Label("Language", systemImage: "globe")
        }
        .disabled(isProcessing)
    }
}

#Preview {
    HomeView()
}
