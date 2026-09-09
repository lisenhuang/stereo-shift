import Combine
import CoreML
import Foundation
import Network

/// Owns everything about optional depth models: which ones the catalog offers, which
/// are installed, download/pause/resume/cancel, the compile + warm-up install step,
/// removal, selection and the Settings benchmark.
///
/// Reach it through `StereoPipeline.depthModelStore`. Everything is main-actor; long
/// work (transfers, hashing, compile, warm-up) happens elsewhere and reports back.
///
/// State per model (`state(for:)` / `states`):
/// - `.builtIn` — shipped in the bundle, always available.
/// - `.notInstalled` / `.blocked(reason)` — downloadable, or not on this device.
/// - `.queued` → `.downloading(...)` → `.verifying` → `.preparing` → `.installed`.
/// - `.paused(fraction)` after `pause(_:)`; `.failed(reason)` after any error
///   (retry with `download(_:allowCellular:)` — staged files are kept).
///
/// Install is all-or-nothing: a compile or contract failure removes every trace and
/// reports `.failed`, so `.installed` always means "loads and produces usable depth".
@MainActor
final class DepthModelStore: ObservableObject {
    enum InstallState: Equatable {
        case builtIn
        case notInstalled
        case blocked(String)
        case queued
        case downloading(fraction: Double, bytesReceived: Int64, totalBytes: Int64)
        case paused(fraction: Double)
        case verifying
        case preparing
        case installed
        case failed(String)

        /// Usable by the pipeline right now.
        var isAvailable: Bool {
            switch self {
            case .builtIn, .installed: return true
            default: return false
            }
        }

        /// A download or install is in progress (not paused/failed).
        var isBusy: Bool {
            switch self {
            case .queued, .downloading, .verifying, .preparing: return true
            default: return false
            }
        }

        /// State that must survive a catalog refresh (`rebuildStates`).
        fileprivate var isTransient: Bool {
            switch self {
            case .queued, .downloading, .paused, .verifying, .preparing, .failed: return true
            default: return false
            }
        }
    }

    /// Remote copy of `Resources/depth-models.json`; merged over the bundled catalog.
    nonisolated static let remoteCatalogURL = URL(string: "https://raw.githubusercontent.com/lisenhuang/stereo-shift/main/StereoShift/Resources/depth-models.json")!
    nonisolated static let selectedModelDefaultsKey = "depthModel"
    nonisolated static let wifiOnlyDefaultsKey = "depthModelWifiOnly"
    nonisolated private static let catalogFetchInterval: TimeInterval = 24 * 60 * 60
    nonisolated private static let catalogRequestTimeout: TimeInterval = 8
    /// How long the install step waits for a running conversion before giving up.
    nonisolated private static let warmUpBusyRetries = 120

    @Published private(set) var catalog: DepthModelCatalog
    @Published private(set) var states: [DepthModel: InstallState] = [:]
    /// The model conversions should use. Persisted; only installed models can be set
    /// (use `select(_:)`). Resets to the bundled model when the stored one is missing.
    @Published var selectedModel: DepthModel = .bundledDefault {
        didSet { userDefaults.set(selectedModel.rawValue, forKey: Self.selectedModelDefaultsKey) }
    }
    /// When on, downloads on cellular/constrained paths need explicit confirmation
    /// (`isCellularConfirmationNeeded(for:)`). Persisted; default true.
    @Published var wifiOnlyDownloads = true {
        didSet { userDefaults.set(wifiOnlyDownloads, forKey: Self.wifiOnlyDefaultsKey) }
    }
    @Published private(set) var totalInstalledBytes: Int64 = 0
    @Published private(set) var benchmarks: [DepthModel: DepthBenchmarkResult] = [:]
    /// One-shot alert text set when a persisted selection had to fall back to the
    /// bundled model; clear with `clearPendingSelectionResetMessage()`.
    @Published private(set) var pendingSelectionResetMessage: String?
    /// Conversions currently running (see `beginConversion`/`endConversion`); the
    /// benchmark counts as one. Remove and benchmark are refused while this is non-zero
    /// and the install warm-up waits for it to drop to zero.
    @Published private(set) var activeConversions = 0

