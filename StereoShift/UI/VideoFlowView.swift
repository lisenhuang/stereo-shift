import AVKit
import PhotosUI
import SwiftUI

struct VideoFlowView: View {
    private enum InputMediaMode: String, CaseIterable, Identifiable {
        case regular2D = "2D"
        case spatial = "Spatial"

        var id: String { rawValue }
    }

    let pipeline: StereoPipeline
    @Binding var strength: Float
    @Binding var sbsLayoutEnabled: Bool
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    let onGenerated: () -> Void
    let onProcessingStateChanged: (Bool) -> Void

    @State private var inputMode: InputMediaMode = .regular2D
    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceVideoURL: URL?
    @State private var outputVideoURL: URL?
    @State private var isLoadingSelection = false
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var showStopConfirmation = false
    @State private var errorMessage: String?
    @State private var saveMessage: String?
    @State private var progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)

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
            .disabled(isProcessing || (inputMode == .spatial && !supportsSpatialPicker))

            if isLoadingSelection {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sourceVideoURL {
                ResultPreviewView(title: "Input", media: .video(sourceVideoURL))
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
                    Button(action: saveOutputToInAppGallary) {
                        Label(
                            isSaving ? "Saving…" : "Save to In-App Gallary",
                            systemImage: "tray.and.arrow.down"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving || isProcessing)

                    Button(action: saveOutputToPhotos) {
                        Label(
                            isSaving ? "Saving…" : "Save to Photos",
                            systemImage: "square.and.arrow.down"
                        )
                        .frame(maxWidth: .infinity)
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

                if let saveMessage {
                    Text(saveMessage)
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
                    title: progressTitle,
                    progress: progressValue.fractionCompleted,
                    detail: progressDetail,
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
            onProcessingStateChanged(newValue)
        }
        .onDisappear {
            selectionTask?.cancel()
            processingTask?.cancel()
            onProcessingStateChanged(false)
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Something went wrong.")
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
    }

    private var supportsSpatialPicker: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }

    private var videoPickerFilter: PHPickerFilter {
        if inputMode == .spatial {
            if #available(iOS 18.0, *) {
                return .all(of: [.videos, .spatialMedia])
            }
        }
        return .videos
    }

    private var pickerButtonTitle: String {
        if inputMode == .spatial {
            return sourceVideoURL == nil ? "Pick Spatial Video" : "Pick Another Spatial Video"
        }
        return sourceVideoURL == nil ? "Pick Video" : "Pick Another Video"
    }

    private var generateButtonTitle: String {
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

    private var progressTitle: String {
        inputMode == .spatial ? "Converting Spatial Video" : "Rendering 3D Video"
    }

    private var progressDetail: String {
        let percent = Int((progressValue.fractionCompleted * 100).rounded())
        if inputMode == .spatial {
            return "\(percent)% • Extracting stereo views"
        }
        return "\(percent)% • \(formatTime(progressValue.processedSeconds)) / \(formatTime(progressValue.totalSeconds))"
    }

    private func resetForSourceModeChange() {
        selectionTask?.cancel()
        processingTask?.cancel()

        sourceVideoURL = nil
        if let oldOutput = outputVideoURL {
            TempFiles.removeItemIfExists(at: oldOutput)
        }
        outputVideoURL = nil
        selectedItem = nil
        saveMessage = nil
        progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)
        isLoadingSelection = false
        isProcessing = false
    }

    private func loadSelectedVideo(_ item: PhotosPickerItem?) {
        selectionTask?.cancel()

        guard let item else {
            sourceVideoURL = nil
            outputVideoURL = nil
            return
        }

        isLoadingSelection = true
        selectionTask = Task {
            do {
                if inputMode == .spatial {
                    guard supportsSpatialPicker else {
                        throw StereoPipelineError.spatialPickerUnavailable
                    }
                }

                let loadedURL = try await MediaPicker.loadVideoURL(from: item)
                if Task.isCancelled { return }

                await MainActor.run {
                    sourceVideoURL = loadedURL
                    if let oldOutput = outputVideoURL {
                        TempFiles.removeItemIfExists(at: oldOutput)
                    }
                    outputVideoURL = nil
                    saveMessage = nil
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
        guard let sourceVideoURL else { return }

        processingTask?.cancel()
        isProcessing = true
        progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)

        let processor = pipeline.videoProcessor
        let appliedStrength = strength
        let usingSpatialMode = inputMode == .spatial

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
                        strength: appliedStrength
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
                    saveMessage = nil
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

    private func saveOutputToInAppGallary() {
        guard let outputVideoURL else { return }
        isSaving = true
        saveMessage = nil

        Task {
            do {
                _ = try await galleryLibrary.saveMedia(at: outputVideoURL, type: .video)
                await MainActor.run {
                    isSaving = false
                    saveMessage = "Saved to In-App Gallary."
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
        saveMessage = nil

        Task {
            do {
                try await PhotoLibrarySaver.saveVideoFile(at: outputVideoURL)
                await MainActor.run {
                    isSaving = false
                    saveMessage = "Saved to Photos."
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

    private var strengthLabel: String {
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
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if inputMode == .regular2D {
                HStack {
                    Text("3D Strength")
                        .font(.headline)
                    Spacer()
                    Text("\(strengthLabel) • \(strength.formatted(.number.precision(.fractionLength(2))))")
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
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
