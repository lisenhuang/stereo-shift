import CoreML
import SwiftUI

/// Persistence for the video "Depth Cadence" setting shared by `SettingsView` and
/// `VideoFlowView`. The stored value is a `VideoDepthCadence.rawValue`, or
/// `automaticRawValue` to follow the selected model's tier: every frame for Small
/// models, every 2 frames for Base and Large ones (which are several times slower).
enum VideoDepthCadenceSetting {
    static let defaultsKey = "videoDepthCadence"
    static let automaticRawValue = 0

    static func automaticCadence(for tier: DepthModelCatalogEntry.Tier?) -> VideoDepthCadence {
        switch tier {
        case .base, .large:
            return .every2Frames
        case .small, nil:
            return .everyFrame
        }
    }

    static func effectiveCadence(storedRawValue: Int, tier: DepthModelCatalogEntry.Tier?) -> VideoDepthCadence {
        if let explicit = VideoDepthCadence(rawValue: storedRawValue) {
            return explicit
        }
        return automaticCadence(for: tier)
    }
}

extension VideoDepthCadence {
    var titleKey: LocalizedStringKey {
        switch self {
        case .everyFrame:
            return "Every frame"
        case .every2Frames:
            return "Every 2 frames"
        case .every4Frames:
            return "Every 4 frames"
        }
    }
}

/// Presents `DepthModelStore.pendingSelectionResetMessage` once and clears it.
/// Attached at the navigation-stack level so it shows wherever the user is when the
/// selection falls back (launch with missing files, or a removal in Settings).
struct DepthModelSelectionResetAlert: ViewModifier {
    @ObservedObject var store: DepthModelStore

    func body(content: Content) -> some View {
        content.alert(
            "Depth Model Changed",
            isPresented: Binding(
                get: { store.pendingSelectionResetMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearPendingSelectionResetMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.clearPendingSelectionResetMessage()
            }
        } message: {
            Text(store.pendingSelectionResetMessage ?? "")
        }
    }
}

/// Settings: optional depth models (download / select / remove), video depth cadence,
/// download preferences and a quick on-device benchmark. Pushed from `HomeView`.
struct SettingsView: View {
    @ObservedObject var store: DepthModelStore
    /// `HomeView`'s view of a running photo/video conversion. Combined with the store's
    /// own `activeConversions` count (`isConversionActive`), which also covers a
    /// conversion that was already running when this screen was pushed.
    var isConversionRunning = false

    /// What the cellular confirmation alert starts once the user agrees. Download and
    /// resume both go through `download(_:allowCellular:)`; an update has its own entry.
    private struct CellularConfirmation {
        enum Action {
            case download
            case update

            var confirmKey: LocalizedStringKey {
                self == .update ? "Update" : "Download"
            }
        }

        let model: DepthModel
        let action: Action
    }

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(VideoDepthCadenceSetting.defaultsKey) private var videoDepthCadenceRawValue = VideoDepthCadenceSetting.automaticRawValue
    @State private var cellularConfirmation: CellularConfirmation?
    @State private var removeConfirmationModel: DepthModel?
    @State private var showRemoveAllConfirmation = false
    @State private var isBenchmarking = false
    @State private var isRemoving = false
    @State private var errorMessage: String?
    @State private var benchmarkTask: Task<Void, Never>?