    private let depthEstimator: DepthEstimator
    private let downloader: any DepthModelDownloading
    private let userDefaults: UserDefaults
    private let session: URLSession
    /// Fixed device profile for tests (nil evaluates the live device on every check).
    /// Internal so a test can change the device between `refreshStates()` calls.
    var deviceOverride: DeviceProfile?
    private let appBuild: Int
    private let bundledCatalog: DepthModelCatalog
    /// Models whose downloaded files are being compiled / warmed up right now.
    @Published private(set) var installing: Set<DepthModel> = []
    private var cellularAllowance: [DepthModel: Bool] = [:]
    /// The catalog entry each in-flight download was started with. A catalog refresh
    /// may bump the version mid-download; pause/resume/cancel and event matching keep
    /// using this one so they still address the download that is actually running.
    private var activeDownloadEntries: [DepthModel: DepthModelCatalogEntry] = [:]
    /// Models to select again once their `update(_:allowCellular:)` install lands.
    private var reselectAfterInstall: Set<DepthModel> = []
    private var lastProgress: [DepthModel: (fraction: Double, bytesReceived: Int64, totalBytes: Int64)] = [:]
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.huanglisen.stereoshift.depthmodels.pathmonitor")
    private var isExpensivePath = false
    private var reconcileTask: Task<Void, Never>?

    /// - Parameters:
    ///   - catalog: nil loads the bundled `depth-models.json` (plus the cached remote
    ///     copy); a malformed bundle falls back to a catalog with only the bundled model.
    ///   - downloader: nil uses the shared background-session downloader.
    ///   - device: nil evaluates the live device on every check (tests inject a fixed one).
    init(
        depthEstimator: DepthEstimator,
        catalog: DepthModelCatalog? = nil,
        downloader: (any DepthModelDownloading)? = nil,
        userDefaults: UserDefaults = .standard,
        device: DeviceProfile? = nil,
        appBuild: Int = DepthModelCatalogLoader.currentAppBuild(),
        session: URLSession = .shared
    ) {
        self.depthEstimator = depthEstimator
        self.downloader = downloader ?? DepthModelDownloader.shared
        self.userDefaults = userDefaults
        self.session = session
        self.deviceOverride = device
        self.appBuild = appBuild

        let bundled = Self.ensuringBundledEntry(catalog ?? ((try? DepthModelCatalogLoader.loadBundled()) ?? Self.fallbackCatalog()))
        self.bundledCatalog = bundled
        let cachedRemote = catalog == nil ? Self.loadCachedRemoteCatalog() : nil
        self.catalog = DepthModelCatalogLoader.merge(bundled: bundled, remote: cachedRemote, appBuild: appBuild)

        if userDefaults.object(forKey: Self.wifiOnlyDefaultsKey) != nil {
            wifiOnlyDownloads = userDefaults.bool(forKey: Self.wifiOnlyDefaultsKey)
        }

        rebuildStates()
        restoreSelection()
        totalInstalledBytes = DepthModelLibrary.totalInstalledBytes()

        self.downloader.delegate = self
        startPathMonitoring()
        reconcileTask = Task { [weak self] in
            await self?.reconcileDownloads()
        }
    }

    deinit {
        reconcileTask?.cancel()
        pathMonitor?.cancel()
    }

    // MARK: - Catalog access

    /// Supported, visible entries in catalog order (the bundled model first).
    var entries: [DepthModelCatalogEntry] {
        catalog.supportedEntries.filter(\.visible)
    }

    func entry(for model: DepthModel) -> DepthModelCatalogEntry? {
        catalog.entry(for: model)
    }

    func state(for model: DepthModel) -> InstallState {
        states[model] ?? (model.isBundled ? .builtIn : .notInstalled)
    }

    func compatibility(for model: DepthModel) -> DepthModelCompatibility.Verdict {
        guard let entry = entry(for: model) else {
            return model.isBundled ? .ok : .blocked(DepthModelCompatibility.requiresAppUpdateMessage)
        }
        return DepthModelCompatibility.evaluate(entry, device: currentDevice, appBuild: appBuild, catalogMinAppBuild: catalog.minAppBuild)
    }

    /// Version string of the installed copy, nil when not installed.
    func installedVersion(for model: DepthModel) -> String? {
        DepthModelLibrary.installedRecord(for: model)?.version
    }

    /// The catalog now lists a newer version than the installed one (re-download to update).
    func isUpdateAvailable(for model: DepthModel) -> Bool {
        guard case .installed = state(for: model), let entry = entry(for: model),
              let installed = installedVersion(for: model) else {
            return false
        }
        return installed != entry.version
    }

