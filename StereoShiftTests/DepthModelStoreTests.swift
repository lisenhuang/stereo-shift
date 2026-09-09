import CryptoKit
import Foundation
import Testing
@testable import StereoShift

/// Records what the store asks for and lets tests push downloader events back in.
private final class FakeDepthModelDownloader: DepthModelDownloading {
    weak var delegate: (any DepthModelDownloaderDelegate)?
    var started: [(entry: DepthModelCatalogEntry, allowCellular: Bool)] = []
    var paused: [DepthModelCatalogEntry] = []
    var resumed: [DepthModelCatalogEntry] = []
    var cancelled: [DepthModelCatalogEntry] = []
    var snapshots: [DepthModelDownloadSnapshot] = []
    var backgroundHandlerCalls = 0

    func startDownload(_ entry: DepthModelCatalogEntry, allowCellular: Bool) {
        started.append((entry, allowCellular))
    }

    func pause(_ entry: DepthModelCatalogEntry) {
        paused.append(entry)
    }

    func resume(_ entry: DepthModelCatalogEntry, allowCellular: Bool) {
        resumed.append(entry)
    }

    func cancel(_ entry: DepthModelCatalogEntry) {
        cancelled.append(entry)
    }

    func reconcile() async -> [DepthModelDownloadSnapshot] {
        snapshots
    }

    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        backgroundHandlerCalls += 1
        completionHandler()
    }

    @MainActor
    func emit(_ event: DepthModelDownloadEvent) {
        delegate?.downloader(self, didReceive: event)
    }
}

/// Store behaviour with a fake downloader, an isolated `UserDefaults` suite and an
/// injected device, so nothing touches the network. `DepthModelLibrary` is the real
/// on-disk index of the test host, which is empty for the models used here; tests
/// that plant a record clean it up again.
@MainActor
@Suite(.serialized)
struct DepthModelStoreTests {
    nonisolated private static let bundledID = DepthModel.bundledDefault.rawValue
    nonisolated private static let smallID = DepthModel.depthAnythingV3SmallF16.rawValue

    // MARK: Fixtures

    nonisolated private static func entry(
        id: String,
        format: DepthModelCatalogEntry.ArtifactFormat,
        version: String = "1",
        minimumMemoryGB: Double? = nil,
        visible: Bool = true,
        bytes: Int64 = 1_000
    ) -> DepthModelCatalogEntry {
        let files: [DepthModelCatalogEntry.File] = format == .bundled ? [] : [
            DepthModelCatalogEntry.File(
                path: "Manifest.json",
                urls: [URL(string: "https://example.com/a/Manifest.json")!, URL(string: "https://example.com/b/Manifest.json")!],
                bytes: bytes / 2,
                sha256: String(repeating: "0", count: 64)
            ),
            DepthModelCatalogEntry.File(
                path: "Data/com.apple.CoreML/weights/weight.bin",
                urls: [URL(string: "https://example.com/a/weight.bin")!],
                bytes: bytes - bytes / 2,
                sha256: String(repeating: "1", count: 64)
            )
        ]
        return DepthModelCatalogEntry(
            id: id,
            version: version,
            format: format,
            packageName: "\(id).mlpackage",
            tier: .small,
            license: "Apache-2.0",
            licenseURL: nil,
            sourceURL: nil,
            inputWidth: 504,
            inputHeight: 504,
            minimumOS: nil,
            minimumPhysicalMemoryGB: minimumMemoryGB,
            recommendedPhysicalMemoryGB: nil,
            estimatedPeakMemoryMB: nil,
            visible: visible,
            recommended: false,
            videoRecommended: false,
            files: files,
            provenance: nil
        )
    }

    nonisolated private static func catalog(minimumMemoryGB: Double? = 3, smallVersion: String = "1") -> DepthModelCatalog {
        DepthModelCatalog(
            schemaVersion: DepthModelCatalog.currentSchemaVersion,
            minAppBuild: 1,
            models: [
                entry(id: bundledID, format: .bundled),
                entry(id: smallID, format: .mlpackage, version: smallVersion, minimumMemoryGB: minimumMemoryGB),
                entry(id: "SomeFutureModel", format: .mlpackage),
                entry(id: DepthModel.depthAnythingV3BaseF16.rawValue, format: .mlpackage, visible: false)
            ]
        )
    }

