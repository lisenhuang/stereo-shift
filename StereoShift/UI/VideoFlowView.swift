import AVKit
import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoFlowView: View {
    let pipeline: StereoPipeline
    @Binding var inputMode: InputMediaMode
    @Binding var strength: Float
    @Binding var sbsLayoutEnabled: Bool
    @Binding var stereo3DOptions: Stereo3DOptions
    @ObservedObject var subscriptionManager: SubscriptionManager
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @ObservedObject var depthModelStore: DepthModelStore
    let onRequireSubscription: () -> Void
    let onGenerated: () -> Void
    let onProcessingStateChanged: (Bool) -> Void

    @Environment(\.requestReview) private var requestReview
    @AppStorage(VideoDepthCadenceSetting.defaultsKey) private var videoDepthCadenceRawValue = VideoDepthCadenceSetting.automaticRawValue

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
    @State private var showSaveToDiskMover = false
    @State private var saveToDiskSourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("stereoshift-video-export-placeholder")
    @State private var limitToFirstTenSeconds = true
    @State private var sourceVideoDurationSeconds: Double?
    @State private var sourceVideoFrameRate: Double?
    /// Depth model that produced `outputVideoURL`; nil for spatial splits.
    @State private var outputModel: DepthModel?
    @State private var showSlowModelConfirmation = false
    // ETA bookkeeping for the progress overlay (see `estimateSecondsRemaining`).
    @State private var processingStartDate: Date?
    @State private var activeDepthCadence = 1
    @State private var lastDepthInferenceSeconds: Double?
    @State private var estimatedSecondsRemaining: Double?
    @State private var lastEstimateUpdate = Date.distantPast

    @State private var selectionTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?
    @State private var reviewPromptTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            if sourceVideoURL == nil {
                pickerControls
            }

            if isLoadingSelection {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sourceVideoURL {
                ResultPreviewView(title: "Input", media: .video(sourceVideoURL), allowsFullscreenPreview: true)
                pickerControls
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

                    if supportsDesktopFileImport {
                        Button(action: saveOutputToDisk) {
                            Label("Save to Disk", systemImage: "externaldrive")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving || isProcessing)
                    }

                    Button {
                        presentShareSheet()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || isSaving)
                }
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [outputVideoURL]) { completed in
                        guard completed else { return }
                        scheduleReviewPromptAfterVideoExport()
                    }
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
        .onChange(of: isProcessing) { _, newValue in
            updateScreenAwakeLock(isActive: newValue)
            onProcessingStateChanged(newValue)
        }
        .onDisappear {
            updateScreenAwakeLock(isActive: false)
            selectionTask?.cancel()
            processingTask?.cancel()
            reviewPromptTask?.cancel()
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
        .alert("Stop current conversion?", isPresented: $showStopConfirmation) {
            Button("Stop", role: .destructive) {
                cancelProcessing()
            }
            Button("Continue", role: .cancel) {}
        }
        .alert("Slow Model for Video", isPresented: $showSlowModelConfirmation) {
            Button("Continue") {
                startSBSVideo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(depthModelStore.selectedModel.displayName) is slow for video. Continue?")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            handleVideoFileImport(result)
        }
        .fileMover(
            isPresented: $showSaveToDiskMover,
            file: saveToDiskSourceURL
        ) { result in
            switch result {
            case .success:
                saveMessageKey = "Saved to Disk."
                scheduleReviewPromptAfterVideoExport()
            case let .failure(error):
                if !isUserCancelledError(error) {
                    errorMessage = error.localizedDescription
                }
            }

            TempFiles.removeItemIfExists(at: saveToDiskSourceURL)
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
        guard sourceVideoURL != nil, !isProcessing else { return false }
        if inputMode == .spatial, !supportsSpatialPicker {
            return false
        }
        if inputMode == .regular2D {
            return sbsLayoutEnabled
        }
        return true
    }

    private var progressTitleText: Text {
        inputMode == .spatial ? Text("Converting Spatial Video") : Text("Rendering 3D Video")
    }

    private var progressDetailText: Text {
        let percent = Int((progressValue.fractionCompleted * 100).rounded())
        var text: Text
        if inputMode == .spatial {
            text = Text("\(percent)%") + Text(" • ") + Text("Extracting stereo views")
        } else {
            text = Text("\(percent)% • \(formatTime(progressValue.processedSeconds)) / \(formatTime(progressValue.totalSeconds))")
        }
        if let estimatedSecondsRemaining {
            text = text + Text(" • ") + Text("~\(formatTime(estimatedSecondsRemaining)) left")
        }
        return text
    }

    private func resetForSourceModeChange() {
        selectionTask?.cancel()
        processingTask?.cancel()

        sourceVideoURL = nil
        sourceVideoDurationSeconds = nil
        sourceVideoFrameRate = nil
        if let oldOutput = outputVideoURL {
            TempFiles.removeItemIfExists(at: oldOutput)
        }
        outputVideoURL = nil
        selectedItem = nil
        saveMessageKey = nil
        progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)
        outputModel = nil
        estimatedSecondsRemaining = nil
        processingStartDate = nil
        isLoadingSelection = false
        isProcessing = false
        showFileImporter = false
    }

    private func loadSelectedVideo(_ item: PhotosPickerItem?) {
        selectionTask?.cancel()

        guard let item else {
            sourceVideoURL = nil
            sourceVideoDurationSeconds = nil
            sourceVideoFrameRate = nil
            if let oldOutput = outputVideoURL {
                TempFiles.removeItemIfExists(at: oldOutput)
            }
            outputVideoURL = nil
            return
        }

        sourceVideoURL = nil
        sourceVideoDurationSeconds = nil
        sourceVideoFrameRate = nil
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
                let loadedInfo = try await loadSourceVideoInfo(for: loadedURL)
                if Task.isCancelled { return }

                await MainActor.run {
                    sourceVideoURL = loadedURL
                    sourceVideoDurationSeconds = loadedInfo.durationSeconds
                    sourceVideoFrameRate = loadedInfo.frameRate
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
        selectionTask?.cancel()
        sourceVideoURL = nil
        sourceVideoDurationSeconds = nil
        sourceVideoFrameRate = nil
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
                let loadedInfo = try await loadSourceVideoInfo(for: loadedURL)
                if Task.isCancelled { return }

                await MainActor.run {
                    selectedItem = nil
                    sourceVideoURL = loadedURL
                    sourceVideoDurationSeconds = loadedInfo.durationSeconds
                    sourceVideoFrameRate = loadedInfo.frameRate
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
        guard sourceVideoURL != nil else { return }

        // Base/Large models take several times longer per frame; ask before a long run.
        if inputMode == .regular2D, !isSelectedModelVideoRecommended {
            showSlowModelConfirmation = true
            return
        }
        startSBSVideo()
    }

    private func startSBSVideo() {
        guard let sourceVideoURL else { return }

        processingTask?.cancel()
        isProcessing = true
        progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)
        processingStartDate = Date()
        estimatedSecondsRemaining = nil
        lastDepthInferenceSeconds = nil
        lastEstimateUpdate = .distantPast

        let processor = pipeline.videoProcessor
        let depthEstimator = pipeline.depthEstimator
        let store = depthModelStore
        let appliedStrength = strength
        var appliedOptions = stereo3DOptions
        appliedOptions.depthModel = store.selectedModel
        appliedOptions.renderEngine = .metal
        appliedOptions.renderProfile = .ultraFast
        appliedOptions.videoDepthCadence = effectiveDepthCadence
        activeDepthCadence = appliedOptions.videoDepthCadence.rawValue
        let appliedModel = appliedOptions.depthModel
        let usingSpatialMode = inputMode == .spatial
        let shouldLimitDuration = !usingSpatialMode && limitToFirstTenSeconds && (sourceVideoDurationSeconds ?? .infinity) > 10.0
        let maxDurationSeconds = shouldLimitDuration ? 10.0 : nil

        // Only depth conversions use the estimator; spatial splits do not. The guard
        // keeps model removal, benchmark and install off the estimator meanwhile.
        if !usingSpatialMode {
            store.beginConversion()
        }

        processingTask = Task.detached(priority: .userInitiated) {
            defer {
                if !usingSpatialMode {
                    Task { @MainActor in store.endConversion() }
                }
            }
            do {
                try Task.checkCancellation()

                let processedURL: URL
                if usingSpatialMode {
                    processedURL = try await SpatialMediaConverter.processSpatialVideo(inputURL: sourceVideoURL) { update in
                        Task { @MainActor in
                            applyProgress(update, depthInferenceSeconds: nil)
                        }
                    }
                } else {
                    processedURL = try await processor.processVideo(
                        inputURL: sourceVideoURL,
                        strength: appliedStrength,
                        options: appliedOptions,
                        maxDurationSeconds: maxDurationSeconds
                    ) { update in
                        Task {
                            // Latest model timing feeds the ETA; cheap, the actor is idle
                            // between predictions.
                            let stats = await depthEstimator.lastInferenceStats()
                            await MainActor.run {
                                applyProgress(update, depthInferenceSeconds: stats?.seconds)
                            }
                        }
                    }
                }

                if Task.isCancelled {
                    TempFiles.removeItemIfExists(at: processedURL)
                    return
                }

                // A `let`, so the main-actor hop below captures a value, not a mutable box.
                let outputURL = usingSpatialMode ? processedURL : Self.taggedOutputURL(processedURL, model: appliedModel)

                await MainActor.run {
                    outputVideoURL = outputURL
                    outputModel = usingSpatialMode ? nil : appliedModel
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
                    // A downloaded model that no longer loads is dropped from the
                    // selection; the stack-level alert explains the switch, so the raw
                    // error is not shown on top. Spatial splits never touch the model.
                    if usingSpatialMode || !store.handleModelLoadFailure(appliedModel, error: error) {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }

    /// Progress callbacks hop to the main actor one Task per frame, so the odd pair
    /// can land out of order; only forward motion is accepted. The ETA is refreshed
    /// at most once a second to keep the overlay text steady.
    private func applyProgress(_ update: VideoProcessingProgress, depthInferenceSeconds: Double?) {
        guard isProcessing else { return }
        if update.fractionCompleted >= progressValue.fractionCompleted {
            progressValue = update
        }
        if let depthInferenceSeconds {
            lastDepthInferenceSeconds = depthInferenceSeconds
        }

        let now = Date()
        guard now.timeIntervalSince(lastEstimateUpdate) >= 1 else { return }
        lastEstimateUpdate = now
        estimatedSecondsRemaining = estimateSecondsRemaining(at: now)
    }

    /// Two estimates, the larger wins: model time alone (last inference seconds ×
    /// depth frames left ÷ cadence — a lower bound that ignores warp and encode) and
    /// overall throughput so far (elapsed ÷ fraction), which is noisy in the first
    /// frames but accounts for everything once it settles.
    private func estimateSecondsRemaining(at now: Date) -> Double? {
        let fraction = progressValue.fractionCompleted
        let remainingVideoSeconds = max(0, progressValue.totalSeconds - progressValue.processedSeconds)
        var estimates: [Double] = []

        if inputMode == .regular2D,
           let inference = lastDepthInferenceSeconds,
           let frameRate = sourceVideoFrameRate, frameRate > 0 {
            let depthFramesLeft = (remainingVideoSeconds * frameRate / Double(max(1, activeDepthCadence))).rounded(.up)
            estimates.append(inference * depthFramesLeft)
        }

        if let processingStartDate, fraction >= 0.02, fraction < 1 {
            let elapsed = now.timeIntervalSince(processingStartDate)
            estimates.append(elapsed * (1 - fraction) / fraction)
        }

        return estimates.max()
    }

    /// Renames the processor's output so exported files carry the depth model id
    /// (`stereoshift-video-<model>-<uuid>.mp4`), keeping A/B results distinguishable.
    /// Pure file work, hence `nonisolated`: the detached processing task calls it.
    nonisolated private static func taggedOutputURL(_ url: URL, model: DepthModel) -> URL {
        let fileExtension = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        guard let tagged = try? TempFiles.makeTemporaryFileURL(
            prefix: outputFilePrefix("stereoshift-video", model: model),
            fileExtension: fileExtension
        ) else {
            return url
        }
        do {
            try FileManager.default.moveItem(at: url, to: tagged)
            return tagged
        } catch {
            return url
        }
    }

    nonisolated private static func outputFilePrefix(_ base: String, model: DepthModel?) -> String {
        guard let model else { return base }
        return "\(base)-\(model.rawValue)"
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
        guard canExportOutput else {
            onRequireSubscription()
            return
        }
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
        guard canExportOutput else {
            onRequireSubscription()
            return
        }
        guard let outputVideoURL else { return }
        isSaving = true
        saveMessageKey = nil

        Task {
            do {
                try await PhotoLibrarySaver.saveVideoFile(at: outputVideoURL)
                await MainActor.run {
                    isSaving = false
                    saveMessageKey = "Saved to Photos."
                    scheduleReviewPromptAfterVideoExport()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveOutputToDisk() {
        guard let outputVideoURL else { return }
        saveMessageKey = nil

        do {
            let extensionName = outputVideoURL.pathExtension.isEmpty ? "mp4" : outputVideoURL.pathExtension
            let temporaryExportURL = try TempFiles.makeTemporaryFileURL(
                prefix: Self.outputFilePrefix("stereoshift-video-export", model: outputModel),
                fileExtension: extensionName
            )
            try FileManager.default.copyItem(at: outputVideoURL, to: temporaryExportURL)
            saveToDiskSourceURL = temporaryExportURL
            showSaveToDiskMover = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleReviewPromptAfterVideoExport() {
        ReviewPrompter.shared.recordSuccessfulVideoExport()
        guard ReviewPrompter.shared.shouldPromptNow else { return }

        reviewPromptTask?.cancel()
        reviewPromptTask = Task {
            try? await Task.sleep(for: ReviewPrompter.promptDelay)
            guard !Task.isCancelled else { return }
            ReviewPrompter.shared.recordPromptShown()
            requestReview()
        }
    }

    private func isUserCancelledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private var canExportOutput: Bool {
        subscriptionManager.canAccessVideo
    }

    private func presentShareSheet() {
        guard canExportOutput else {
            onRequireSubscription()
            return
        }

        showShareSheet = true
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private struct SourceVideoInfo {
        let durationSeconds: Double
        /// Nominal frame rate of the first video track; nil when the track does not say.
        let frameRate: Double?
    }

    private func loadSourceVideoInfo(for url: URL) async throws -> SourceVideoInfo {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        var frameRate: Double?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let nominal = try? await track.load(.nominalFrameRate),
           nominal > 0 {
            frameRate = Double(nominal)
        }

        return SourceVideoInfo(
            durationSeconds: seconds.isFinite ? max(0, seconds) : 0,
            frameRate: frameRate
        )
    }

    private var isSelectedModelVideoRecommended: Bool {
        depthModelStore.entry(for: depthModelStore.selectedModel)?.videoRecommended ?? true
    }

    private var effectiveDepthCadence: VideoDepthCadence {
        VideoDepthCadenceSetting.effectiveCadence(
            storedRawValue: videoDepthCadenceRawValue,
            tier: depthModelStore.entry(for: depthModelStore.selectedModel)?.tier
        )
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

    private var pickerControls: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $selectedItem, matching: videoPickerFilter, preferredItemEncoding: .current) {
                Label(pickerButtonTitle, systemImage: "video")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || (inputMode == .spatial && !supportsSpatialPicker))

            if supportsDesktopFileImport {
                Button {
                    showFileImporter = true
                } label: {
                    Label(filePickerButtonTitle, systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isProcessing || (inputMode == .spatial && !supportsSpatialPicker))
            }
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 14) {
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

                depthModelRow
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

    private var depthModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Depth Model")
                    .font(.subheadline)
                Spacer()
                Text(verbatim: depthModelStore.selectedModel.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Depth Cadence")
                    .font(.subheadline)
                Spacer()
                Text(effectiveDepthCadence.titleKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !isSelectedModelVideoRecommended {
                Text("Not recommended for video.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
