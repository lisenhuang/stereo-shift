import SwiftUI

struct StereoCameraFlowView: View {
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @ObservedObject var subscriptionManager: SubscriptionManager
    let focusDotsEnabled: Bool
    let onRequireSubscription: () -> Void
    let onProcessingStateChanged: (Bool) -> Void

    @Environment(\.locale) private var locale
    @State private var showCamera = false
    @State private var showShareSheet = false
    @State private var outputImage: CGImage?
    @State private var outputURL: URL?
    @State private var isComposing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveMessage: LocalizedStringKey?
    @State private var compositionTask: Task<Void, Never>?

    private let mint = Color(red: 0.62, green: 0.94, blue: 0.76)
    private var isBusy: Bool { showCamera || isComposing || isSaving }

    var body: some View {
        VStack(spacing: 20) {
            if let outputImage {
                result(outputImage)
            } else if isComposing {
                ProgressView("Creating your stereo photo…")
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                introduction
            }
            if outputImage != nil || isComposing { captureButton }
            if outputImage == nil {
                Text("Both photos are taken here in StereoShift. Everything stays on your device.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            StereoCameraView(onComplete: compose)
                .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        }
        .sheet(isPresented: $showShareSheet) {
            if let outputURL { ShareSheet(items: [outputURL]) }
        }
        .onChange(of: isBusy) { _, busy in onProcessingStateChanged(busy) }
        .onDisappear {
            if !showCamera && !showShareSheet {
                compositionTask?.cancel()
                onProcessingStateChanged(false)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private var captureButton: some View {
            Button { showCamera = true } label: {
                Label(LocalizedStringKey(outputImage == nil ? "Open stereo camera" : "Take another stereo photo"), systemImage: "camera.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isComposing || isSaving)
            .accessibilityIdentifier("openStereoCamera")
    }

    private var introduction: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 22) {
                Label("STEREO CAMERA", systemImage: "viewfinder")
                    .font(.caption.weight(.bold)).tracking(2).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Two photos.\nOne 3D moment.")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("Capture real depth with a small step to the right.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                captureDiagram
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(
                LinearGradient(colors: [Color(red: 0.08, green: 0.18, blue: 0.18), Color(red: 0.04, green: 0.08, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 24)
            )
            captureButton
            VStack(alignment: .leading, spacing: 18) {
                instruction(number: "1", title: "Take the left photo", detail: "Frame a still subject and tap the shutter.")
                instruction(number: "2", title: "Slide about 6.4 cm right", detail: "Follow the guide. Keep the phone level and facing the same way.")
                instruction(number: "3", title: "Take the right photo", detail: "Review both shots, then create your SBS photo.")
            }
            .padding(.horizontal, 4)
            Label {
                Text("Best with still scenes at least 2 metres away. Avoid moving people, pets and close-ups.")
                    .font(.footnote)
            } icon: { Image(systemName: "sparkle") }
            .foregroundStyle(.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var captureDiagram: some View {
        HStack(spacing: 14) {
            diagramPhone(title: "LEFT", filled: true)
            VStack(spacing: 8) {
                Text("6.4 cm").font(.title3.monospacedDigit().weight(.semibold))
                Image(systemName: "arrow.right").font(.title2).frame(maxWidth: .infinity)
                Text("SLIDE, DON'T TURN").font(.system(size: 8, weight: .bold)).tracking(1)
            }
            .foregroundStyle(mint)
            diagramPhone(title: "RIGHT", filled: false)
        }
        .padding(.top, 4)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Take a left photo, slide the phone 6.4 centimetres to the right without turning, then take a right photo.")
    }

    private func diagramPhone(title: LocalizedStringKey, filled: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(mint.opacity(filled ? 0.14 : 0.04))
                RoundedRectangle(cornerRadius: 14)
                    .stroke(mint.opacity(filled ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: filled ? [] : [5, 4]))
                Image(systemName: "mountain.2.fill").font(.title2).foregroundStyle(mint.opacity(0.8))
                VStack {
                    Capsule().fill(mint.opacity(0.5)).frame(width: 18, height: 3).padding(.top, 9)
                    Spacer()
                }
            }
            .frame(width: 64, height: 86)
            Text(title).font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.65))
        }
    }

    private func instruction(number: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 30, height: 30).background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func result(_ image: CGImage) -> some View {
        VStack(spacing: 14) {
            Label("Stereo photo ready", systemImage: "checkmark.circle.fill")
                .font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
            ResultPreviewView(title: "SBS Output", media: .image(image), allowsFullscreenPreview: true,
                              canOpenFullscreen: subscriptionManager.canAccessVideo,
                              onRequireFullscreenAccess: onRequireSubscription)
            Text("Two captured views, combined side by side.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { export(toGallery: true) } label: {
                Label("Save to In-App Gallery", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            Button { export(toGallery: false) } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            Button {
                guard subscriptionManager.canAccessVideo else { onRequireSubscription(); return }
                showShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            RedditPostButton()
            if isSaving { ProgressView("Saving…") }
            if let saveMessage { Text(saveMessage).font(.footnote).foregroundStyle(.secondary) }
        }
        .disabled(isSaving || isComposing)
    }

    private func compose(_ pair: StereoImagePair) {
        compositionTask?.cancel()
        isComposing = true
        let focusDots = focusDotsEnabled
        compositionTask = Task {
            do {
                let (image, url) = try await Task.detached(priority: .userInitiated) {
                    let image = try SpatialMediaConverter.makeSBSImage(from: pair, focusDotsEnabled: focusDots)
                    let url = try TempFiles.writeJPEG(cgImage: image, prefix: "stereoshift-camera", quality: 0.95)
                    return (image, url)
                }.value
                guard !Task.isCancelled else { TempFiles.removeItemIfExists(at: url); return }
                if let outputURL { TempFiles.removeItemIfExists(at: outputURL) }
                outputImage = image
                outputURL = url
                saveMessage = nil
                isComposing = false
            } catch {
                guard !Task.isCancelled else { return }
                isComposing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func export(toGallery: Bool) {
        guard subscriptionManager.canAccessVideo else { onRequireSubscription(); return }
        guard let outputURL else { return }
        isSaving = true
        saveMessage = nil
        Task {
            do {
                if toGallery {
                    _ = try await galleryLibrary.saveMedia(at: outputURL, type: .image)
                    saveMessage = "Saved to In-App Gallery."
                } else {
                    try await PhotoLibrarySaver.saveImageFile(at: outputURL)
                    saveMessage = "Saved to Photos."
                }
                ReviewPrompter.shared.recordSuccessfulExport(isPaidUser: subscriptionManager.canAccessVideo)
            } catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }
}
