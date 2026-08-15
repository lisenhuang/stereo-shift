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
    @StateObject private var updateChecker = AppUpdateChecker()
    @Environment(\.openURL) private var openURL
    @State private var mode: Mode = .photo
    @State private var inputMode: InputMediaMode = .regular2D
    @State private var strength: Float = 0.80
    @State private var sbsLayoutEnabled = true
    @State private var stereo3DOptions = Stereo3DOptions()
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
                                stereo3DOptions: $stereo3DOptions,
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
                                stereo3DOptions: $stereo3DOptions,
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
                .scrollDisabled(isProcessing)
                .navigationTitle("StereoShift")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !subscriptionManager.canAccessVideo {
                            Button {
                                showVideoSubscriptionSheet = true
                            } label: {
                                Label("Upgrade", systemImage: "crown.fill")
                            }
                            .disabled(isProcessing)
                        }

                        themeMenu
                        languageMenu

                        NavigationLink {
                            GalleryView(
                                galleryLibrary: galleryLibrary,
                                webServer: galleryWebServer,
                                subscriptionManager: subscriptionManager
                            )
                        } label: {
                            Label("Gallery", systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(isProcessing)
                    }
                }
                .sheet(isPresented: $showVideoSubscriptionSheet) {
                    VideoSubscriptionPaywallView(subscriptionManager: subscriptionManager)
                }
                .alert(
                    "Update Available",
                    isPresented: Binding(
                        get: { updateChecker.availableUpdate != nil },
                        set: { isPresented in
                            if !isPresented {
                                updateChecker.dismiss()
                            }
                        }
                    )
                ) {
                    Button("Update") {
                        if let update = updateChecker.availableUpdate {
                            openURL(update.storeURL)
                        }
                        updateChecker.dismiss()
                    }
                    Button("Later", role: .cancel) {
                        updateChecker.dismiss()
                    }
                } message: {
                    Text("A new version of StereoShift is available with the latest improvements.")
                }
                .task {
                    await updateChecker.check()
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
            mode = newValue
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
