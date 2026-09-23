import AVFoundation
import CoreImage
import ImageIO
import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct GalleryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var galleryLibrary: AppGalleryLibrary
    @ObservedObject var webServer: GalleryWebServer
    @ObservedObject var subscriptionManager: SubscriptionManager
    @State private var selectedItem: GalleryItem?
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var importPickerItems: [PhotosPickerItem] = []
    @State private var showAddFromPhotosPrompt = false
    @State private var isShowingPhotoImportPicker = false
    @State private var isShowingDiskImporter = false
    @State private var isImporting = false
    @State private var importMessageKey: LocalizedStringKey?
    @State private var isClearingAll = false
    @State private var showClearAllConfirmation = false
    @State private var isDeletingSelection = false
    @State private var showDeleteSelectionConfirmation = false
    @State private var showVideoSubscriptionSheet = false
    @State private var errorMessage: String?
    @State private var visibleItemCount = 0
    @State private var isShowingQRCodeSheet = false
    @State private var filter: GalleryFilter = .all
    @State private var gridWidth: CGFloat = 0
    @State private var dragSelection: DragSelection?
    @State private var isShowingSelectionShareSheet = false

    /// Mirrors the Photos grid: square cells, hairline gaps, at least three columns.
    private static let gridSpacing: CGFloat = 2
    private static let gridMinimumCellSide: CGFloat = 110
    private static let gridMinimumColumnCount = 3

    private var columnCount: Int {
        let fitted = Int((gridWidth + Self.gridSpacing) / (Self.gridMinimumCellSide + Self.gridSpacing))
        return max(Self.gridMinimumColumnCount, fitted)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
            count: columnCount
        )
    }
    private let initialPageSize = 120
    private let pageSize = 80

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                    .padding(.horizontal, 16)

                if galleryLibrary.items.isEmpty {
                    emptyState
                        .padding(.horizontal, 16)
                } else {
                    if filter != .all {
                        filterStatusRow
                            .padding(.horizontal, 16)
                    }

                    if filteredItems.isEmpty {
                        filteredEmptyState
                    } else {
                        grid
                    }
                }
            }
            .padding(.bottom, 16)
        }
        // Avoid a janky large-title collapse/expand transition while scrolling this grid.
        .navigationTitle("In-App Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button(areAllFilteredItemsSelected ? "Deselect All" : "Select All") {
                        toggleSelectAll()
                    }
                    .disabled(filteredItems.isEmpty || isDeletingSelection)
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button("Cancel") {
                        exitSelectionMode()
                    }
                    .disabled(isDeletingSelection)
                } else {
                    filterMenu

                    Button("Select") {
                        isSelecting = true
                        selectedItemIDs.removeAll()
                    }
                    .disabled(filteredItems.isEmpty || isClearingAll || isImporting || isDeletingSelection)

                    Menu {
                        Button {
                            galleryLibrary.reload()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            showClearAllConfirmation = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(galleryLibrary.items.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isClearingAll || isImporting || isDeletingSelection)
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Button {
                        isShowingSelectionShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedItemIDs.isEmpty || isDeletingSelection)

                    Spacer()

                    Text(selectionTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .monospacedDigit()
                        // iOS 26 wraps bar text in a glass capsule that otherwise truncates it.
                        .fixedSize()

                    Spacer()

                    Button {
                        showDeleteSelectionConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedItemIDs.isEmpty || isDeletingSelection)
                }
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .refreshable {
            galleryLibrary.reload()
        }
        .onAppear {
            syncVisibleItemCount()
            webServer.refreshNetworkStatus()
        }
        .onChange(of: scenePhase) { _, newValue in
            // Enabling Personal Hotspot in Settings does not change this device's own network
            // path, so NWPathMonitor may not fire. Re-check when the user comes back.
            guard newValue == .active else { return }
            webServer.refreshNetworkStatus()
        }
        .onChange(of: galleryLibrary.items.count) { _, _ in
            syncVisibleItemCount()
            pruneSelectionIfNeeded()
        }
        .onChange(of: filter) { _, _ in
            visibleItemCount = 0
            syncVisibleItemCount()
        }
        .onChange(of: importPickerItems) { _, newValue in
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
            selection: $importPickerItems,
            maxSelectionCount: 0,
            matching: galleryImportPickerFilter,
            preferredItemEncoding: .current
        )
        .sheet(item: $selectedItem) { item in
            GalleryItemDetailView(item: item, galleryLibrary: galleryLibrary)
        }
        .sheet(isPresented: $isShowingQRCodeSheet) {
            if let qrURLString {
                WebShareQRCodeSheet(urlString: qrURLString)
            }
        }
        .sheet(isPresented: $isShowingSelectionShareSheet) {
            ShareSheet(items: selectedItemsInDisplayOrder.map(\.url))
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
        .alert("Before Selecting", isPresented: $showAddFromPhotosPrompt) {
            Button("Confirm") {
                isShowingPhotoImportPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please choose left-right side-by-side 3D images or videos.")
        }
        .alert("Delete all items from In-App Gallery?", isPresented: $showClearAllConfirmation) {
            Button("Delete", role: .destructive) {
                clearAllItems()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete selected items?",
            isPresented: $showDeleteSelectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteSelectedItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the selected items from In-App Gallery.")
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
            ForEach(visibleItems) { item in
                let isSelected = selectedItemIDs.contains(item.id)
                Button {
                    if isSelecting {
                        toggleSelection(for: item)
                    } else {
                        selectedItem = item
                    }
                } label: {
                    GalleryGridCell(
                        item: item,
                        showsSelection: isSelecting,
                        isSelected: isSelected
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.type == .image ? Text("Photo") : Text("Video"))
                .accessibilityValue(Text(item.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute()))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .onAppear {
                    loadMoreIfNeeded(currentItem: item)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            gridWidth = width
        }
        .background {
            GalleryDragSelectionRecognizer(
                isEnabled: isSelecting && !isDeletingSelection,
                columnCount: columnCount,
                spacing: Self.gridSpacing,
                itemCount: visibleItemCount,
                onBegan: beginDragSelection(at:),
                onChanged: updateDragSelection(to:),
                onEnded: endDragSelection
            )
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(GalleryFilter.allCases) { filter in
                    Label(filter.titleKey, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: filter == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .disabled(galleryLibrary.items.isEmpty || isClearingAll || isImporting || isDeletingSelection)
    }

    private var filterStatusRow: some View {
        HStack {
            Text(filter == .videos ? "Showing Videos Only" : "Showing Photos Only")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show All") {
                filter = .all
            }
            .font(.subheadline)
            .disabled(isSelecting)
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .videos ? "video" : "photo")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
            Text(filter == .videos ? "No Videos" : "No Photos")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
            }

            HStack(spacing: 8) {
                Button {
                    requestPhotosImportAccess()
                } label: {
                    Label("Add from Photos", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isClearingAll || isImporting || isSelecting || isDeletingSelection)

                if supportsDiskImport {
                    Button {
                        isShowingDiskImporter = true
                    } label: {
                        Label("Add from Disk", systemImage: "externaldrive.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isClearingAll || isImporting || isSelecting || isDeletingSelection)
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
                    isSelecting ||
                    isDeletingSelection ||
                    (!webServer.isShareNetworkAvailable && !webServer.isRunning)
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
                            Button {
                                isShowingQRCodeSheet = true
                            } label: {
                                Image(systemName: "qrcode")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show QR Code")
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
                } else if !webServer.isShareNetworkAvailable {
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

    private var qrURLString: String? {
        guard webServer.isRunning, let hostAddress = webServer.hostAddress else { return nil }
        // Use http in QR to avoid certificate prompts on scan; server redirects to https and keeps query.
        return "http://\(hostAddress)?code=\(webServer.accessPIN)"
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

    private var filteredItems: [GalleryItem] {
        switch filter {
        case .all:
            return galleryLibrary.items
        case .photos:
            return galleryLibrary.items.filter { $0.type == .image }
        case .videos:
            return galleryLibrary.items.filter { $0.type == .video }
        }
    }

    private var visibleItems: [GalleryItem] {
        Array(filteredItems.prefix(visibleItemCount))
    }

    private func syncVisibleItemCount() {
        let totalCount = filteredItems.count
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

        let totalCount = filteredItems.count
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
                    exitSelectionMode()
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

    private func toggleSelection(for item: GalleryItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func pruneSelectionIfNeeded() {
        guard !selectedItemIDs.isEmpty else { return }
        let ids = Set(galleryLibrary.items.map(\.id))
        selectedItemIDs = selectedItemIDs.intersection(ids)
        if selectedItemIDs.isEmpty && isSelecting {
            // Keep selection mode on, but with an empty selection.
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedItemIDs.removeAll()
        dragSelection = nil
        isDeletingSelection = false
        showDeleteSelectionConfirmation = false
    }

    private var areAllFilteredItemsSelected: Bool {
        !filteredItems.isEmpty && filteredItems.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    private func toggleSelectAll() {
        if areAllFilteredItemsSelected {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = Set(filteredItems.map(\.id))
        }
    }

    private var selectedItemsInDisplayOrder: [GalleryItem] {
        galleryLibrary.items.filter { selectedItemIDs.contains($0.id) }
    }

    /// Same wording as the Photos select toolbar: "Select Items", "3 Photos Selected", …
    private var selectionTitle: LocalizedStringKey {
        let selected = selectedItemsInDisplayOrder
        let count = selected.count
        guard count > 0 else { return "Select Items" }

        if selected.allSatisfy({ $0.type == .image }) {
            return count == 1 ? "1 Photo Selected" : "\(count) Photos Selected"
        }
        if selected.allSatisfy({ $0.type == .video }) {
            return count == 1 ? "1 Video Selected" : "\(count) Videos Selected"
        }
        return "\(count) Items Selected"
    }

    // MARK: Drag to select

    /// A swipe across the grid selects (or deselects, if it started on a selected item) every item
    /// between where it began and where the finger is — the Photos range-selection behaviour.
    private struct DragSelection {
        let anchorIndex: Int
        let selects: Bool
        let baseline: Set<String>
    }

    private func beginDragSelection(at index: Int) {
        let items = visibleItems
        guard items.indices.contains(index) else { return }
        dragSelection = DragSelection(
            anchorIndex: index,
            selects: !selectedItemIDs.contains(items[index].id),
            baseline: selectedItemIDs
        )
        updateDragSelection(to: index)
    }

    private func updateDragSelection(to index: Int) {
        guard let dragSelection else { return }
        let items = visibleItems
        guard !items.isEmpty else { return }

        let current = min(max(index, 0), items.count - 1)
        let anchor = min(dragSelection.anchorIndex, items.count - 1)
        var selection = dragSelection.baseline
        for item in items[min(anchor, current)...max(anchor, current)] {
            if dragSelection.selects {
                selection.insert(item.id)
            } else {
                selection.remove(item.id)
            }
        }

        if selection != selectedItemIDs {
            selectedItemIDs = selection
        }
    }

    private func endDragSelection() {
        dragSelection = nil
    }

    private func deleteSelectedItems() {
        guard !selectedItemIDs.isEmpty else { return }
        isDeletingSelection = true
        importMessageKey = nil

        let idsToDelete = selectedItemIDs
        Task {
            do {
                // Delete in reverse chronological order (matches UI order).
                let itemsToDelete = galleryLibrary.items.filter { idsToDelete.contains($0.id) }
                for item in itemsToDelete {
                    try await galleryLibrary.delete(item)
                }

                await MainActor.run {
                    isDeletingSelection = false
                    exitSelectionMode()
                    importMessageKey = "Deleted."
                }
            } catch {
                await MainActor.run {
                    isDeletingSelection = false
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

    private func importFromPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        importMessageKey = nil

        Task {
            var importedCount = 0

            for item in items {
                do {
                    guard let mediaType = mediaType(for: item) else {
                        continue
                    }

                    let importURL = try await temporaryImportURL(from: item, type: mediaType)
                    defer { try? FileManager.default.removeItem(at: importURL) }
                    _ = try await galleryLibrary.saveMedia(at: importURL, type: mediaType)
                    importedCount += 1
                } catch {
                    continue
                }
            }

            await MainActor.run {
                importPickerItems = []
                isImporting = false
                if importedCount > 0 {
                    importMessageKey = "Added to In-App Gallery."
                } else {
                    importMessageKey = nil
                    errorMessage = String(localized: "Selected files are not supported.")
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

private enum GalleryFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all:
            return "All Items"
        case .photos:
            return "Photos"
        case .videos:
            return "Videos"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "photo.on.rectangle"
        case .photos:
            return "photo"
        case .videos:
            return "video"
        }
    }
}

/// A square Photos-style cell showing the left eye of the SBS item.
private struct GalleryGridCell: View {
    let item: GalleryItem
    let showsSelection: Bool
    let isSelected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GalleryThumbnailView(item: item)
            }
            .clipped()
            .overlay {
                if showsSelection && isSelected {
                    Color.white.opacity(0.2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsSelection && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.25), radius: 1.5)
                        .padding(5)
                } else if item.type == .video {
                    GalleryVideoDurationBadge(url: item.url)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct GalleryVideoDurationBadge: View {
    let url: URL
    @State private var duration: Double?

    private static let cache = NSCache<NSURL, NSNumber>()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // A soft scrim like Photos so the white label stays readable on bright frames.
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            if let duration {
                Text(verbatim: Self.format(duration))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .padding(.trailing, 5)
                    .padding(.bottom, 3)
            }
        }
        .task(id: url) {
            duration = await Self.loadDuration(for: url)
        }
    }

    private static func loadDuration(for url: URL) async -> Double? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.doubleValue
        }

        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else {
            return nil
        }

        let seconds = time.seconds
        cache.setObject(NSNumber(value: seconds), forKey: url as NSURL)
        return seconds
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

/// Photos-style swipe-to-select. SwiftUI gestures inside a ScrollView either block scrolling or
/// scroll along with the selection, so this attaches a UIKit pan to the enclosing UIScrollView:
/// it only begins on a mostly-horizontal swipe, and the scroll view's own pan waits for it to fail,
/// so vertical swipes still scroll. Once selecting, the finger can move over any row and the grid
/// auto-scrolls near the top and bottom edges.
private struct GalleryDragSelectionRecognizer: UIViewRepresentable {
    var isEnabled: Bool
    var columnCount: Int
    var spacing: CGFloat
    var itemCount: Int
    var onBegan: (Int) -> Void
    var onChanged: (Int) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        context.coordinator.anchorView = view
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.panRecognizer.isEnabled = isEnabled
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                coordinator?.detach()
            } else {
                coordinator?.attach(to: enclosingScrollView())
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GalleryDragSelectionRecognizer
        weak var anchorView: AnchorView?
        let panRecognizer = UIPanGestureRecognizer()
        private weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var lastIndex: Int?

        /// Distance from the visible top/bottom edge where auto-scroll kicks in, and its top speed.
        private let autoScrollEdge: CGFloat = 60
        private let autoScrollMaxSpeed: CGFloat = 900

        init(parent: GalleryDragSelectionRecognizer) {
            self.parent = parent
            super.init()
            panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            panRecognizer.delegate = self
            panRecognizer.maximumNumberOfTouches = 1
        }

        func attach(to scrollView: UIScrollView?) {
            guard let scrollView, scrollView !== self.scrollView else { return }
            detach()
            self.scrollView = scrollView
            scrollView.addGestureRecognizer(panRecognizer)
        }

        func detach() {
            stopAutoScroll()
            scrollView?.removeGestureRecognizer(panRecognizer)
            scrollView = nil
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === panRecognizer, parent.isEnabled, let anchorView else {
                return false
            }
            guard anchorView.bounds.contains(panRecognizer.location(in: anchorView)) else {
                return false
            }
            let velocity = panRecognizer.velocity(in: anchorView)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Make the scroll view wait until we decide the swipe is not a selection swipe.
            otherGestureRecognizer === scrollView?.panGestureRecognizer
        }

        // MARK: Pan handling

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let index = currentIndex() else {
                    // Toggling isEnabled cancels the in-flight gesture.
                    recognizer.isEnabled = false
                    recognizer.isEnabled = parent.isEnabled
                    return
                }
                lastIndex = index
                parent.onBegan(index)
                startAutoScroll()
            case .changed:
                reportCurrentIndex()
            default:
                stopAutoScroll()
                lastIndex = nil
                parent.onEnded()
            }
        }

        private func reportCurrentIndex() {
            guard let index = currentIndex(), index != lastIndex else { return }
            lastIndex = index
            parent.onChanged(index)
        }

        /// Maps the finger to an item index using the grid's fixed geometry (square cells, uniform
        /// spacing), so cells LazyVGrid has not built yet still resolve.
        private func currentIndex() -> Int? {
            guard let anchorView, parent.itemCount > 0, parent.columnCount > 0 else { return nil }
            let columns = parent.columnCount
            let spacing = parent.spacing
            let width = anchorView.bounds.width
            let side = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            guard side > 0 else { return nil }

            let point = panRecognizer.location(in: anchorView)
            let pitch = side + spacing
            let column = min(max(Int(point.x / pitch), 0), columns - 1)
            let row = max(Int(floor(point.y / pitch)), 0)
            return min(row * columns + column, parent.itemCount - 1)
        }

        // MARK: Auto-scroll

        private func startAutoScroll() {
            stopAutoScroll()
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func autoScrollTick(_ link: CADisplayLink) {
            guard let scrollView else { return }
            let insets = scrollView.adjustedContentInset
            let locationY = panRecognizer.location(in: scrollView).y - scrollView.contentOffset.y
            let topEdge = insets.top + autoScrollEdge
            let bottomEdge = scrollView.bounds.height - insets.bottom - autoScrollEdge

            let speed: CGFloat
            if locationY < topEdge {
                speed = -autoScrollMaxSpeed * min(1, (topEdge - locationY) / autoScrollEdge)
            } else if locationY > bottomEdge {
                speed = autoScrollMaxSpeed * min(1, (locationY - bottomEdge) / autoScrollEdge)
            } else {
                return
            }

            let minOffset = -insets.top
            let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
            let delta = speed * CGFloat(link.targetTimestamp - link.timestamp)
            let newOffset = min(max(scrollView.contentOffset.y + delta, minOffset), maxOffset)
            guard newOffset != scrollView.contentOffset.y else { return }

            scrollView.contentOffset.y = newOffset
            reportCurrentIndex()
        }
    }
}

private struct WebShareQRCodeSheet: View {
    let urlString: String

    @Environment(\.dismiss) private var dismiss
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = qrUIImage(from: urlString) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 280)
                        .padding(.top, 8)
                }

                Text(urlString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
            .navigationTitle("Web Share QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func qrUIImage(from text: String) -> UIImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard var output = filter.outputImage else { return nil }

        // Scale QR up so it stays sharp when rendered in SwiftUI.
        output = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Loads the item's thumbnail and shows only its left eye, square-cropped like a Photos cell.
private struct GalleryThumbnailView: View {
    let item: GalleryItem
    @State private var thumbnail: UIImage?
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

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
        let cacheKey = item.url.path as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            thumbnail = cached
            return
        }

        let item = item
        let loaded = await Task.detached(priority: .utility) {
            Self.makeLeftEyeThumbnail(for: item)
        }.value

        guard let loaded else { return }
        Self.cache.setObject(loaded, forKey: cacheKey, cost: Self.pixelCost(for: loaded))
        guard !Task.isCancelled else { return }
        thumbnail = loaded
    }

    nonisolated private static func makeLeftEyeThumbnail(for item: GalleryItem) -> UIImage? {
        var source = item.thumbnailURL.flatMap(decodeImage(at:))
        if source.map({ AppGalleryLibrary.isLegacyThumbnail(pixelWidth: $0.width, pixelHeight: $0.height) }) ?? true {
            // Missing, or written by an older version at a size too small to crop — rebuild it once.
            if let upgradedURL = AppGalleryLibrary.regenerateThumbnail(for: item),
               let upgraded = decodeImage(at: upgradedURL) {
                source = upgraded
            }
        }

        guard let source else { return nil }
        return squareLeftEye(of: source).map(UIImage.init(cgImage:))
    }

    nonisolated private static func decodeImage(at url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions)
    }

    /// Takes the left half of the SBS frame, center-crops it to a square and redraws it into its
    /// own bitmap so the cache holds only the visible pixels, not the whole SBS thumbnail.
    nonisolated private static func squareLeftEye(of image: CGImage) -> CGImage? {
        let eyeWidth = max(image.width / 2, 1)
        let side = min(eyeWidth, image.height)
        let cropRect = CGRect(
            x: (eyeWidth - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return cropped
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage() ?? cropped
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
    @Environment(\.requestReview) private var requestReview

    @State private var showShareSheet = false
    @State private var showDiskExportPicker = false
    @State private var showDeleteConfirmation = false
    @State private var isSaving = false
    @State private var isSavingToDisk = false
    @State private var isDeleting = false
    @State private var saveMessageKey: LocalizedStringKey?
    @State private var errorMessage: String?
    @State private var reviewPromptTask: Task<Void, Never>?

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
                ShareSheet(items: [item.url]) { completed in
                    guard completed else { return }
                    scheduleReviewPromptAfterVideoExport()
                }
            }
            .sheet(isPresented: $showDiskExportPicker) {
                DiskExportPicker(sourceURL: item.url) { didSave in
                    Task { @MainActor in
                        isSavingToDisk = false
                        showDiskExportPicker = false
                        if didSave {
                            saveMessageKey = "Saved to Disk."
                            scheduleReviewPromptAfterVideoExport()
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
            .onDisappear {
                reviewPromptTask?.cancel()
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
            .alert("Delete this item from In-App Gallery?", isPresented: $showDeleteConfirmation) {
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

    /// Exporting a photo is a couple of seconds of work, so only video counts towards the
    /// review prompt — the same rule the video flow follows.
    private func scheduleReviewPromptAfterVideoExport() {
        guard item.type == .video else { return }

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
