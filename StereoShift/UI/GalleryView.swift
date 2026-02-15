import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct GalleryView: View {
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @ObservedObject var webServer: GalleryWebServer
    @ObservedObject var subscriptionManager: SubscriptionManager
    @State private var selectedItem: GalleryItem?
    @State private var importPickerItem: PhotosPickerItem?
    @State private var showAddFromPhotosPrompt = false
    @State private var isShowingPhotoImportPicker = false
    @State private var isShowingDiskImporter = false
    @State private var isImporting = false
    @State private var importMessageKey: LocalizedStringKey?
    @State private var isClearingAll = false
    @State private var showClearAllConfirmation = false
    @State private var showVideoSubscriptionSheet = false
    @State private var errorMessage: String?
    @State private var visibleItemCount = 0

    private static let gridCardWidth: CGFloat = 170
    private static let gridCardHeight: CGFloat = 210
    private static let gridThumbnailSide: CGFloat = 150
    private static let gridSpacing: CGFloat = 12

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: Self.gridCardWidth, maximum: Self.gridCardWidth),
                spacing: Self.gridSpacing,
                alignment: .top
            )
        ]
    }
    private let initialPageSize = 120
    private let pageSize = 80

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if galleryLibrary.items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(visibleItems) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                GalleryGridItemView(
                                    item: item,
                                    thumbnailSide: Self.gridThumbnailSide,
                                    cardHeight: Self.gridCardHeight
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                loadMoreIfNeeded(currentItem: item)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .refreshable {
            galleryLibrary.reload()
        }
        .onAppear {
            syncVisibleItemCount()
        }
        .onChange(of: galleryLibrary.items.count) { _, _ in
            syncVisibleItemCount()
        }
        .onChange(of: importPickerItem) { _, newValue in
            importFromPhotos(newValue)
        }
        .onChange(of: webServer.errorMessage) { _, newValue in
            guard let newValue else { return }
            errorMessage = newValue
        }
        .fileImporter(
            isPresented: $isShowingDiskImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            importFromDisk(result)
        }
        .photosPicker(
            isPresented: $isShowingPhotoImportPicker,
            selection: $importPickerItem,
            matching: galleryImportPickerFilter,
            preferredItemEncoding: .current
        )
        .sheet(item: $selectedItem) { item in
            GalleryItemDetailView(item: item, galleryLibrary: galleryLibrary)
        }
        .sheet(isPresented: $showVideoSubscriptionSheet) {
            VideoSubscriptionPaywallView(subscriptionManager: subscriptionManager)
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
            "Before Selecting",
            isPresented: $showAddFromPhotosPrompt,
            titleVisibility: .visible
        ) {
            Button("Confirm") {
                isShowingPhotoImportPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please choose left-right side-by-side 3D images or videos.")
        }
        .confirmationDialog(
            "Delete all items from In-App Gallery?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                clearAllItems()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In-App Gallery")
                        .font(.headline)
                    Text("Saved photos and videos stay on this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Clear All", role: .destructive) {
                        showClearAllConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(galleryLibrary.items.isEmpty || isClearingAll || isImporting)

                    Button {
                        galleryLibrary.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                            .padding(10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isClearingAll || isImporting)
                }
            }

            HStack(spacing: 8) {
                Button {
                    requestPhotosImportAccess()
                } label: {
                    Label("Add from Photos", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isClearingAll || isImporting)

                if supportsDiskImport {
                    Button {
                        isShowingDiskImporter = true
                    } label: {
                        Label("Add from Disk", systemImage: "externaldrive.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isClearingAll || isImporting)
                }
            }

            if isImporting {
                Text("Importing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let importMessageKey {
                Text(importMessageKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    webServer.toggle()
                } label: {
                    Label(webServer.isRunning ? "Stop Web Share" : "Start Web Share", systemImage: webServer.isRunning ? "wifi.slash" : "wifi")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.bordered)
                .disabled(
                    isClearingAll ||
                    isImporting ||
                    (galleryLibrary.items.isEmpty && !webServer.isRunning) ||
                    (!webServer.isWiFiConnected && !webServer.isRunning)
                )

                if let hostAddress = webServer.hostAddress, webServer.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Web share URL:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(verbatim: hostAddress)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)

                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Text("PIN:")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(verbatim: webServer.accessPIN)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Reset PIN") {
                                webServer.resetAccessPIN()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isClearingAll || isImporting)
                        }

                        Text("Keep StereoShift in the foreground while Web Share is running. If the app goes to background, sharing stops.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !webServer.isWiFiConnected {
                    Text("Connect to Wi-Fi to start Web Share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Web share uses local ports 80/443 and redirects HTTP to HTTPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    private var visibleItems: ArraySlice<GalleryItem> {
        galleryLibrary.items.prefix(visibleItemCount)
    }

    private func syncVisibleItemCount() {
        let totalCount = galleryLibrary.items.count
        if totalCount == 0 {
            visibleItemCount = 0
            return
        }
        if visibleItemCount == 0 {
            visibleItemCount = min(initialPageSize, totalCount)
            return
        }
        visibleItemCount = min(max(visibleItemCount, initialPageSize), totalCount)
    }

    private func loadMoreIfNeeded(currentItem: GalleryItem) {
        guard currentItem.id == visibleItems.last?.id else {
            return
        }

        let totalCount = galleryLibrary.items.count
        guard visibleItemCount < totalCount else {
            return
        }

        visibleItemCount = min(totalCount, visibleItemCount + pageSize)
    }

    private func requestPhotosImportAccess() {
        if subscriptionManager.canAccessVideo {
            showAddFromPhotosPrompt = true
            return
        }

        if !subscriptionManager.hasResolvedEntitlements {
            Task { @MainActor in
                await subscriptionManager.refreshEntitlements()
                if subscriptionManager.canAccessVideo {
                    showAddFromPhotosPrompt = true
                } else {
                    showVideoSubscriptionSheet = true
                }
            }
            return
        }

        showVideoSubscriptionSheet = true
    }

    private func clearAllItems() {
        importMessageKey = nil
        isClearingAll = true
        Task {
            do {
                try await galleryLibrary.clearAll()
                await MainActor.run {
                    selectedItem = nil
                    isClearingAll = false
                }
            } catch {
                await MainActor.run {
                    isClearingAll = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var supportsDiskImport: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        ProcessInfo.processInfo.isiOSAppOnMac
#endif
    }

    private var galleryImportPickerFilter: PHPickerFilter {
        if #available(iOS 18.0, *) {
            return .all(of: [.any(of: [.images, .videos]), .not(.spatialMedia)])
        }
        return .any(of: [.images, .videos])
    }

    private func importFromPhotos(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isImporting = true
        importMessageKey = nil

        Task {
            do {
                guard let mediaType = mediaType(for: item) else {
                    throw StereoPipelineError.photoPickerDataUnavailable
                }

                let importURL = try await temporaryImportURL(from: item, type: mediaType)
                defer { try? FileManager.default.removeItem(at: importURL) }
                _ = try await galleryLibrary.saveMedia(at: importURL, type: mediaType)

                await MainActor.run {
                    importPickerItem = nil
                    isImporting = false
                    importMessageKey = "Added to In-App Gallery."
                }
            } catch {
                await MainActor.run {
                    importPickerItem = nil
                    isImporting = false
                    importMessageKey = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importFromDisk(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            isImporting = true
            importMessageKey = nil

            Task {
                do {
                    var importedCount = 0
                    for url in urls {
                        guard let mediaType = mediaType(forFileURL: url) else {
                            continue
                        }
                        _ = try await galleryLibrary.saveMedia(at: url, type: mediaType)
                        importedCount += 1
                    }

                    await MainActor.run {
                        isImporting = false
                        if importedCount > 0 {
                            importMessageKey = "Added to In-App Gallery."
                        } else {
                            errorMessage = String(localized: "Selected files are not supported.")
                        }
                    }
                } catch {
                    await MainActor.run {
                        isImporting = false
                        importMessageKey = nil
                        errorMessage = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func mediaType(for item: PhotosPickerItem) -> GalleryMediaType? {
        for contentType in item.supportedContentTypes {
            if contentType.conforms(to: .image) {
                return .image
            }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return .video
            }
        }
        return nil
    }

    private func mediaType(forFileURL url: URL) -> GalleryMediaType? {
        let pathExtension = url.pathExtension.lowercased()
        if let detectedType = UTType(filenameExtension: pathExtension) {
            if detectedType.conforms(to: .movie) || detectedType.conforms(to: .video) {
                return .video
            }
            if detectedType.conforms(to: .image) {
                return .image
            }
        }
        if ["mp4", "mov", "m4v"].contains(pathExtension) {
            return .video
        }
        if ["png", "jpg", "jpeg", "heic", "heif"].contains(pathExtension) {
            return .image
        }
        return nil
    }

    private func temporaryImportURL(from item: PhotosPickerItem, type: GalleryMediaType) async throws -> URL {
        switch type {
        case .video:
            return try await MediaPicker.loadVideoURL(from: item)
        case .image:
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw StereoPipelineError.photoPickerDataUnavailable
            }

            let fileExtension = preferredImageFileExtension(from: item.supportedContentTypes)
            let importURL = try TempFiles.makeTemporaryFileURL(prefix: "gallery-import-photo", fileExtension: fileExtension)
            try data.write(to: importURL, options: [.atomic])
            return importURL
        }
    }

    private func preferredImageFileExtension(from contentTypes: [UTType]) -> String {
        for contentType in contentTypes where contentType.conforms(to: .image) {
            if let fileExtension = contentType.preferredFilenameExtension, !fileExtension.isEmpty {
                return fileExtension.lowercased()
            }
        }
        return "jpg"
    }
}

private struct GalleryGridItemView: View {
    let item: GalleryItem
    let thumbnailSide: CGFloat
    let cardHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GalleryThumbnailView(item: item)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                }

            if item.type == .image {
                Text("Photo")
                    .font(.subheadline.bold())
                    .lineLimit(1)
            } else {
                Text("Video")
                    .font(.subheadline.bold())
                    .lineLimit(1)
            }

            Text(item.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct GalleryThumbnailView: View {
    let item: GalleryItem
    @State private var thumbnail: UIImage?
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let imageThumbnailMaxPixelSize = 320

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
        .clipped()
        .task(id: item.id) {
            await loadThumbnail()
        }
        .onDisappear {
            thumbnail = nil
        }
    }

    private func loadThumbnail() async {
        let cacheKey = (item.thumbnailURL?.path ?? item.url.path) as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            await MainActor.run {
                thumbnail = cached
            }
            return
        }

        if let thumbnailURL = item.thumbnailURL {
            let loadedFromDisk = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: thumbnailURL.path)
            }.value

            if let loadedFromDisk {
                await MainActor.run {
                    thumbnail = loadedFromDisk
                }
                Self.cache.setObject(loadedFromDisk, forKey: cacheKey, cost: Self.pixelCost(for: loadedFromDisk))
                return
            }
        }

        if item.type == .image {
            let loadingTask = Task.detached(priority: .utility) {
                Self.makeImageThumbnail(from: item.url, maxPixelSize: Self.imageThumbnailMaxPixelSize)
            }
            let loaded = await loadingTask.value
            if let loaded {
                await MainActor.run {
                    thumbnail = loaded
                }
                Self.cache.setObject(loaded, forKey: cacheKey, cost: Self.pixelCost(for: loaded))
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
            Self.cache.setObject(generated, forKey: cacheKey, cost: Self.pixelCost(for: generated))
        } catch {
            await MainActor.run {
                thumbnail = nil
            }
        }
    }

    private static func makeImageThumbnail(from url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private static func pixelCost(for image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let cost = pixelWidth * pixelHeight * 4
        return max(cost, 1)
    }
}

private struct GalleryItemDetailView: View {
    let item: GalleryItem
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showShareSheet = false
    @State private var showDiskExportPicker = false
    @State private var showDeleteConfirmation = false
    @State private var isSaving = false
    @State private var isSavingToDisk = false
    @State private var isDeleting = false
    @State private var saveMessageKey: LocalizedStringKey?
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
                        .disabled(isSaving || isSavingToDisk || isDeleting)

                        Button(action: saveToPhotos) {
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
                        .disabled(isSaving || isSavingToDisk || isDeleting)

                        if supportsDiskSave {
                            Button {
                                showDiskExportPicker = true
                            } label: {
                                Group {
                                    if isSavingToDisk {
                                        Label("Saving…", systemImage: "internaldrive")
                                    } else {
                                        Label("Save to Disk", systemImage: "internaldrive")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving || isSavingToDisk || isDeleting)
                        }
                    }

                    if let saveMessageKey {
                        Text(saveMessageKey)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle(itemTypeTitle)
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
            .sheet(isPresented: $showDiskExportPicker) {
                DiskExportPicker(sourceURL: item.url) { didSave in
                    Task { @MainActor in
                        isSavingToDisk = false
                        showDiskExportPicker = false
                        if didSave {
                            saveMessageKey = "Saved to Disk."
                        }
                    }
                }
            }
            .onChange(of: showDiskExportPicker) { _, isPresented in
                if isPresented {
                    isSavingToDisk = true
                    saveMessageKey = nil
                }
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

    private var itemTypeTitle: LocalizedStringKey {
        switch item.type {
        case .image:
            return "Photo"
        case .video:
            return "Video"
        }
    }

    private var supportsDiskSave: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        ProcessInfo.processInfo.isiOSAppOnMac
#endif
    }

    private func saveToPhotos() {
        isSaving = true
        saveMessageKey = nil

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

private struct DiskExportPicker: UIViewControllerRepresentable {
    let sourceURL: URL
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Bool) -> Void

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(false)
        }
    }
}
