import CoreVideo
import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct PhotoFlowView: View {
    let pipeline: StereoPipeline
    @Binding var inputMode: InputMediaMode
    @Binding var strength: Float
    @Binding var sbsLayoutEnabled: Bool
    @Binding var stereo3DOptions: Stereo3DOptions
    @ObservedObject var subscriptionManager: SubscriptionManager
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    let importedFileURL: URL?
    let onRequireSubscription: () -> Void
    let onGenerated: () -> Void
    let onProcessingStateChanged: (Bool) -> Void

    @Environment(\.requestReview) private var requestReview
    @State private var reviewPromptTask: Task<Void, Never>?

    @State private var didLoadImportedFile = false
    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceImage: CGImage?
    @State private var sourceSpatialPair: StereoImagePair?
    @State private var sourceEmbeddedDepth: CVPixelBuffer?
    @State private var outputImage: CGImage?
    @State private var outputFileURL: URL?
    @State private var isLoadingSelection = false
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var showStopConfirmation = false
    @State private var errorMessage: String?
    @State private var saveMessageKey: LocalizedStringKey?
    @State private var holdsScreenAwakeLock = false
    @State private var showFileImporter = false
    @State private var showSaveToDiskMover = false
    @State private var saveToDiskSourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("stereoshift-photo-export-placeholder")

    @State private var selectionTask: Task<Void, Never>?
    @State private var generateTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            if isLoadingSelection {
                ProgressView("Loading photo…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sourceImage {
                ResultPreviewView(title: "Input", media: .image(sourceImage), allowsFullscreenPreview: true)
            }

            PhotosPicker(selection: $selectedItem, matching: photoPickerFilter, preferredItemEncoding: .current) {
                Label(pickerButtonTitle, systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isGenerating || (inputMode == .spatial && !supportsSpatialPicker))

            if supportsDesktopFileImport {
                Button {
                    showFileImporter = true
                } label: {
                    Label(filePickerButtonTitle, systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isGenerating || (inputMode == .spatial && !supportsSpatialPicker))
            }

            controlsCard

            Button(action: generateSBSPhoto) {
                Label(generateButtonTitle, systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate)

            if let outputImage {
                ResultPreviewView(title: "SBS Output", media: .image(outputImage),
                                  allowsFullscreenPreview: true,
                                  canOpenFullscreen: subscriptionManager.canAccessVideo,
                                  onRequireFullscreenAccess: onRequireSubscription)
            }

            if let outputFileURL {
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
                    .disabled(isSaving || isGenerating)

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
                    .disabled(isSaving || isGenerating)

                    if supportsDesktopFileImport {
                        Button(action: saveOutputToDisk) {
                            Label("Save to Disk", systemImage: "externaldrive")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving || isGenerating)
                    }

                    Button {
                        presentShareSheet()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating || isSaving)

                    RedditPostButton()
                        .disabled(isGenerating || isSaving)
                }
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [outputFileURL]) { completed in
                        if completed { scheduleReviewPromptAfterExport() }
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
        .allowsHitTesting(!isGenerating)
        .overlay {
            if isGenerating {
                ProgressViewOverlay(
                    title: progressTitleText,
                    progress: 0.4,
                    detail: progressDetailText,
                    onCancel: {
                        showStopConfirmation = true
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isGenerating)
        .onAppear {
            if !didLoadImportedFile, let importedFileURL {
                didLoadImportedFile = true
                loadSelectedPhotoFile(importedFileURL)
            }
        }
        .onChange(of: selectedItem) { _, newValue in
            // File imports clear picker selection after loading their own source.
            if newValue != nil { loadSelectedPhoto(newValue) }
        }
        .onChange(of: inputMode) { _, _ in
            resetForSourceModeChange()
        }
        .onChange(of: isGenerating) { _, newValue in
            updateScreenAwakeLock(isActive: newValue)
            onProcessingStateChanged(newValue)
        }
        .onDisappear {
            updateScreenAwakeLock(isActive: false)
            selectionTask?.cancel()
            generateTask?.cancel()
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
                cancelGenerating()
            }
            Button("Continue", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handlePhotoFileImport(result)
        }
        .fileMover(
            isPresented: $showSaveToDiskMover,
            file: saveToDiskSourceURL
        ) { result in
            switch result {
            case .success:
                saveMessageKey = "Saved to Disk."
                scheduleReviewPromptAfterExport()
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

    private var photoPickerFilter: PHPickerFilter {
        if #available(iOS 18.0, *) {
            if inputMode == .spatial {
                return .all(of: [.images, .spatialMedia])
            }
            return .all(of: [.images, .not(.spatialMedia)])
        }
        return .images
    }

    private var pickerButtonTitle: LocalizedStringKey {
        if inputMode == .spatial {
            return sourceImage == nil ? "Pick Spatial Photo" : "Pick Another Spatial Photo"
        }
        return sourceImage == nil ? "Pick Photo" : "Pick Another Photo"
    }

    private var filePickerButtonTitle: LocalizedStringKey {
        if inputMode == .spatial {
            return sourceImage == nil ? "Pick Spatial Photo from Files" : "Pick Another Spatial Photo from Files"
        }
        return sourceImage == nil ? "Pick Photo from Files" : "Pick Another Photo from Files"
    }

    private var generateButtonTitle: LocalizedStringKey {
        if isGenerating {
            return inputMode == .spatial ? "Converting…" : "Generating…"
        }
        return inputMode == .spatial ? "Convert Spatial to SBS" : "Generate"
    }

    private var canGenerate: Bool {
        guard sourceImage != nil, !isGenerating else { return false }
        if inputMode == .spatial, !supportsSpatialPicker {
            return false
        }
        if inputMode == .regular2D {
            return sbsLayoutEnabled
        }
        return true
    }

    private var progressTitleText: Text {
        inputMode == .spatial ? Text("Converting Spatial Photo") : Text("Generating 3D Photo")
    }

    private var progressDetailText: Text {
        inputMode == .spatial
            ? Text("Separating stereo views and building SBS output.")
            : Text("Estimating depth and rendering stereo views.")
    }

    private func resetForSourceModeChange() {
        selectionTask?.cancel()
        generateTask?.cancel()

        selectedItem = nil
        sourceImage = nil
        sourceSpatialPair = nil
        sourceEmbeddedDepth = nil
        outputImage = nil
        outputFileURL = nil
        saveMessageKey = nil
        isLoadingSelection = false
        showFileImporter = false
        clearRenderCache()
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem?) {
        selectionTask?.cancel()

        guard let item else {
            sourceImage = nil
            sourceSpatialPair = nil
            outputImage = nil
            outputFileURL = nil
            clearRenderCache()
            return
        }

        isLoadingSelection = true
        selectionTask = Task {
            do {
                if inputMode == .spatial {
                    guard supportsSpatialPicker else {
                        throw StereoPipelineError.spatialPickerUnavailable
                    }

                    let pair = try await MediaPicker.loadSpatialPhotoPair(from: item)
                    if Task.isCancelled { return }

                    await MainActor.run {
                        sourceImage = pair.left
                        sourceSpatialPair = pair
                        sourceEmbeddedDepth = nil
                        outputImage = nil
                        outputFileURL = nil
                        saveMessageKey = nil
                        isLoadingSelection = false
                        clearRenderCache()
                    }
                } else {
                    let picked = try await MediaPicker.loadPhotoWithEmbeddedDepth(from: item)
                    if Task.isCancelled { return }

                    await MainActor.run {
                        sourceImage = picked.image
                        sourceSpatialPair = nil
                        sourceEmbeddedDepth = picked.embeddedDepth
                        outputImage = nil
                        outputFileURL = nil
                        saveMessageKey = nil
                        isLoadingSelection = false
                        clearRenderCache()
                    }
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

    private func handlePhotoFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            loadSelectedPhotoFile(url)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedPhotoFile(_ url: URL) {
        selectionTask?.cancel()
        isLoadingSelection = true

        selectionTask = Task {
            do {
                if inputMode == .spatial {
                    guard supportsSpatialPicker else {
                        throw StereoPipelineError.spatialPickerUnavailable
                    }

                    let pair = try await Task.detached(priority: .userInitiated) {
                        try MediaPicker.loadSpatialPhotoPair(fromFileURL: url)
                    }.value
                    if Task.isCancelled { return }

                    await MainActor.run {
                        selectedItem = nil
                        sourceImage = pair.left
                        sourceSpatialPair = pair
                        sourceEmbeddedDepth = nil
                        outputImage = nil
                        outputFileURL = nil
                        saveMessageKey = nil
                        isLoadingSelection = false
                        clearRenderCache()
                    }
                } else {
                    let picked = try await Task.detached(priority: .userInitiated) {
                        try MediaPicker.loadPhotoWithEmbeddedDepth(fromFileURL: url)
                    }.value
                    if Task.isCancelled { return }

                    await MainActor.run {
                        selectedItem = nil
                        sourceImage = picked.image
                        sourceSpatialPair = nil
                        sourceEmbeddedDepth = picked.embeddedDepth
                        outputImage = nil
                        outputFileURL = nil
                        saveMessageKey = nil
                        isLoadingSelection = false
                        clearRenderCache()
                    }
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

    private func generateSBSPhoto() {
        generateTask?.cancel()
        isGenerating = true
        let focusDotsEnabled = stereo3DOptions.focusDotsEnabled

        if inputMode == .spatial {
            guard let sourceSpatialPair else {
                isGenerating = false
                return
            }

            generateTask = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    let output = try SpatialMediaConverter.makeSBSImage(from: sourceSpatialPair, focusDotsEnabled: focusDotsEnabled)
                    let fileURL = try TempFiles.writePNG(cgImage: output, prefix: "stereoshift-spatial-photo")

                    if Task.isCancelled {
                        TempFiles.removeItemIfExists(at: fileURL)
                        return
                    }

                    await MainActor.run {
                        outputImage = output
                        outputFileURL = fileURL
                        saveMessageKey = nil
                        isGenerating = false
                        onGenerated()
                    }
                } catch {
                    if Task.isCancelled {
                        await MainActor.run {
                            isGenerating = false
                        }
                        return
                    }
                    await MainActor.run {
                        isGenerating = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        guard let sourceImage else {
            isGenerating = false
            return
        }

        let renderer = pipeline.stereoRenderer
        let depthEstimator = pipeline.depthEstimator
        let appliedStrength = strength
        var appliedOptions = stereo3DOptions
        appliedOptions.depthModel = .depthAnythingV2SmallF16
        appliedOptions.renderEngine = .metal
        appliedOptions.renderProfile = .ultraFast

        generateTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let rgbBuffer = try PixelBufferUtilities.makePixelBuffer(from: sourceImage)
                let rawDepth = try await depthEstimator.predictRawDepth(
                    pixelBuffer: rgbBuffer,
                    model: appliedOptions.depthModel,
                    quality: appliedOptions.depthQuality
                )
                let outputBuffer = try renderer.makeSBS(
                    from: rgbBuffer,
                    rawDepth: rawDepth,
                    strength: appliedStrength,
                    options: appliedOptions
                )
                let exportBuffer = try StereoFocusDots.addingIfEnabled(to: outputBuffer, enabled: appliedOptions.focusDotsEnabled)
                let output = try PixelBufferUtilities.makeCGImage(from: exportBuffer)
                let jpegQuality: Float = 0.95
                let fileURL = try TempFiles.writeJPEG(cgImage: output, prefix: "stereoshift-photo", quality: jpegQuality)

                if Task.isCancelled {
                    TempFiles.removeItemIfExists(at: fileURL)
                    return
                }

                await MainActor.run {
                    outputImage = output
                    outputFileURL = fileURL
                    saveMessageKey = nil
                    isGenerating = false
                    onGenerated()
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        isGenerating = false
                    }
                    return
                }
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func clearRenderCache() {
        // No-op: strength changes no longer trigger automatic regeneration.
    }

    private func cancelGenerating() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
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

    private func scheduleReviewPromptAfterExport() {
        ReviewPrompter.shared.recordSuccessfulExport(isPaidUser: subscriptionManager.canAccessVideo)
        guard subscriptionManager.canAccessVideo, ReviewPrompter.shared.shouldPromptNow else { return }

        reviewPromptTask?.cancel()
        reviewPromptTask = Task {
            try? await Task.sleep(for: ReviewPrompter.promptDelay)
            guard !Task.isCancelled, subscriptionManager.canAccessVideo, ReviewPrompter.shared.shouldPromptNow else { return }
            ReviewPrompter.shared.recordPromptShown()
            requestReview()
        }
    }

    private func presentShareSheet() {
        guard subscriptionManager.canAccessVideo else {
            onRequireSubscription()
            return
        }
        showShareSheet = true
    }

    private func saveOutputToInAppGallery() {
        guard subscriptionManager.canAccessVideo else {
            onRequireSubscription()
            return
        }
        guard let outputFileURL else { return }
        isSaving = true
        saveMessageKey = nil

        Task {
            do {
                _ = try await galleryLibrary.saveMedia(at: outputFileURL, type: .image)
                await MainActor.run {
                    isSaving = false
                    saveMessageKey = "Saved to In-App Gallery."
                    scheduleReviewPromptAfterExport()
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
        guard subscriptionManager.canAccessVideo else {
            onRequireSubscription()
            return
        }
        guard let outputFileURL else { return }
        isSaving = true
        saveMessageKey = nil

        Task {
            do {
                try await PhotoLibrarySaver.saveImageFile(at: outputFileURL)
                await MainActor.run {
                    isSaving = false
                    saveMessageKey = "Saved to Photos."
                    scheduleReviewPromptAfterExport()
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
        guard subscriptionManager.canAccessVideo else {
            onRequireSubscription()
            return
        }
        guard let outputFileURL else { return }
        saveMessageKey = nil

        do {
            let extensionName = outputFileURL.pathExtension.isEmpty ? "png" : outputFileURL.pathExtension
            let temporaryExportURL = try TempFiles.makeTemporaryFileURL(prefix: "stereoshift-photo-export", fileExtension: extensionName)
            try FileManager.default.copyItem(at: outputFileURL, to: temporaryExportURL)
            saveToDiskSourceURL = temporaryExportURL
            showSaveToDiskMover = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isUserCancelledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
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

            Toggle(isOn: $stereo3DOptions.focusDotsEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Focus Dots")
                    Text("White dots on a black strip above both views help you align your eyes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isGenerating)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
