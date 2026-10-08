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
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: Mode = .photo
    @State private var inputMode: InputMediaMode = .regular2D
    @State private var strength: Float = 0.80
    @State private var sbsLayoutEnabled = true
    @State private var stereo3DOptions = Stereo3DOptions()
    @State private var isProcessing = false
    @State private var showVideoSubscriptionSheet = false
    @State private var pendingInstagramImport: PendingInstagramImport?
    @State private var deferredInstagramRequestID: UUID?
    @State private var navigationPath = NavigationPath()
    @State private var importedInstagramMedia: ImportedInstagramMedia?
    @State private var importGeneration = UUID()
    private let bottomAnchorID = "content-bottom-anchor"

    var body: some View {
        NavigationStack(path: $navigationPath) {
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
                                subscriptionManager: subscriptionManager,
                                galleryLibrary: galleryLibrary,
                                importedFileURL: importedInstagramMedia?.kind == .photo ? importedInstagramMedia?.url : nil,
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
                            .id(importGeneration)
                        } else if mode == .video {
                            VideoFlowView(
                                pipeline: pipeline,
                                inputMode: $inputMode,
                                strength: $strength,
                                sbsLayoutEnabled: $sbsLayoutEnabled,
                                stereo3DOptions: $stereo3DOptions,
                                subscriptionManager: subscriptionManager,
                                galleryLibrary: galleryLibrary,
                                importedFileURL: importedInstagramMedia?.kind == .video ? importedInstagramMedia?.url : nil,
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
                            .id(importGeneration)
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

                        preferencesMenu

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
                .sheet(item: $pendingInstagramImport) { request in
                    InstagramImportView(request: request) { media in
                        if let previous = importedInstagramMedia {
                            TempFiles.removeItemIfExists(at: previous.url)
                        }
                        importedInstagramMedia = media
                        inputMode = .regular2D
                        mode = media.kind == .photo ? .photo : .video
                        importGeneration = UUID()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        refreshInstagramInbox()
                        Task { await updateChecker.check() }
                    }
                }
                .onOpenURL { url in
                    guard let id = InstagramHandoff.requestID(from: url) else { return }
                    guard pendingInstagramImport?.id != id else { return }
                    deferredInstagramRequestID = id
                    refreshInstagramInbox()
                }
                .onChange(of: isProcessing) { _, processing in
                    if !processing { refreshInstagramInbox() }
                }
                .onChange(of: showVideoSubscriptionSheet) { _, presented in
                    if !presented { refreshInstagramInbox() }
                }
                .sheet(isPresented: $showVideoSubscriptionSheet) {
                    VideoSubscriptionPaywallView(subscriptionManager: subscriptionManager)
                }
                .alert(
                    "Update Available",
                    isPresented: Binding(
                        get: {
                            updateChecker.availableUpdate != nil && scenePhase == .active
                                && pendingInstagramImport == nil && !isProcessing
                                && !showVideoSubscriptionSheet && navigationPath.isEmpty
                        },
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
                    refreshInstagramInbox()
                    await updateChecker.check()
                }
            }
        }
    }

    private func refreshInstagramInbox() {
        guard scenePhase == .active, !isProcessing, !showVideoSubscriptionSheet,
              pendingInstagramImport == nil else { return }
        let requestID = deferredInstagramRequestID
        deferredInstagramRequestID = nil
        guard let request = try? InstagramShareInbox.takePending(requestID: requestID) else { return }
        navigationPath = NavigationPath()
        pendingInstagramImport = request
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
            if newValue != mode, let importedInstagramMedia {
                TempFiles.removeItemIfExists(at: importedInstagramMedia.url)
                self.importedInstagramMedia = nil
            }
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

    /// Theme and language share one menu so the toolbar keeps four items; a fifth pushes
    /// Gallery into an overflow menu on iOS 18 and on narrower iPhones.
    private var preferencesMenu: some View {
        Menu {
            Picker(selection: selectedThemeBinding) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayNameKey).tag(theme)
                }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.menu)

            Picker(selection: selectedLanguageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .pickerStyle(.menu)
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .disabled(isProcessing)
    }
}

#Preview {
    HomeView()
}
