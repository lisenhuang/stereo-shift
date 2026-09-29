import SwiftUI

struct InstagramImportView: View {
    let request: PendingInstagramImport
    let onImported: (ImportedInstagramMedia) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var loadingProgress: Double?
    @State private var importAttemptID = UUID()
    @State private var resolvedPost: InstagramMediaImporter.ResolvedPost?
    @State private var selectedCandidate: InstagramMediaImporter.Candidate?
    @State private var isChoosing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("Retry", action: startImport)
                        .buttonStyle(.borderedProminent)
                    if let resolvedPost, resolvedPost.candidates.count > 1 {
                        Button("Choose another item") {
                            selectedCandidate = nil
                            self.errorMessage = nil
                            isChoosing = true
                        }
                    }
                } else if isChoosing, let resolvedPost {
                    Text(resolvedPost.candidates.allSatisfy { $0.kind == .photo }
                         ? LocalizedStringKey("Choose a photo") : LocalizedStringKey("Choose an image or video"))
                        .font(.headline)
                    Text("Select one item to convert to 3D.")
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 12) {
                            ForEach(Array(resolvedPost.candidates.enumerated()), id: \.offset) { index, candidate in
                                Button {
                                    selectedCandidate = candidate
                                    isChoosing = false
                                    startImport()
                                } label: {
                                    InstagramCandidateThumbnail(post: resolvedPost, candidate: candidate, index: index)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                            }
                        }
                    }
                } else if let loadingProgress {
                    ProgressView(value: loadingProgress) {
                        Text("Loading...")
                    } currentValueLabel: {
                        Text(loadingProgress, format: .percent.precision(.fractionLength(0)).rounded(rule: .down))
                            .monospacedDigit()
                    }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                } else {
                    ProgressView("Loading...")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Shared from Instagram")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { if resolvedPost == nil { startImport() } }
            .onDisappear {
                importTask?.cancel()
                resolvedPost?.cancel()
            }
            .interactiveDismissDisabled(isImporting)
        }
    }

    private func startImport() {
        guard !isImporting else { return }
        errorMessage = nil
        loadingProgress = nil
        let attemptID = UUID()
        importAttemptID = attemptID
        isImporting = true
        importTask = Task {
            defer { isImporting = false }
            do {
                let post: InstagramMediaImporter.ResolvedPost
                if let resolvedPost {
                    post = resolvedPost
                } else {
                    post = try await InstagramMediaImporter.prepare(postURL: request.url)
                    try Task.checkCancellation()
                    resolvedPost = post
                }
                if selectedCandidate == nil, post.candidates.count > 1 {
                    isChoosing = true
                    return
                }
                guard let candidate = selectedCandidate ?? post.candidates.first else {
                    throw InstagramImportError.unavailable
                }
                let media = try await InstagramMediaImporter.download(candidate, from: post, onProgress: { progress in
                    Task { @MainActor in
                        guard isImporting, importAttemptID == attemptID else { return }
                        loadingProgress = max(loadingProgress ?? 0, progress)
                    }
                })
                guard !Task.isCancelled else {
                    TempFiles.removeItemIfExists(at: media.url)
                    return
                }
                onImported(media)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct InstagramCandidateThumbnail: View {
    let post: InstagramMediaImporter.ResolvedPost
    let candidate: InstagramMediaImporter.Candidate
    let index: Int
    @State private var image: CGImage?
    @State private var finishedLoading = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.secondary.opacity(0.1)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if finishedLoading {
                    Image(systemName: candidate.kind == .photo ? "photo" : "film")
                        .font(.largeTitle)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 140)
            .clipped()
            if candidate.kind == .photo {
                Text("Photo \(index + 1)")
            } else {
                Text("Video \(index + 1)")
            }
        }
        .contentShape(Rectangle())
        .task {
            image = try? await InstagramMediaImporter.thumbnail(candidate, from: post)
            finishedLoading = true
        }
    }
}
