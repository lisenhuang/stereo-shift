import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct VideoFlowView: View {
    let pipeline: StereoPipeline
    @Binding var inputMode: InputMediaMode
    @Binding var strength: Float
    @Binding var sbsLayoutEnabled: Bool
    @ObservedObject var subscriptionManager: SubscriptionManager
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    let onRequireSubscription: () -> Void
    let onGenerated: () -> Void
    let onProcessingStateChanged: (Bool) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceVideoURL: URL?
    @State private var outputVideoURL: URL?
    @State private var isLoadingSelection = false
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var showStopConfirmation = false
    @State private var errorMessage: String?
    @State private var saveMessageKey: LocalizedStringKey?
    @State private var progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)
    @State private var holdsScreenAwakeLock = false
    @State private var showFileImporter = false
    @State private var limitToFirstTenSeconds = true
    @State private var sourceVideoDurationSeconds: Double?

    @State private var selectionTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            PhotosPicker(selection: $selectedItem, matching: videoPickerFilter, preferredItemEncoding: .current) {
                Label(pickerButtonTitle, systemImage: "video")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || isVideoLocked || (inputMode == .spatial && !supportsSpatialPicker))

            if supportsDesktopFileImport {
                Button {
                    showFileImporter = true
                } label: {
                    Label(filePickerButtonTitle, systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isProcessing || isVideoLocked || (inputMode == .spatial && !supportsSpatialPicker))
            }

            if isLoadingSelection {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sourceVideoURL {
                ResultPreviewView(title: "Input", media: .video(sourceVideoURL), allowsFullscreenPreview: true)
            }

            controlsCard

            Button(action: generateSBSVideo) {
                Label(generateButtonTitle, systemImage: "sparkles.tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate)

            if let outputVideoURL {
                ResultPreviewView(title: "SBS Output", media: .video(outputVideoURL), allowsFullscreenPreview: true)

                VStack(spacing: 10) {
                    Button(action: saveOutputToInAppGallery) {
                        Group {
                            if isSaving {
                                Label("Saving…", systemImage: "tray.and.arrow.down")
                            } else {
                                Label("Save to In-App Gallery", systemImage: "tray.and.arrow.down")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving || isProcessing)

                    Button(action: saveOutputToPhotos) {
                        Group {
                            if isSaving {
                                Label("Saving…", systemImage: "square.and.arrow.down")
                            } else {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving || isProcessing)

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || isSaving)
                }
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [outputVideoURL])
                }

                if let saveMessageKey {
                    Text(saveMessageKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .allowsHitTesting(!isProcessing)
        .overlay {
            if isProcessing {
                ProgressViewOverlay(
                    title: progressTitleText,
                    progress: progressValue.fractionCompleted,
                    detail: progressDetailText,
                    onCancel: {
                        showStopConfirmation = true
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
        .onChange(of: selectedItem) { _, newValue in
            loadSelectedVideo(newValue)
        }
        .onChange(of: inputMode) { _, _ in
            resetForSourceModeChange()
        }
        .onChange(of: subscriptionManager.canAccessVideo) { _, newValue in
            guard !newValue else { return }
            resetForSourceModeChange()
        }
        .onChange(of: isProcessing) { _, newValue in
            updateScreenAwakeLock(isActive: newValue)
            onProcessingStateChanged(newValue)
        }
        .onDisappear {
            updateScreenAwakeLock(isActive: false)
            selectionTask?.cancel()
            processingTask?.cancel()
            onProcessingStateChanged(false)
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            } else {
                Text("Something went wrong.")
            }
        }
        .confirmationDialog(
            "Stop current conversion?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) {
                cancelProcessing()
            }
            Button("Continue", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            handleVideoFileImport(result)
        }
    }

    private var supportsSpatialPicker: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }

    private var supportsDesktopFileImport: Bool {
#if targetEnvironment(macCatalyst)
        return true
#else
        return ProcessInfo.processInfo.isiOSAppOnMac
#endif
    }

    private var videoPickerFilter: PHPickerFilter {
        if #available(iOS 18.0, *) {
            if inputMode == .spatial {
                return .all(of: [.videos, .spatialMedia])
            }
            return .all(of: [.videos, .not(.spatialMedia)])
        }
        return .videos
    }

    private var pickerButtonTitle: LocalizedStringKey {
        if inputMode == .spatial {
            return sourceVideoURL == nil ? "Pick Spatial Video" : "Pick Another Spatial Video"
        }
        return sourceVideoURL == nil ? "Pick Video" : "Pick Another Video"
    }

    private var filePickerButtonTitle: LocalizedStringKey {
        if inputMode == .spatial {
            return sourceVideoURL == nil ? "Pick Spatial Video from Files" : "Pick Another Spatial Video from Files"
        }
        return sourceVideoURL == nil ? "Pick Video from Files" : "Pick Another Video from Files"
    }

    private var generateButtonTitle: LocalizedStringKey {
        if isProcessing {
            return inputMode == .spatial ? "Converting…" : "Generating…"
        }
        return inputMode == .spatial ? "Convert Spatial to SBS" : "Generate"
    }

    private var canGenerate: Bool {
        guard sourceVideoURL != nil, !isProcessing, !isVideoLocked else { return false }
        if inputMode == .spatial, !supportsSpatialPicker {
            return false
        }
        if inputMode == .regular2D {
            return sbsLayoutEnabled
        }
        return true
    }

    private var isVideoLocked: Bool {
        !subscriptionManager.canAccessVideo
    }

    private var progressTitleText: Text {
        inputMode == .spatial ? Text("Converting Spatial Video") : Text("Rendering 3D Video")
    }

    private var progressDetailText: Text {
        let percent = Int((progressValue.fractionCompleted * 100).rounded())
        if inputMode == .spatial {
            return Text("\(percent)%") + Text(" • ") + Text("Extracting stereo views")
        }
        return Text("\(percent)% • \(formatTime(progressValue.processedSeconds)) / \(formatTime(progressValue.totalSeconds))")
    }

    private func resetForSourceModeChange() {
        selectionTask?.cancel()
        processingTask?.cancel()

        sourceVideoURL = nil
        sourceVideoDurationSeconds = nil
        if let oldOutput = outputVideoURL {
            TempFiles.removeItemIfExists(at: oldOutput)
        }
        outputVideoURL = nil
        selectedItem = nil
        saveMessageKey = nil
        progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)
        isLoadingSelection = false
        isProcessing = false
        showFileImporter = false
    }

    private func loadSelectedVideo(_ item: PhotosPickerItem?) {
        selectionTask?.cancel()

        guard let item else {
            sourceVideoURL = nil
            sourceVideoDurationSeconds = nil
            if let oldOutput = outputVideoURL {
                TempFiles.removeItemIfExists(at: oldOutput)
            }
            outputVideoURL = nil
            return
        }

        guard !isVideoLocked else {
            onRequireSubscription()
            selectedItem = nil
            return
        }

        sourceVideoURL = nil
        sourceVideoDurationSeconds = nil
        if let oldOutput = outputVideoURL {
            TempFiles.removeItemIfExists(at: oldOutput)
        }
        outputVideoURL = nil
        saveMessageKey = nil
        isLoadingSelection = true
        selectionTask = Task {
            do {
                if inputMode == .spatial {
                    guard supportsSpatialPicker else {
                        throw StereoPipelineError.spatialPickerUnavailable
                    }
                }

                let loadedURL = try await MediaPicker.loadVideoURL(from: item)
                let loadedDuration = try await videoDurationSeconds(for: loadedURL)
                if Task.isCancelled { return }

                await MainActor.run {
                    sourceVideoURL = loadedURL
                    sourceVideoDurationSeconds = loadedDuration
                    if let oldOutput = outputVideoURL {
                        TempFiles.removeItemIfExists(at: oldOutput)
                    }
                    outputVideoURL = nil
                    saveMessageKey = nil
                    isLoadingSelection = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isLoadingSelection = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleVideoFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            loadSelectedVideoFile(url)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedVideoFile(_ url: URL) {
        guard !isVideoLocked else {
            onRequireSubscription()
            return
        }
        selectionTask?.cancel()
        sourceVideoURL = nil
        sourceVideoDurationSeconds = nil
        if let oldOutput = outputVideoURL {
            TempFiles.removeItemIfExists(at: oldOutput)
        }
        outputVideoURL = nil
        saveMessageKey = nil
        isLoadingSelection = true

        selectionTask = Task {
            do {
                if inputMode == .spatial {
                    guard supportsSpatialPicker else {
                        throw StereoPipelineError.spatialPickerUnavailable
                    }
                }

                let loadedURL = try await Task.detached(priority: .userInitiated) {
                    try MediaPicker.loadVideoURL(fromFileURL: url)
                }.value
                let loadedDuration = try await videoDurationSeconds(for: loadedURL)
                if Task.isCancelled { return }

                await MainActor.run {
                    selectedItem = nil
                    sourceVideoURL = loadedURL
                    sourceVideoDurationSeconds = loadedDuration
                    if let oldOutput = outputVideoURL {
                        TempFiles.removeItemIfExists(at: oldOutput)
                    }
                    outputVideoURL = nil
                    saveMessageKey = nil
                    isLoadingSelection = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isLoadingSelection = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func generateSBSVideo() {
        guard !isVideoLocked else {
            onRequireSubscription()
            return
        }
        guard let sourceVideoURL else { return }

        processingTask?.cancel()
        isProcessing = true
        progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)

        let processor = pipeline.videoProcessor
        let appliedStrength = strength
        let usingSpatialMode = inputMode == .spatial
        let shouldLimitDuration = !usingSpatialMode && limitToFirstTenSeconds && (sourceVideoDurationSeconds ?? .infinity) > 10.0
        let maxDurationSeconds = shouldLimitDuration ? 10.0 : nil

        processingTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()

                let outputURL: URL
                if usingSpatialMode {
                    outputURL = try await SpatialMediaConverter.processSpatialVideo(inputURL: sourceVideoURL) { update in
                        Task { @MainActor in
                            progressValue = update
                        }
                    }
                } else {
                    outputURL = try await processor.processVideo(
                        inputURL: sourceVideoURL,
                        strength: appliedStrength,
                        maxDurationSeconds: maxDurationSeconds
                    ) { update in
                        Task { @MainActor in
                            progressValue = update
                        }
                    }
                }

                if Task.isCancelled {
                    TempFiles.removeItemIfExists(at: outputURL)
                    return
                }

                await MainActor.run {
                    outputVideoURL = outputURL
                    saveMessageKey = nil
                    isProcessing = false
                    onGenerated()
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        isProcessing = false
                    }
                    return
                }

                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }

    private func updateScreenAwakeLock(isActive: Bool) {
        if isActive, !holdsScreenAwakeLock {
            holdsScreenAwakeLock = true
            ScreenAwakeManager.shared.acquire()
            return
        }

        if !isActive, holdsScreenAwakeLock {
            holdsScreenAwakeLock = false
            ScreenAwakeManager.shared.release()
        }
    }

    private func saveOutputToInAppGallery() {
        guard let outputVideoURL else { return }
        isSaving = true
        saveMessageKey = nil

        Task {
            do {
                _ = try await galleryLibrary.saveMedia(at: outputVideoURL, type: .video)
                await MainActor.run {
                    isSaving = false
                    saveMessageKey = "Saved to In-App Gallery."
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveOutputToPhotos() {
        guard let outputVideoURL else { return }
        isSaving = true
        saveMessageKey = nil

        Task {
            do {
                try await PhotoLibrarySaver.saveVideoFile(at: outputVideoURL)
                await MainActor.run {
                    isSaving = false
                    saveMessageKey = "Saved to Photos."
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private func videoDurationSeconds(for url: URL) async throws -> Double {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite {
            return max(0, seconds)
        }
        return 0
    }

    private var strengthLabelKey: LocalizedStringKey {
        if strength < 0.45 {
            return "Subtle"
        }
        if strength < 1.0 {
            return "Balanced"
        }
        return "Strong"
    }

    private var controlsCard: some View {
        VStack(spacing: 14) {
            Picker("Input", selection: $inputMode) {
                ForEach(InputMediaMode.allCases) { mode in
                    Text(mode.titleKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if inputMode == .regular2D {
                HStack {
                    Text("3D Strength")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(strengthLabelKey)
                        Text("•")
                        Text(strength.formatted(.number.precision(.fractionLength(2))))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(strength) },
                        set: { strength = Float($0) }
                    ),
                    in: 0.1...1.5
                )

                Toggle("Side-by-Side (SBS)", isOn: $sbsLayoutEnabled)
                    .disabled(true)

                if (sourceVideoDurationSeconds ?? 0) > 10 {
                    Toggle("Only convert first 10 seconds for testing", isOn: $limitToFirstTenSeconds)
                }
            } else {
                Text("Spatial media is converted by separating left and right views. The depth model is not used.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !supportsSpatialPicker {
                    Text("Spatial-only picker requires iOS 18 or later.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