    /// True when the device is on an expensive/constrained path (cellular, hotspot,
    /// Low Data Mode) and Wi-Fi-only downloads are on, so the UI should ask first.
    func isCellularConfirmationNeeded(for model: DepthModel) -> Bool {
        guard let entry = entry(for: model), !entry.isBundled else { return false }
        return wifiOnlyDownloads && isExpensivePath
    }

    // MARK: - Download control

    /// Pre-flight (compatibility, free space) then starts every file of the model.
    /// `allowCellular: false` lets the system wait for Wi-Fi rather than refusing.
    /// A retry after a failure continues the download that was started (same
    /// version, staged files kept) even if the catalog has moved on since.
    func download(_ model: DepthModel, allowCellular: Bool) {
        guard let catalogEntry = entry(for: model), !catalogEntry.isBundled else { return }
        switch state(for: model) {
        case .builtIn, .installed, .queued, .downloading, .verifying, .preparing:
            return
        default:
            break
        }
        let entry = activeDownloadEntries[model] ?? catalogEntry

        let verdict = compatibility(for: model)
        if case let .blocked(reason) = verdict {
            states[model] = .blocked(reason)
            return
        }
        if let available = currentDevice.availableBytes {
            let required = DepthModelCompatibility.requiredFreeBytes(for: entry)
            if available < required {
                states[model] = .blocked(DepthModelCompatibility.insufficientFreeSpaceMessage(for: entry))
                return
            }
        }

        cellularAllowance[model] = allowCellular
        if lastProgress[model] == nil {
            lastProgress[model] = (0, 0, entry.totalBytes)
        }
        activeDownloadEntries[model] = entry
        states[model] = .queued
        downloader.startDownload(entry, allowCellular: allowCellular)
    }

    func pause(_ model: DepthModel) {
        guard let entry = activeDownloadEntry(for: model) else { return }
        switch state(for: model) {
        case .queued, .downloading:
            states[model] = .paused(fraction: lastProgress[model]?.fraction ?? 0)
            downloader.pause(entry)
        default:
            break
        }
    }

    /// Continues a paused or failed download. `allowCellular` defaults to what the
    /// original `download(_:allowCellular:)` call allowed.
    func resume(_ model: DepthModel, allowCellular: Bool? = nil) {
        guard let entry = activeDownloadEntry(for: model) else { return }
        switch state(for: model) {
        case .paused, .failed:
            let allowance = allowCellular ?? cellularAllowance[model] ?? false
            cellularAllowance[model] = allowance
            activeDownloadEntries[model] = entry
            states[model] = .queued
            downloader.resume(entry, allowCellular: allowance)
        default:
            break
        }
    }

    /// Stops the download and deletes everything staged for it.
    func cancel(_ model: DepthModel) {
        guard let entry = activeDownloadEntry(for: model) else { return }
        switch state(for: model) {
        case .queued, .downloading, .paused, .verifying, .failed:
            downloader.cancel(entry)
            forgetDownload(of: model)
            states[model] = self.entry(for: model).map { idleState(for: model, entry: $0) } ?? .notInstalled
        default:
            break
        }
    }

    /// The entry an in-flight download was started with, else the catalog's.
    private func activeDownloadEntry(for model: DepthModel) -> DepthModelCatalogEntry? {
        activeDownloadEntries[model] ?? entry(for: model)
    }

    /// Drops every per-download memory once the download is gone (cancelled, or
    /// consumed by an install), so the next start uses the current catalog entry.
    private func forgetDownload(of model: DepthModel) {
        activeDownloadEntries[model] = nil
        lastProgress[model] = nil
        reselectAfterInstall.remove(model)
    }

    // MARK: - Installed models

    /// Deletes an installed model. Throws `modelBusy` while a conversion or install is
    /// running. Selection falls back to the bundled model if needed.
    func remove(_ model: DepthModel) async throws {
        guard !model.isBundled else { return }
        guard activeConversions == 0, !installing.contains(model) else {
            throw StereoPipelineError.modelBusy
        }
        await depthEstimator.unload(model)
        try DepthModelLibrary.removeInstalledModel(model)
        benchmarks[model] = nil
        lastProgress[model] = nil
        states[model] = entry(for: model).map { idleState(for: model, entry: $0) } ?? .notInstalled
        totalInstalledBytes = DepthModelLibrary.totalInstalledBytes()

        if selectedModel == model {
            selectedModel = .bundledDefault
            pendingSelectionResetMessage = Self.selectionResetMessage(from: model)
        }
    }

