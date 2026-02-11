import PhotosUI
import SwiftUI

struct PhotoFlowView: View {
    let pipeline: StereoPipeline
    @Binding var strength: Float
    @Binding var sbsLayoutEnabled: Bool

    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceImage: CGImage?
    @State private var outputImage: CGImage?
    @State private var outputFileURL: URL?
    @State private var isLoadingSelection = false
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    @State private var selectionTask: Task<Void, Never>?
    @State private var generateTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            PhotosPicker(selection: $selectedItem, matching: .images) {
                Label(sourceImage == nil ? "Pick Photo" : "Pick Another Photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isGenerating)

            if isLoadingSelection {
                ProgressView("Loading photo…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sourceImage {
                ResultPreviewView(title: "Input", media: .image(sourceImage))
            }

            Button(action: generateSBSPhoto) {
                Label(isGenerating ? "Generating…" : "Generate", systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sourceImage == nil || isGenerating || !sbsLayoutEnabled)

            if let outputImage {
                ResultPreviewView(title: "SBS Output", media: .image(outputImage))
            }

            if let outputFileURL {
                HStack(spacing: 12) {
                    Button(action: saveOutputToPhotos) {
                        Label(isSaving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving || isGenerating)

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
                }
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [outputFileURL])
                }
            }
        }
        .overlay {
            if isGenerating {
                ProgressViewOverlay(
                    title: "Generating 3D Photo",
                    progress: 0.4,
                    detail: "Estimating depth and rendering stereo views.",
                    onCancel: nil
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isGenerating)
        .onChange(of: selectedItem) { _, newValue in
            loadSelectedPhoto(newValue)
        }
        .onDisappear {
            selectionTask?.cancel()
            generateTask?.cancel()
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem?) {
        selectionTask?.cancel()

        guard let item else {
            sourceImage = nil
            outputImage = nil
            outputFileURL = nil
            return
        }

        isLoadingSelection = true
        selectionTask = Task {
            do {
                let image = try await MediaPicker.loadPhoto(from: item)
                if Task.isCancelled { return }

                await MainActor.run {
                    sourceImage = image
                    outputImage = nil
                    outputFileURL = nil
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

    private func generateSBSPhoto() {
        guard let sourceImage else { return }

        generateTask?.cancel()
        isGenerating = true

        let renderer = pipeline.stereoRenderer
        let appliedStrength = strength

        generateTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let output = try await renderer.makeSBS(from: sourceImage, strength: appliedStrength)
                let fileURL = try TempFiles.writePNG(cgImage: output, prefix: "stereoshift-photo")

                if Task.isCancelled {
                    TempFiles.removeItemIfExists(at: fileURL)
                    return
                }

                await MainActor.run {
                    outputImage = output
                    outputFileURL = fileURL
                    isGenerating = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveOutputToPhotos() {
        guard let outputFileURL else { return }
        isSaving = true

        Task {
            do {
                try await PhotoLibrarySaver.saveImageFile(at: outputFileURL)
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
}