    nonisolated private static func device(memoryGB: Double, availableBytes: Int64? = 50_000_000_000) -> DeviceProfile {
        DeviceProfile(
            physicalMemoryBytes: UInt64(memoryGB * 1_073_741_824),
            osVersion: OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0),
            isMac: false,
            availableBytes: availableBytes
        )
    }

    nonisolated private static func makeDefaults() -> UserDefaults {
        let suite = "DepthModelStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeStore(
        defaults: UserDefaults = makeDefaults(),
        downloader: FakeDepthModelDownloader = FakeDepthModelDownloader(),
        device: DeviceProfile = device(memoryGB: 6),
        catalog: DepthModelCatalog = catalog()
    ) -> DepthModelStore {
        DepthModelStore(
            depthEstimator: DepthEstimator(),
            catalog: catalog,
            downloader: downloader,
            userDefaults: defaults,
            device: device,
            appBuild: 25
        )
    }

    /// Plants an index record for the small model with an (empty) compiled directory,
    /// as an install would leave behind. `validated: false` mimics a crash during the
    /// warm-up. Undo with `removePlantedInstall()`.
    nonisolated private static func plantInstall(validated: Bool, version: String = "1") throws {
        let model = DepthModel.depthAnythingV3SmallF16
        let compiledName = "\(model.rawValue).mlmodelc"
        let directory = try DepthModelLibrary.versionDirectory(for: model.rawValue, version: version, createIfNeeded: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(compiledName, isDirectory: true), withIntermediateDirectories: true)

        var index = DepthModelLibrary.loadIndex()
        index[model.rawValue] = DepthModelLibrary.InstalledRecord(
            modelID: model.rawValue,
            version: version,
            compiledRelativePath: "\(model.rawValue)/\(version)/\(compiledName)",
            packageName: "\(model.rawValue).mlpackage",
            installedAt: Date(),
            osVersion: "test",
            sizeBytes: 0,
            compileSeconds: nil,
            warmUpSeconds: nil,
            inferenceSeconds: nil,
            validatedAt: validated ? Date() : nil
        )
        try DepthModelLibrary.saveIndex(index)
    }

    nonisolated private static func removePlantedInstall() {
        try? DepthModelLibrary.removeInstalledModel(.depthAnythingV3SmallF16)
    }

    nonisolated private static func plantedVersionDirectoryExists(version: String = "1") -> Bool {
        guard let directory = try? DepthModelLibrary.versionDirectory(for: Self.smallID, version: version) else { return false }
        return FileManager.default.fileExists(atPath: directory.path)
    }

    /// Polls `condition` until it holds or `timeout` passes; returns whether it held.
    private static func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: Initial state

    @Test func initialStatesFollowCatalogAndDevice() {
        let store = Self.makeStore(device: Self.device(memoryGB: 6))
        #expect(store.state(for: .bundledDefault) == .builtIn)
        #expect(store.state(for: .depthAnythingV3SmallF16) == .notInstalled)
        #expect(store.selectedModel == .bundledDefault)
        #expect(store.pendingSelectionResetMessage == nil)
        // Unknown ids and hidden entries never show up; the bundled model comes first.
        #expect(store.entries.map(\.id) == [Self.bundledID, Self.smallID])
        #expect(store.entry(for: .depthAnythingV3BaseF16) != nil)
    }

    @Test func lowMemoryDeviceIsBlocked() {
        let store = Self.makeStore(device: Self.device(memoryGB: 2))
        guard case let .blocked(reason) = store.state(for: .depthAnythingV3SmallF16) else {
            Issue.record("expected blocked, got \(store.state(for: .depthAnythingV3SmallF16))")
            return
        }
        #expect(reason.contains("3 GB"))
        #expect(store.compatibility(for: .depthAnythingV3SmallF16).isBlocked)
        #expect(store.compatibility(for: .bundledDefault) == .ok)
    }

    @Test func wifiOnlyDefaultsToTrueAndPersists() {
        let defaults = Self.makeDefaults()
        let store = Self.makeStore(defaults: defaults)
        #expect(store.wifiOnlyDownloads)

        store.wifiOnlyDownloads = false
        #expect(defaults.bool(forKey: DepthModelStore.wifiOnlyDefaultsKey) == false)
        #expect(!Self.makeStore(defaults: defaults).wifiOnlyDownloads)
    }

    @Test func refreshStatesRederivesRestingStatesOnly() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader, device: Self.device(memoryGB: 6, availableBytes: 10))
        guard case let .blocked(reason) = store.state(for: .depthAnythingV3SmallF16),
              let entry = store.entry(for: .depthAnythingV3SmallF16) else {
            Issue.record("expected the free-space block")
            return
        }
        #expect(DepthModelCompatibility.isInsufficientFreeSpaceMessage(reason, for: entry))

        // Space freed (no catalog fetch involved): the block clears on the next check.
        store.deviceOverride = Self.device(memoryGB: 6)
        store.refreshStates()
        #expect(store.state(for: .depthAnythingV3SmallF16) == .notInstalled)

        // In-progress states survive a refresh untouched.
        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        store.deviceOverride = Self.device(memoryGB: 6, availableBytes: 10)
        store.refreshStates()
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)
    }

    // MARK: Installed records

    @Test func unvalidatedInstallRecordIsDiscarded() throws {
        try Self.plantInstall(validated: false)
        defer { Self.removePlantedInstall() }

        let store = Self.makeStore()
        #expect(store.state(for: .depthAnythingV3SmallF16) == .notInstalled)
        #expect(DepthModelLibrary.installedRecord(for: .depthAnythingV3SmallF16) == nil)
        #expect(!Self.plantedVersionDirectoryExists())
        #expect(store.installedVersion(for: .depthAnythingV3SmallF16) == nil)
    }

    @Test func validatedInstallRecordIsInstalled() throws {
        try Self.plantInstall(validated: true)
        defer { Self.removePlantedInstall() }

        let store = Self.makeStore(catalog: Self.catalog(smallVersion: "2"))
        #expect(store.state(for: .depthAnythingV3SmallF16) == .installed)
        #expect(store.installedVersion(for: .depthAnythingV3SmallF16) == "1")
        #expect(store.isUpdateAvailable(for: .depthAnythingV3SmallF16))

        // Old records without `validatedAt` still decode (and count as unvalidated).
        let legacy = Data("""
        {"modelID":"\(Self.smallID)","version":"1","compiledRelativePath":"x","packageName":"p","installedAt":"2026-01-01T00:00:00Z","osVersion":"o","sizeBytes":1}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DepthModelLibrary.InstalledRecord.self, from: legacy)
        #expect(record.validatedAt == nil)
    }

    // MARK: Selection

    @Test func selectionPersistsAndRefusesUnavailableModels() {
        let defaults = Self.makeDefaults()
        let store = Self.makeStore(defaults: defaults)

        store.select(.depthAnythingV3SmallF16)
        #expect(store.selectedModel == .bundledDefault)

        store.select(.bundledDefault)
        #expect(defaults.string(forKey: DepthModelStore.selectedModelDefaultsKey) == Self.bundledID)
    }

    @Test func storedSelectionOfMissingModelResetsToBundled() {
        let defaults = Self.makeDefaults()
        defaults.set(Self.smallID, forKey: DepthModelStore.selectedModelDefaultsKey)

        let store = Self.makeStore(defaults: defaults)
        #expect(store.selectedModel == .bundledDefault)
        #expect(store.pendingSelectionResetMessage?.contains(DepthModel.depthAnythingV3SmallF16.displayName) == true)
        #expect(defaults.string(forKey: DepthModelStore.selectedModelDefaultsKey) == Self.bundledID)

        store.clearPendingSelectionResetMessage()
        #expect(store.pendingSelectionResetMessage == nil)
    }

    @Test func loadFailureOfSelectedModelFallsBackToBundled() throws {
        try Self.plantInstall(validated: true)
        defer { Self.removePlantedInstall() }
        let defaults = Self.makeDefaults()
        let store = Self.makeStore(defaults: defaults)
        store.select(.depthAnythingV3SmallF16)
        #expect(store.selectedModel == .depthAnythingV3SmallF16)

        // Not a load failure: nothing changes.
        #expect(!store.handleModelLoadFailure(.depthAnythingV3SmallF16, error: StereoPipelineError.modelDownloadFailed("x")))
        #expect(!store.handleModelLoadFailure(.depthAnythingV3SmallF16, error: CancellationError()))
        #expect(store.selectedModel == .depthAnythingV3SmallF16)
        #expect(store.pendingSelectionResetMessage == nil)

        #expect(store.handleModelLoadFailure(.depthAnythingV3SmallF16, error: StereoPipelineError.modelContractViolation("shape")))
        #expect(store.selectedModel == .bundledDefault)
        #expect(defaults.string(forKey: DepthModelStore.selectedModelDefaultsKey) == Self.bundledID)
        #expect(store.pendingSelectionResetMessage?.contains(DepthModel.depthAnythingV3SmallF16.displayName) == true)
        #expect(store.pendingSelectionResetMessage?.contains("could not be loaded") == true)

        // The bundled model never triggers a fallback, whatever the error.
        #expect(!store.handleModelLoadFailure(.bundledDefault, error: StereoPipelineError.modelNotFound))
    }

    // MARK: Downloads

    @Test func downloadRefusesBlockedModel() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader, device: Self.device(memoryGB: 2))

        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started.isEmpty)
        if case .blocked = store.state(for: .depthAnythingV3SmallF16) {} else {
            Issue.record("expected blocked")
        }
    }

    @Test func downloadRefusesWhenStorageIsShort() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader, device: Self.device(memoryGB: 6, availableBytes: 10))

        store.download(.depthAnythingV3SmallF16, allowCellular: false)
        #expect(downloader.started.isEmpty)
        #expect(!store.state(for: .depthAnythingV3SmallF16).isBusy)
    }

    @Test func downloadStartsAndProgressUpdatesState() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader)

        store.download(.depthAnythingV3SmallF16, allowCellular: false)
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)
        #expect(downloader.started.count == 1)
        #expect(downloader.started[0].entry.id == Self.smallID)
        #expect(downloader.started[0].allowCellular == false)

        // A second tap while queued is a no-op.
        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started.count == 1)

        downloader.emit(.progress(modelID: Self.smallID, fraction: 0.5, bytesReceived: 500, totalBytes: 1_000))
        #expect(store.state(for: .depthAnythingV3SmallF16) == .downloading(fraction: 0.5, bytesReceived: 500, totalBytes: 1_000))

        downloader.emit(.progress(modelID: Self.smallID, fraction: 1, bytesReceived: 1_000, totalBytes: 1_000))
        #expect(store.state(for: .depthAnythingV3SmallF16) == .verifying)

        // Events for models the catalog does not know are ignored.
        downloader.emit(.progress(modelID: "SomeFutureModel", fraction: 0.2, bytesReceived: 1, totalBytes: 5))
        #expect(store.state(for: .depthAnythingV3SmallF16) == .verifying)
    }

    @Test func failureEventSetsFailedAndRetryRestarts() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader)

        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        // A report about some other version of the model is not this download's.
        downloader.emit(.failed(modelID: Self.smallID, version: "9", error: StereoPipelineError.modelDownloadFailed("stale")))
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)

        downloader.emit(.failed(modelID: Self.smallID, version: "1", error: StereoPipelineError.modelDownloadFailed("HTTP 503")))
        guard case let .failed(reason) = store.state(for: .depthAnythingV3SmallF16) else {
            Issue.record("expected failed")
            return
        }
        #expect(reason.contains("HTTP 503"))

        // Retry goes through the downloader again (it keeps staged files).
        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started.count == 2)
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)
    }

    @Test func pauseResumeAndCancel() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader)

        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        downloader.emit(.progress(modelID: Self.smallID, fraction: 0.25, bytesReceived: 250, totalBytes: 1_000))

        store.pause(.depthAnythingV3SmallF16)
        #expect(downloader.paused.map(\.id) == [Self.smallID])
        #expect(store.state(for: .depthAnythingV3SmallF16) == .paused(fraction: 0.25))

        // A progress event that was already in flight must not un-pause the row.
        downloader.emit(.progress(modelID: Self.smallID, fraction: 0.3, bytesReceived: 300, totalBytes: 1_000))
        #expect(store.state(for: .depthAnythingV3SmallF16) == .paused(fraction: 0.25))

        store.resume(.depthAnythingV3SmallF16)
        #expect(downloader.resumed.map(\.id) == [Self.smallID])
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)

        store.cancel(.depthAnythingV3SmallF16)
        #expect(downloader.cancelled.map(\.id) == [Self.smallID])
        #expect(store.state(for: .depthAnythingV3SmallF16) == .notInstalled)
    }

    @Test func catalogBumpMidDownloadKeepsAddressingTheStartedVersion() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader)

        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started[0].entry.version == "1")

        store.applyRemoteCatalog(Self.catalog(smallVersion: "2"))
        #expect(store.entry(for: .depthAnythingV3SmallF16)?.version == "2")
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)

        // Pause/resume/cancel and events still belong to the version being fetched.
        store.pause(.depthAnythingV3SmallF16)
        #expect(downloader.paused.map(\.version) == ["1"])
        store.resume(.depthAnythingV3SmallF16)
        #expect(downloader.resumed.map(\.version) == ["1"])
        downloader.emit(.failed(modelID: Self.smallID, version: "1", error: StereoPipelineError.modelDownloadFailed("HTTP 503")))
        if case .failed = store.state(for: .depthAnythingV3SmallF16) {} else {
            Issue.record("expected failed")
        }
        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started.map(\.entry.version) == ["1", "1"])
        store.cancel(.depthAnythingV3SmallF16)
        #expect(downloader.cancelled.map(\.version) == ["1"])

        // Once cancelled, a fresh start picks up the current catalog entry.
        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started.map(\.entry.version) == ["1", "1", "2"])
    }

    @Test func installFailureForgetsTheDownloadSoRetryStartsAfresh() async throws {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthModelStoreTests-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        // Nothing staged: the install cannot assemble the package and rolls back.
        downloader.emit(.modelFilesComplete(modelID: Self.smallID, version: "1", stagingDirectory: staging))
        let failed = await Self.waitUntil {
            if case .failed = store.state(for: .depthAnythingV3SmallF16) { return true }
            return false
        }
        #expect(failed)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(DepthModelLibrary.installedRecord(for: .depthAnythingV3SmallF16) == nil)
        // The downloader must drop its record, or a retry would wait forever for
        // files it still considers verified.
        #expect(downloader.cancelled.map(\.id) == [Self.smallID])

        store.download(.depthAnythingV3SmallF16, allowCellular: true)
        #expect(downloader.started.count == 2)
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)
    }

    @Test func updateRemovesTheInstalledCopyThenDownloads() async throws {
        try Self.plantInstall(validated: true)
        defer { Self.removePlantedInstall() }
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader, catalog: Self.catalog(smallVersion: "2"))
        store.select(.depthAnythingV3SmallF16)

        // Refused while a conversion runs: the installed copy stays put and the
        // refusal is thrown so Settings can show it.
        store.beginConversion()
        await #expect(throws: StereoPipelineError.self) {
            try await store.update(.depthAnythingV3SmallF16, allowCellular: false)
        }
        #expect(store.state(for: .depthAnythingV3SmallF16) == .installed)
        #expect(downloader.started.isEmpty)
        store.endConversion()

        try await store.update(.depthAnythingV3SmallF16, allowCellular: false)
        #expect(DepthModelLibrary.installedRecord(for: .depthAnythingV3SmallF16) == nil)
        #expect(store.state(for: .depthAnythingV3SmallF16) == .queued)
        #expect(downloader.started.map(\.entry.version) == ["2"])
        #expect(downloader.started[0].allowCellular == false)
        // The user asked for this, so no "no longer installed" alert; conversions use
        // the bundled model until the new copy lands.
        #expect(store.selectedModel == .bundledDefault)
        #expect(store.pendingSelectionResetMessage == nil)
    }

    @Test func backgroundEventsForwardToDownloader() {
        let downloader = FakeDepthModelDownloader()
        let store = Self.makeStore(downloader: downloader)
        var called = false
        store.handleBackgroundSessionEvents { called = true }
        #expect(called)
        #expect(downloader.backgroundHandlerCalls == 1)
    }

    @Test func conversionCounterGatesRemoveAndBenchmark() async {
        let store = Self.makeStore()
        store.beginConversion()
        store.beginConversion()
        store.endConversion()
        #expect(store.activeConversions == 1)

        await #expect(throws: StereoPipelineError.self) {
            try await store.benchmark(.bundledDefault, iterations: 1)
        }
        store.endConversion()
        store.endConversion()
        #expect(store.activeConversions == 0)

        await #expect(throws: StereoPipelineError.self) {
            try await store.benchmark(.depthAnythingV3SmallF16, iterations: 1)
        }
        #expect(store.activeConversions == 0)
    }

    @Test func benchmarkCountsAsAConversion() async {
        let store = Self.makeStore()
        let benchmark = Task { try await store.benchmark(.bundledDefault, iterations: 1) }
        let started = await Self.waitUntil { store.activeConversions == 1 }
        #expect(started)

        // Remove is refused for as long as the benchmark holds the estimator.
        await #expect(throws: StereoPipelineError.self) {
            try await store.remove(.depthAnythingV3SmallF16)
        }

        // Whether or not the test host can load the bundled model, the counter drops.
        _ = try? await benchmark.value
        #expect(store.activeConversions == 0)
    }
}

// MARK: - Pure helpers

struct DepthModelDownloaderHelperTests {
    @Test func sha256StreamsWholeFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthModelDownloaderHelperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Known vector.
        let small = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: small)
        #expect(try DepthModelFileVerifier.sha256Hex(of: small) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // Larger than one chunk, not chunk-aligned, compared against the one-shot hash.
        var bytes = [UInt8](repeating: 0, count: DepthModelFileVerifier.chunkSize * 2 + 12_345)
        var seed: UInt32 = 0x9E37_79B9
        for index in bytes.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let data = Data(bytes)
        let large = directory.appendingPathComponent("large.bin")
        try data.write(to: large)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try DepthModelFileVerifier.sha256Hex(of: large) == expected)

        // Empty file has the well-known empty digest.
        let empty = directory.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        #expect(try DepthModelFileVerifier.sha256Hex(of: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func mirrorCursorAdvancesThenExhausts() {
        let first = URL(string: "https://huggingface.co/x/weight.bin")!
        let second = URL(string: "https://github.com/x/weight.bin")!
        var cursor = DepthModelMirrorCursor(urls: [first, second])

        #expect(cursor.currentURL == first)
        #expect(!cursor.isExhausted)
        #expect(cursor.failureSummary == nil)

        #expect(cursor.advance(reason: "HTTP 503") == second)
        #expect(cursor.index == 1)
        #expect(cursor.lastFailureReason == "HTTP 503")

        #expect(cursor.advance(reason: "HTTP 404") == nil)
        #expect(cursor.isExhausted)
        #expect(cursor.lastFailureReason == "HTTP 404")
        // Every mirror's reason survives, so the fallback's 404 does not hide the 503.
        #expect(cursor.failureSummary == "huggingface.co: HTTP 503; github.com: HTTP 404")

        cursor.restart()
        #expect(cursor.currentURL == first)
        #expect(cursor.lastFailureReason == nil)
        #expect(cursor.failureSummary == nil)

        #expect(DepthModelMirrorCursor(urls: []).isExhausted)
        #expect(DepthModelMirrorCursor.isFailure(statusCode: 404))
        #expect(DepthModelMirrorCursor.isFailure(statusCode: 500))
        #expect(!DepthModelMirrorCursor.isFailure(statusCode: 200))
        #expect(!DepthModelMirrorCursor.isFailure(statusCode: 302))
    }

    @Test func taskDescriptorRoundTrips() {
        let descriptor = DepthModelTaskDescriptor(
            modelID: "DepthAnythingV3SmallF16",
            version: "2026.02",
            path: "Data/com.apple.CoreML/weights/weight.bin",
            mirrorIndex: 1
        )
        #expect(descriptor.encoded == "DepthAnythingV3SmallF16|2026.02|Data/com.apple.CoreML/weights/weight.bin|1")
        #expect(DepthModelTaskDescriptor(descriptor.encoded) == descriptor)
        #expect(descriptor.stagingKey == "DepthAnythingV3SmallF16-2026.02")

        #expect(DepthModelTaskDescriptor(nil) == nil)
        #expect(DepthModelTaskDescriptor("garbage") == nil)
        #expect(DepthModelTaskDescriptor("a|b|c|notanumber") == nil)
        #expect(DepthModelTaskDescriptor("|b|c|0") == nil)
    }

    @Test func relativePathsStayInsideStaging() {
        #expect(DepthModelFileVerifier.isSafeRelativePath("Manifest.json"))
        #expect(DepthModelFileVerifier.isSafeRelativePath("Data/com.apple.CoreML/weights/weight.bin"))
        #expect(!DepthModelFileVerifier.isSafeRelativePath(""))
        #expect(!DepthModelFileVerifier.isSafeRelativePath("/etc/passwd"))
        #expect(!DepthModelFileVerifier.isSafeRelativePath("../escape.bin"))
        #expect(!DepthModelFileVerifier.isSafeRelativePath("Data//weight.bin"))
    }
}