    /// Cancels every download and removes every installed model that is not busy
    /// (installed models are left alone while a conversion or benchmark runs).
    func removeAllDownloads() async {
        for (model, state) in states {
            switch state {
            case .queued, .downloading, .paused, .verifying, .failed:
                cancel(model)
            case .installed:
                guard activeConversions == 0 else { continue }
                try? await remove(model)
            case .builtIn, .notInstalled, .blocked, .preparing:
                break
            }
        }
    }

    /// Replaces the installed copy with the catalog's current version. The new entry is
    /// pre-flighted BEFORE the working copy is removed (crediting the space it frees), so
    /// a tightened requirement or a free-space shortfall never costs the user a model
    /// that works today; a refusal is thrown for the UI to show.
    func update(_ model: DepthModel, allowCellular: Bool) async throws {
        guard !model.isBundled, let target = entry(for: model) else { return }
        if case .installed = state(for: model) {
            var device = currentDevice
            if let available = device.availableBytes {
                device.availableBytes = available + DepthModelLibrary.installedBytes(for: model)
            }
            let verdict = DepthModelCompatibility.evaluate(
                target,
                device: device,
                appBuild: appBuild,
                catalogMinAppBuild: catalog.minAppBuild
            )
            if case let .blocked(reason) = verdict {
                throw StereoPipelineError.modelUpdateRefused(reason)
            }

            let wasSelected = selectedModel == model
            let pendingMessage = pendingSelectionResetMessage
            try await remove(model)
            if wasSelected {
                // The user asked for this; no "no longer installed" alert needed.
                pendingSelectionResetMessage = pendingMessage
                reselectAfterInstall.insert(model)
            }
        }
        download(model, allowCellular: allowCellular)
    }

    /// Makes `model` the one conversions use; ignored unless it is built in or installed.
    func select(_ model: DepthModel) {
        guard state(for: model).isAvailable else { return }
        selectedModel = model
    }

    func clearPendingSelectionResetMessage() {
        pendingSelectionResetMessage = nil
    }

    /// Flows call this when a conversion could not load `model` (which they took from
    /// `selectedModel`). For a downloaded model that is missing, fails its contract or
    /// cannot be loaded by Core ML, the selection falls back to the bundled model,
    /// `pendingSelectionResetMessage` explains why, and true is returned so the flow
    /// can retry with the bundled model. False for the bundled model, cancellations
    /// and every other error (nothing was changed).
    @discardableResult
    func handleModelLoadFailure(_ model: DepthModel, error: Error) -> Bool {
        guard !model.isBundled, Self.isModelLoadFailure(error) else { return false }
        selectedModel = .bundledDefault
        pendingSelectionResetMessage = String(
            format: NSLocalizedString("%@ could not be loaded. Switched back to %@.", comment: "Depth model load failure alert"),
            model.displayName,
            DepthModel.bundledDefault.displayName
        )
        // A missing model drops out of the index here, so its row shows Download again.
        rebuildStates()
        return true
    }

    /// Loads the model, runs a warm-up and `iterations` timed predictions. Throws
    /// `modelBusy` during a conversion or install, `modelNotInstalled` otherwise
    /// unavailable. The result is kept in `benchmarks`. Counts as a conversion, so
    /// remove and the install warm-up wait for it.
    func benchmark(_ model: DepthModel, iterations: Int = 5) async throws -> DepthBenchmarkResult {
        guard activeConversions == 0, installing.isEmpty else {
            throw StereoPipelineError.modelBusy
        }
        guard state(for: model).isAvailable else {
            throw StereoPipelineError.modelNotInstalled(model.displayName)
        }
        beginConversion()
        defer { endConversion() }
        let result = try await depthEstimator.benchmark(model: model, iterations: iterations)
        if model != selectedModel {
            // Do not keep a model the next conversion will not use resident.
            await depthEstimator.unload(model)
        }
        benchmarks[model] = result

        var index = DepthModelLibrary.loadIndex()
        if var record = index[model.rawValue] {
            record.inferenceSeconds = result.medianInferenceSeconds
            index[model.rawValue] = record
            try? DepthModelLibrary.saveIndex(index)
        }
        return result
    }

    // MARK: - Conversions

    /// Flows call these around a photo/video conversion so remove/benchmark/install
    /// never touch the estimator while it is in use.
    func beginConversion() {
        activeConversions += 1
    }

