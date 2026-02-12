import AVFoundation
import SwiftUI
import UIKit

struct GalleryView: View {
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @State private var selectedItem: GalleryItem?

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 14) {
            header

            if galleryLibrary.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(galleryLibrary.items) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                GalleryGridItemView(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                .refreshable {
                    galleryLibrary.reload()
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            GalleryItemDetailView(item: item, galleryLibrary: galleryLibrary)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("In-App Gallery")
                    .font(.headline)
                Text("Saved photos and videos stay on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                galleryLibrary.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
                    .padding(10)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No media in In-App Gallery yet.")
                .font(.headline)
            Text("Generate a photo or video, then choose \"Save to In-App Gallery\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct GalleryGridItemView: View {
    let item: GalleryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GalleryThumbnailView(item: item)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                }

            Text(item.type == .image ? "Photo" : "Video")
                .font(.subheadline.bold())

            Text(Self.dateFormatter.string(from: item.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct GalleryThumbnailView: View {
    let item: GalleryItem
    @State private var thumbnail: UIImage?
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: item.type == .image ? "photo" : "video")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let cacheKey = item.url.path as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            await MainActor.run {
                thumbnail = cached
            }
            return
        }

        if item.type == .image {
            if let loaded = UIImage(contentsOfFile: item.url.path) {
                await MainActor.run {
                    thumbnail = loaded
                }
                Self.cache.setObject(loaded, forKey: cacheKey)
            }
            return
        }

        do {
            let generated = try await Task.detached(priority: .utility) {
                let asset = AVAsset(url: item.url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 220, height: 220)
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                return UIImage(cgImage: cgImage)
            }.value
            await MainActor.run {
                thumbnail = generated
            }
            Self.cache.setObject(generated, forKey: cacheKey)
        } catch {
            await MainActor.run {
                thumbnail = nil
            }
        }
    }
}

private struct GalleryItemDetailView: View {
    let item: GalleryItem
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showShareSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var saveMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ResultPreviewView(title: "Preview", media: previewMedia, allowsFullscreenPreview: true)

                    HStack(spacing: 12) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDeleting)

                        Button(action: saveToPhotos) {
                            Label(isSaving ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving || isDeleting)
                    }

                    if let saveMessage {
                        Text(saveMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle(item.type == .image ? "Photo" : "Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(isDeleting || isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [item.url])
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
            .confirmationDialog(
                "Delete this item from In-App Gallery?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteItem()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var previewMedia: PreviewMedia {
        switch item.type {
        case .image:
            return .imageFile(item.url)
        case .video:
            return .video(item.url)
        }
    }

    private func saveToPhotos() {
        isSaving = true
        saveMessage = nil

        Task {
            do {
                switch item.type {
                case .image:
                    try await PhotoLibrarySaver.saveImageFile(at: item.url)
                case .video:
                    try await PhotoLibrarySaver.saveVideoFile(at: item.url)
                }

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

    private func deleteItem() {
        isDeleting = true

        Task {
            do {
                try await galleryLibrary.delete(item)
                await MainActor.run {
                    isDeleting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
