import AVKit
import PhotosUI
import SwiftUI

struct VideoFlowView: View {
    let pipeline: StereoPipeline
    @Binding var strength: Float
    @Binding var sbsLayoutEnabled: Bool

    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceVideoURL: URL?
    @State private var outputVideoURL: URL?
    @State private var isLoadingSelection = false
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var errorMessage: String?
    @State private var progressValue = VideoProcessingProgress(fractionCompleted: 0, processedSeconds: 0, totalSeconds: 1)

    @State private var selectionTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            PhotosPicker(selection: $selectedItem, matching: .videos) {
                Label(sourceVideoURL == nil ? "Pick Video" : "Pick Another Video", systemImage: "video")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing)

            if isLoadingSelection {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sourceVideoURL {
                ResultPreviewView(title: "Input", media: .video(sourceVideoURL))
            }

            Button(action: generateSBSVideo) {
                Label(isProcessing ? "Generating…" : "Generate", systemImage: "sparkles.tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sourceVideoURL == nil || isProcessing || !sbsLayoutEnabled)

            if let outputVideoURL {
                ResultPreviewView(title: "SBS Output", media: .video(outputVideoURL))

                HStack(spacing: 12) {
                    Button(action: saveOutputToPhotos) {
                        Label(isSaving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
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
                    .disabled(isProcessing)
                }
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [outputVideoURL])
                }
            }
        }
        .overlay {
            if isProcessing {
                ProgressViewOverlay(
                    title: "Rendering 3D Video",
                    progress: progressValue.fractionCompleted,
                    detail: progressDetail,
                    onCancel: cancelProcessing
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
        .onChange(of: selectedItem) { _, newValue in
            loadSelectedVideo(newValue)
        }
        .onDisappear {
            selectionTask?.cancel()
            processingTask?.cancel()
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var progressDetail: String {
        let percent = Int((progressValue.fractionCompleted * 100).rounded())
        return "\(percent)% • \(formatTime(progressValue.processedSeconds)) / \(formatTime(progressValue.totalSeconds))"
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
                let loadedURL = try await MediaPicker.loadVideoURL(from: item)
                if Task.isCancelled { return }

                await MainActor.run {
                    sourceVideoURL = loadedURL
                    if let oldOutput = outputVideoURL {
                        TempFiles.removeItemIfExists(at: oldOutput)
                    }
                    outputVideoURL = nil
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

        processingTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let outputURL = try await processor.processVideo(
                    inputURL: sourceVideoURL,
                    strength: appliedStrength
                ) { update in
                    Task { @MainActor in
                        progressValue = update
                    }
                }

                if Task.isCancelled {
                    TempFiles.removeItemIfExists(at: outputURL)
                    return
                }

                await MainActor.run {
                    outputVideoURL = outputURL
                    isProcessing = false
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

    private func saveOutputToPhotos() {
        guard let outputVideoURL else { return }
        isSaving = true

        Task {
            do {
                try await PhotoLibrarySaver.saveVideoFile(at: outputVideoURL)
                await MainActor.run {
                    isSaving = false
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
}