    func endConversion() {
        activeConversions = max(0, activeConversions - 1)
    }

    // MARK: - Background session

    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        downloader.handleBackgroundSessionEvents(completionHandler: completionHandler)
    }

    // MARK: - Remote catalog

    /// Best-effort refresh of the catalog from `remoteCatalogURL`, at most once a day
    /// (`force` bypasses the throttle). Every failure path is silent. Resting states
    /// are re-derived whatever happens (see `refreshStates()`).
    func refreshCatalog(force: Bool = false) async {
        defer { rebuildStates() }
        let now = Date()
        guard force || shouldFetchCatalog(at: now) else { return }

        var request = URLRequest(
            url: Self.remoteCatalogURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.catalogRequestTimeout
        )
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let remote = try DepthModelCatalogLoader.decode(data)

            // Only a completed round trip arms the throttle, so a flaky network retries next launch.
            userDefaults.set(now, forKey: DepthModelCatalogLoader.remoteCatalogDefaultsKey)
            if let cacheURL = Self.catalogCacheURL(createIfNeeded: true) {
                try? data.write(to: cacheURL, options: .atomic)
            }
            catalog = DepthModelCatalogLoader.merge(bundled: bundledCatalog, remote: remote, appBuild: appBuild)
        } catch {
            // Offline, timed out, or a payload we cannot read: keep what we have.
        }
    }

    /// Re-derives every resting state (`.notInstalled` / `.blocked` / `.installed`)
    /// from the index, the catalog and the device, leaving in-progress downloads and
    /// installs untouched. Call on appear: a "not enough free space" verdict clears
    /// once storage is freed even when the catalog fetch is throttled or offline.
    func refreshStates() {
        rebuildStates()
    }

    /// Merges a fetched remote catalog over the bundled one. Internal so tests can
    /// simulate a catalog change without the network.
    func applyRemoteCatalog(_ remote: DepthModelCatalog) {
        catalog = DepthModelCatalogLoader.merge(bundled: bundledCatalog, remote: remote, appBuild: appBuild)
        rebuildStates()
    }

    private func shouldFetchCatalog(at date: Date) -> Bool {
        guard let last = userDefaults.object(forKey: DepthModelCatalogLoader.remoteCatalogDefaultsKey) as? Date else { return true }
        let elapsed = date.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= Self.catalogFetchInterval
    }

    nonisolated private static func catalogCacheURL(createIfNeeded: Bool) -> URL? {
        (try? DepthModelLibrary.baseDirectory(createIfNeeded: createIfNeeded))?
            .appendingPathComponent(DepthModelLibrary.catalogCacheFileName)
    }

    nonisolated private static func loadCachedRemoteCatalog() -> DepthModelCatalog? {
        guard let url = catalogCacheURL(createIfNeeded: false), let data = try? Data(contentsOf: url) else { return nil }
        return try? DepthModelCatalogLoader.decode(data)
    }

    // MARK: - State derivation

    private var currentDevice: DeviceProfile {
        deviceOverride ?? DeviceProfile.current()
    }

    /// Derives every model's resting state from the index, the catalog and the device;
    /// in-progress states are carried over untouched.
    private func rebuildStates() {
        var index = DepthModelLibrary.loadIndex()
        var indexChanged = false
        var next: [DepthModel: InstallState] = [:]

        for entry in catalog.supportedEntries {
            guard let model = entry.model else { continue }
            if let current = states[model], current.isTransient {
                next[model] = current
                continue
            }
            if model.isBundled || model.isAvailableInBundle {
                next[model] = .builtIn
                continue
            }
            if let record = index[model.rawValue] {
                if record.validatedAt == nil {
                    // Registered but never warmed up: the app died mid-install, so the
                    // files were never proven usable. Remove them rather than offer them.
                    if let directory = try? DepthModelLibrary.versionDirectory(for: model.rawValue, version: record.version) {
                        try? FileManager.default.removeItem(at: directory)
                    }
                } else if DepthModelLibrary.compiledModelURL(for: record) != nil {
                    next[model] = .installed
                    continue
                }
                // Files went missing (e.g. the user cleared storage): forget the record.
                index[model.rawValue] = nil
                indexChanged = true
            }
            next[model] = idleState(for: model, entry: entry)
        }
        next[.bundledDefault] = .builtIn

        if indexChanged {
            try? DepthModelLibrary.saveIndex(index)
            totalInstalledBytes = DepthModelLibrary.totalInstalledBytes()
        }
        states = next
    }

    /// `.blocked` or `.notInstalled` for a model that is not on disk.
    private func idleState(for model: DepthModel, entry: DepthModelCatalogEntry) -> InstallState {
        let verdict = DepthModelCompatibility.evaluate(entry, device: currentDevice, appBuild: appBuild, catalogMinAppBuild: catalog.minAppBuild)
        if case let .blocked(reason) = verdict {
            return .blocked(reason)
        }
        return .notInstalled
    }

    private func restoreSelection() {
        let stored = userDefaults.string(forKey: Self.selectedModelDefaultsKey).flatMap(DepthModel.init(rawValue:))
        if let stored, state(for: stored).isAvailable {
            selectedModel = stored
            return
        }
        selectedModel = .bundledDefault
        userDefaults.set(DepthModel.bundledDefault.rawValue, forKey: Self.selectedModelDefaultsKey)
        if let stored, stored != .bundledDefault {
            pendingSelectionResetMessage = Self.selectionResetMessage(from: stored)
        }
    }

    nonisolated private static func selectionResetMessage(from model: DepthModel) -> String {
        String(
            format: NSLocalizedString("%@ is no longer installed. Switched back to %@.", comment: "Depth model selection reset alert"),
            model.displayName,
            DepthModel.bundledDefault.displayName
        )
    }

    // MARK: - Network path

    private func startPathMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                self?.isExpensivePath = expensive
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    // MARK: - Launch reconciliation

    private func reconcileDownloads() async {
        let snapshots = await downloader.reconcile()
        guard !Task.isCancelled else { return }

        for snapshot in snapshots {
            guard let model = DepthModel(rawValue: snapshot.modelID), let catalogEntry = entry(for: model) else { continue }
            // Address the download by the entry it was started with (its manifest), not
            // the catalog's, which may list a newer version by now.
            let entry = DepthModelDownloader.stagedEntry(in: snapshot.stagingDirectory) ?? catalogEntry
            if case .installed = state(for: model) {
                // Leftover staging next to a finished install: just clean it up.
                downloader.cancel(entry)
                continue
            }
            activeDownloadEntries[model] = entry
            lastProgress[model] = (snapshot.fraction, snapshot.bytesReceived, snapshot.totalBytes)
            switch snapshot.phase {
            case .downloading:
                states[model] = .downloading(fraction: snapshot.fraction, bytesReceived: snapshot.bytesReceived, totalBytes: snapshot.totalBytes)
            case .paused:
                states[model] = .paused(fraction: snapshot.fraction)
            case .verifying:
                states[model] = .verifying
            case .complete:
                Task { await self.install(model, stagingDirectory: snapshot.stagingDirectory) }
            case let .failed(reason):
                states[model] = .failed(reason)
            }
        }
    }

    // MARK: - Install pipeline

    /// Assembles the package from staging, compiles it (`.mlpackage`) or moves it
    /// (`.mlmodelc`) into the library, registers it, then warms it up through the
    /// estimator — which also validates the output contract. Any failure rolls
    /// everything back. Either way the downloader forgets the download at the end:
    /// staging is consumed here, and a retry after a failure must start afresh
    /// rather than wait for files the downloader still believes are verified.
    private func install(_ model: DepthModel, stagingDirectory: URL) async {
        guard !installing.contains(model) else { return }
        installing.insert(model)
        defer { installing.remove(model) }

        states[model] = .preparing
        guard let entry = DepthModelDownloader.stagedEntry(in: stagingDirectory) ?? activeDownloadEntry(for: model) else {
            try? FileManager.default.removeItem(at: stagingDirectory)
            forgetDownload(of: model)
            states[model] = .failed(StereoPipelineError.modelCompileFailed("Catalog entry is missing.").localizedDescription)
            return
        }
        let reselect = reselectAfterInstall.contains(model)
        defer {
            downloader.cancel(entry)
            forgetDownload(of: model)
        }

        var versionDirectory: URL?
        do {
            let placed = try await Self.placeCompiledModel(entry: entry, model: model, stagingDirectory: stagingDirectory)
            versionDirectory = placed.versionDirectory

            let record = DepthModelLibrary.InstalledRecord(
                modelID: model.rawValue,
                version: entry.version,
                compiledRelativePath: "\(model.rawValue)/\(entry.version)/\(placed.compiledName)",
                packageName: entry.packageName,
                installedAt: Date(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                sizeBytes: DepthModelLibrary.size(of: placed.compiledURL),
                compileSeconds: placed.compileSeconds,
                warmUpSeconds: nil,
                inferenceSeconds: nil,
                validatedAt: nil
            )
            // The estimator resolves installed models through the index, so register
            // first — unvalidated, so a crash during the warm-up leaves a record that
            // `rebuildStates` discards instead of a model that was never proven to load.
            var index = DepthModelLibrary.loadIndex()
            index[model.rawValue] = record
            try DepthModelLibrary.saveIndex(index)

            await depthEstimator.unload(model)
            let result = try await warmUp(model)
            if model != selectedModel, !reselect {
                // A ~1 GB model nobody selected should not stay resident.
                await depthEstimator.unload(model)
            }

            // Re-read rather than re-save the pre-warm-up snapshot: the warm-up may
            // have waited a long time and the benchmark writes to the index too.
            index = DepthModelLibrary.loadIndex()
            guard var validated = index[model.rawValue], validated.version == entry.version else {
                throw StereoPipelineError.modelCompileFailed("Install record was lost during warm-up.")
            }
            validated.warmUpSeconds = result.loadSeconds + result.firstInferenceSeconds
            validated.inferenceSeconds = result.medianInferenceSeconds
            validated.validatedAt = Date()
            index[model.rawValue] = validated
            try DepthModelLibrary.saveIndex(index)
            try Self.writeInstalledMetadata(validated, in: placed.versionDirectory)

            try? FileManager.default.removeItem(at: stagingDirectory)
            benchmarks[model] = result
            states[model] = .installed
            totalInstalledBytes = DepthModelLibrary.totalInstalledBytes()
            if reselect {
                select(model)
            }
        } catch {
            await depthEstimator.unload(model)
            var index = DepthModelLibrary.loadIndex()
            index[model.rawValue] = nil
            try? DepthModelLibrary.saveIndex(index)
            if let versionDirectory {
                try? FileManager.default.removeItem(at: versionDirectory)
            }
            try? FileManager.default.removeItem(at: stagingDirectory)
            states[model] = .failed(Self.installFailureReason(error))
            totalInstalledBytes = DepthModelLibrary.totalInstalledBytes()
        }
    }

    /// The warm-up doubles as contract validation. A conversion may be using the
    /// estimator when the download finishes, so wait for it instead of failing.
    private func warmUp(_ model: DepthModel) async throws -> DepthBenchmarkResult {
        var attempts = 0
        while true {
            while activeConversions > 0 {
                try await Task.sleep(for: .seconds(1))
            }
            do {
                return try await depthEstimator.benchmark(model: model, iterations: 1)
            } catch StereoPipelineError.modelBusy where attempts < Self.warmUpBusyRetries {
                attempts += 1
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private struct PlacedModel {
        let versionDirectory: URL
        let compiledURL: URL
        let compiledName: String
        let compileSeconds: Double?
    }

    /// File-system half of the install, off the main actor: gather the staged files
    /// into `<packageName>`, compile if needed, move the result into the version
    /// directory. Returns where it went.
    nonisolated private static func placeCompiledModel(
        entry: DepthModelCatalogEntry,
        model: DepthModel,
        stagingDirectory: URL
    ) async throws -> PlacedModel {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let packageURL = stagingDirectory.appendingPathComponent(entry.packageName, isDirectory: true)
            if fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.removeItem(at: packageURL)
            }
            for file in entry.files {
                let source = stagingDirectory.appendingPathComponent(file.path, isDirectory: false)
                let target = packageURL.appendingPathComponent(file.path, isDirectory: false)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw StereoPipelineError.modelDownloadFailed("Missing file \(file.path).")
                }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: target)
            }

            let compiledName = ((entry.packageName as NSString).deletingPathExtension) + ".mlmodelc"
            let versionDirectory = try DepthModelLibrary.versionDirectory(for: model.rawValue, version: entry.version, createIfNeeded: true)
            let destination = versionDirectory.appendingPathComponent(compiledName, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            var compileSeconds: Double?
            switch entry.format {
            case .mlpackage:
                let clock = ContinuousClock()
                let start = clock.now
                let compiled: URL
                do {
                    compiled = try await MLModel.compileModel(at: packageURL)
                } catch {
                    throw StereoPipelineError.modelCompileFailed(error.localizedDescription)
                }
                let elapsed = (clock.now - start).components
                compileSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                try fileManager.moveItem(at: compiled, to: destination)
            case .mlmodelc:
                try fileManager.moveItem(at: packageURL, to: destination)
            case .bundled:
                throw StereoPipelineError.modelCompileFailed("Bundled models are not installed.")
            }

            return PlacedModel(
                versionDirectory: versionDirectory,
                compiledURL: destination,
                compiledName: compiledName,
                compileSeconds: compileSeconds
            )
        }.value
    }

    nonisolated private static func writeInstalledMetadata(_ record: DepthModelLibrary.InstalledRecord, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent(DepthModelLibrary.installedMetadataFileName), options: .atomic)
    }

    nonisolated private static func installFailureReason(_ error: Error) -> String {
        if let pipelineError = error as? StereoPipelineError {
            return pipelineError.localizedDescription
        }
        return StereoPipelineError.modelCompileFailed(error.localizedDescription).localizedDescription
    }

    /// Errors that mean "this model cannot be used": missing or broken installs and
    /// Core ML refusing to load. Cancellations and everything else are not.
    nonisolated private static func isModelLoadFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let pipelineError = error as? StereoPipelineError {
            switch pipelineError {
            case .modelNotInstalled, .modelContractViolation, .depthOutputDegenerate, .modelNotFound:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return false
        }
        return nsError.domain == MLModelErrorDomain
    }

    // MARK: - Catalog fallbacks

    /// The catalog must always list the bundled model, even if the JSON forgot it.
    nonisolated private static func ensuringBundledEntry(_ catalog: DepthModelCatalog) -> DepthModelCatalog {
        guard catalog.entry(for: .bundledDefault) == nil else { return catalog }
        var patched = catalog
        patched.models.insert(bundledEntry(), at: 0)
        return patched
    }

    nonisolated private static func fallbackCatalog() -> DepthModelCatalog {
        DepthModelCatalog(schemaVersion: DepthModelCatalog.currentSchemaVersion, minAppBuild: 0, models: [bundledEntry()])
    }

    nonisolated private static func bundledEntry() -> DepthModelCatalogEntry {
        DepthModelCatalogEntry(
            id: DepthModel.bundledDefault.rawValue,
            version: "bundled",
            format: .bundled,
            packageName: "DepthAnythingV2SmallF16.mlpackage",
            tier: .small,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/DepthAnything/Depth-Anything-V2/blob/main/LICENSE"),
            sourceURL: URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small"),
            inputWidth: 518,
            inputHeight: 392,
            minimumOS: nil,
            minimumPhysicalMemoryGB: nil,
            recommendedPhysicalMemoryGB: nil,
            estimatedPeakMemoryMB: nil,
            visible: true,
            recommended: true,
            videoRecommended: true,
            files: [],
            provenance: nil
        )
    }
}