    var body: some View {
        Form {
            depthModelSection
            videoSection
            downloadsSection
            benchmarkSection
            attributionSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.refreshCatalog()
        }
        // Free space is part of every verdict, so re-evaluate whenever the user may
        // have cleared some: on arrival, on pull-to-refresh and on return from the
        // background (iOS Settings › Storage is where the space gets freed).
        .onAppear {
            store.refreshStates()
        }
        .refreshable {
            store.refreshStates()
            await store.refreshCatalog(force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshStates()
            }
        }
        .onDisappear {
            benchmarkTask?.cancel()
        }
        .alert(
            "Use Cellular Data?",
            isPresented: Binding(
                get: { cellularConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        cellularConfirmation = nil
                    }
                }
            ),
            presenting: cellularConfirmation
        ) { confirmation in
            Button(confirmation.action.confirmKey) {
                startAfterCellularConfirmation(confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text("Download \(formattedSize(for: confirmation.model)) over cellular?")
        }
        .alert(
            Text("Remove \(removeConfirmationModel?.displayName ?? "")?"),
            isPresented: Binding(
                get: { removeConfirmationModel != nil },
                set: { isPresented in
                    if !isPresented {
                        removeConfirmationModel = nil
                    }
                }
            ),
            presenting: removeConfirmationModel
        ) { model in
            Button("Remove", role: .destructive) {
                remove(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This frees \(formattedSize(for: model)). You can download it again later.")
        }
        .alert("Remove all downloaded models?", isPresented: $showRemoveAllConfirmation) {
            Button("Remove All", role: .destructive) {
                removeAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads in progress are cancelled. The built-in model is not affected.")
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
    }

    // MARK: - Sections

    private var depthModelSection: some View {
        Section {
            ForEach(store.entries) { entry in
                if let model = entry.model {
                    DepthModelRow(
                        entry: entry,
                        state: store.state(for: model),
                        compatibility: store.compatibility(for: model),
                        isSelected: store.selectedModel == model,
                        isUpdateAvailable: store.isUpdateAvailable(for: model),
                        isConversionRunning: isConversionActive,
                        onDownload: { requestDownload(model) },
                        onPause: { store.pause(model) },
                        onResume: { requestResume(model) },
                        onCancel: { store.cancel(model) },
                        onUpdate: { requestUpdate(model) },
                        onRemove: { removeConfirmationModel = model },
                        onSelect: { store.select(model) }
                    )
                }
            }
        } header: {
            Text("Depth Model")
        } footer: {
            Text("Models are optional downloads. The built-in model always works offline.")
        }
    }

    private var videoSection: some View {
        Section {
            Picker("Depth Cadence", selection: $videoDepthCadenceRawValue) {
                Text("Automatic").tag(VideoDepthCadenceSetting.automaticRawValue)
                ForEach(VideoDepthCadence.allCases, id: \.rawValue) { cadence in
                    Text(cadence.titleKey).tag(cadence.rawValue)
                }
            }

            LabeledContent("Effective Cadence") {
                Text(effectiveCadence.titleKey)
            }
        } header: {
            Text("Video")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Depth is estimated every N frames and reused in between. Automatic uses every frame for Small models and every 2 frames for Base and Large models.")
                if !videoRecommendedNames.isEmpty {
                    Text("Recommended for video: \(videoRecommendedNames)")
                }
                if !isSelectedModelVideoRecommended {
                    Text("\(store.selectedModel.displayName) is slow for video. Photos are unaffected.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var downloadsSection: some View {
        Section {
            Toggle("Wi-Fi Only", isOn: $store.wifiOnlyDownloads)

            LabeledContent("Space Used", value: DepthModelRow.formatBytes(store.totalInstalledBytes))

            Button("Remove All Downloads", role: .destructive) {
                showRemoveAllConfirmation = true
            }
            .disabled(!hasRemovableDownloads || isConversionActive || isRemoving)
        } header: {
            Text("Downloads")
        } footer: {
            Text("Downloads continue in the background. With Wi-Fi Only on, you are asked before cellular data is used.")
        }
    }

    private var benchmarkSection: some View {
        Section {
            Button(action: runBenchmark) {
                HStack(spacing: 10) {
                    if isBenchmarking {
                        ProgressView()
                        Text("Benchmarking…")
                    } else {
                        Text("Run Benchmark")
                    }
                }
            }
            .disabled(isBenchmarking || isConversionActive || !store.state(for: store.selectedModel).isAvailable)

            if let result = store.benchmarks[store.selectedModel] {
                LabeledContent("Load", value: Self.formatSeconds(result.loadSeconds))
                LabeledContent("First Run", value: Self.formatSeconds(result.firstInferenceSeconds))
                LabeledContent("Median", value: Self.formatMilliseconds(result.medianInferenceSeconds))
                LabeledContent("Compute Units") {
                    Text(Self.computeUnitsKey(result.computeUnits))
                }
            }
        } header: {
            Text("Benchmark")
        } footer: {
            Text("Runs \(store.selectedModel.displayName) on a test image. Results vary with device temperature and background activity.")
        }
    }

    private var attributionSection: some View {
        Section {
            ForEach(attributedEntries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.displayName)
                        .font(.subheadline)
                    Text("Licensed under \(entry.license).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let source = entry.provenance?.sourceRepo ?? entry.sourceURL?.host {
                        Text(verbatim: source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Attribution")
        } footer: {
            Text("Downloaded models are redistributed unchanged from their source repositories.")
        }
    }

    // MARK: - Derived

    /// Either side may learn of a conversion first: `HomeView` flips its flag when a
    /// flow starts, the store counts them (`beginConversion`). The count is published,
    /// so Benchmark / Update / Remove re-enable the moment it drops to zero.
    private var isConversionActive: Bool {
        isConversionRunning || store.activeConversions > 0 || !store.installing.isEmpty
    }

    private var selectedTier: DepthModelCatalogEntry.Tier? {
        store.entry(for: store.selectedModel)?.tier
    }

    private var effectiveCadence: VideoDepthCadence {
        VideoDepthCadenceSetting.effectiveCadence(storedRawValue: videoDepthCadenceRawValue, tier: selectedTier)
    }

    private var isSelectedModelVideoRecommended: Bool {
        store.entry(for: store.selectedModel)?.videoRecommended ?? true
    }

    private var videoRecommendedNames: String {
        store.entries
            .filter(\.videoRecommended)
            .map(\.displayName)
            .formatted(.list(type: .and))
    }

    private var attributedEntries: [DepthModelCatalogEntry] {
        store.entries.filter { !$0.isBundled }
    }

    private var hasRemovableDownloads: Bool {
        store.states.values.contains { state in
            switch state {
            case .installed, .queued, .downloading, .paused, .verifying, .failed:
                return true
            case .builtIn, .notInstalled, .blocked, .preparing:
                return false
            }
        }
    }

    private func formattedSize(for model: DepthModel) -> String {
        DepthModelRow.formatBytes(store.entry(for: model)?.totalBytes ?? 0)
    }

    // MARK: - Actions

    private func requestDownload(_ model: DepthModel) {
        if store.isCellularConfirmationNeeded(for: model) {
            cellularConfirmation = CellularConfirmation(model: model, action: .download)
            return
        }
        // Wi-Fi only is on and we are on Wi-Fi: let the system hold the transfer on
        // cellular rather than refuse it. With the toggle off, cellular is fine.
        store.download(model, allowCellular: !store.wifiOnlyDownloads)
    }

    private func requestResume(_ model: DepthModel) {
        if store.isCellularConfirmationNeeded(for: model) {
            cellularConfirmation = CellularConfirmation(model: model, action: .download)
            return
        }
        store.resume(model)
    }

    /// A newer catalog version of an installed model: same cellular rules as a fresh
    /// download; the store swaps the files once the new copy is installed.
    private func requestUpdate(_ model: DepthModel) {
        if store.isCellularConfirmationNeeded(for: model) {
            cellularConfirmation = CellularConfirmation(model: model, action: .update)
            return
        }
        update(model, allowCellular: !store.wifiOnlyDownloads)
    }

    private func update(_ model: DepthModel, allowCellular: Bool) {
        Task {
            do {
                try await store.update(model, allowCellular: allowCellular)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs what the cellular alert was asked to confirm, with cellular allowed.
    private func startAfterCellularConfirmation(_ confirmation: CellularConfirmation) {
        switch confirmation.action {
        case .download:
            store.download(confirmation.model, allowCellular: true)
        case .update:
            update(confirmation.model, allowCellular: true)
        }
    }

    private func remove(_ model: DepthModel) {
        isRemoving = true
        Task {
            do {
                try await store.remove(model)
            } catch {
                errorMessage = error.localizedDescription
            }
            isRemoving = false
        }
    }

    private func removeAllDownloads() {
        isRemoving = true
        Task {
            await store.removeAllDownloads()
            isRemoving = false
        }
    }

    private func runBenchmark() {
        guard !isBenchmarking else { return }
        isBenchmarking = true
        let model = store.selectedModel
        benchmarkTask = Task {
            do {
                _ = try await store.benchmark(model)
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            isBenchmarking = false
        }
    }

    // MARK: - Formatting

    private static func formatSeconds(_ seconds: Double) -> String {
        Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
    }

    private static func formatMilliseconds(_ seconds: Double) -> String {
        Measurement(value: seconds * 1000, unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private static func computeUnitsKey(_ units: MLComputeUnits) -> LocalizedStringKey {
        switch units {
        case .cpuOnly:
            return "CPU only"
        case .cpuAndGPU:
            return "CPU and GPU"
        case .cpuAndNeuralEngine:
            return "CPU and Neural Engine"
        case .all:
            return "All (CPU, GPU, Neural Engine)"
        @unknown default:
            return "Unknown"
        }
    }
}