// MARK: - Downloader events

extension DepthModelStore: DepthModelDownloaderDelegate {
    func downloader(_ downloader: any DepthModelDownloading, didReceive event: DepthModelDownloadEvent) {
        switch event {
        case let .progress(modelID, fraction, bytesReceived, totalBytes):
            guard let model = DepthModel(rawValue: modelID) else { return }
            lastProgress[model] = (fraction, bytesReceived, totalBytes)
            switch state(for: model) {
            case .queued, .downloading, .verifying:
                if totalBytes > 0, bytesReceived >= totalBytes {
                    states[model] = .verifying
                } else {
                    states[model] = .downloading(fraction: fraction, bytesReceived: bytesReceived, totalBytes: totalBytes)
                }
            default:
                // A late event after pause/cancel must not flip the state back.
                break
            }

        case .fileVerified:
            break

        case let .modelFilesComplete(modelID, version, stagingDirectory):
            guard let model = DepthModel(rawValue: modelID), isCurrentDownload(model, version: version) else { return }
            if case .installed = state(for: model) { return }
            Task { await self.install(model, stagingDirectory: stagingDirectory) }

        case let .failed(modelID, version, error):
            guard let model = DepthModel(rawValue: modelID), isCurrentDownload(model, version: version) else { return }
            if case .installed = state(for: model) { return }
            states[model] = .failed(error.localizedDescription)
        }
    }

    /// Whether an event belongs to the download this store is tracking for `model`;
    /// a report about some other version (a stale download) must not drive its row.
    private func isCurrentDownload(_ model: DepthModel, version: String) -> Bool {
        guard let active = activeDownloadEntries[model] else { return true }
        return active.version == version
    }
}
