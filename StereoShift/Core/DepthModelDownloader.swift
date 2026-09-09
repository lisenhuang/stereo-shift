import CryptoKit
import Foundation

// MARK: - Events and protocol

/// What a downloader reports to its delegate. `modelID` is the catalog entry id
/// (a `DepthModel.rawValue`); the store maps it back to the enum.
enum DepthModelDownloadEvent: Sendable {
    /// Aggregate progress over every file of the model. `totalBytes` uses the server's
    /// `Content-Length` once known and the catalog size until then.
    case progress(modelID: String, fraction: Double, bytesReceived: Int64, totalBytes: Int64)
    /// One file landed in staging and its SHA-256 matched the catalog.
    case fileVerified(modelID: String, path: String)
    /// Every file of the model is staged and verified; the store may compile/install.
    /// `stagingDirectory` is `Staging/<id>-<version>` and contains the files at their
    /// catalog `path` plus a `manifest.json` snapshot of the entry that was downloaded.
    case modelFilesComplete(modelID: String, version: String, stagingDirectory: URL)
    /// A file failed on every mirror (or the staging directory could not be written).
    /// Other files of the model are paused so a retry keeps their progress. `version`
    /// is the one the download was started with, so the store can ignore a stale
    /// report after the catalog moved on.
    case failed(modelID: String, version: String, error: any Error)
}

/// Receives downloader events on the main actor.
@MainActor
protocol DepthModelDownloaderDelegate: AnyObject {
    func downloader(_ downloader: any DepthModelDownloading, didReceive event: DepthModelDownloadEvent)
}

/// State of one model's download rebuilt at launch from the background session and
/// the staging directory (see `DepthModelDownloading.reconcile()`).
struct DepthModelDownloadSnapshot: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// At least one file is still transferring in the background session.
        case downloading
        /// Nothing is transferring; resume data and/or staged files are waiting.
        case paused
        /// All bytes are down; staged files are being hashed.
        case verifying
        /// Every file is verified; the store should install from `stagingDirectory`.
        case complete
        case failed(String)
    }

    var modelID: String
    var version: String
    var phase: Phase
    var bytesReceived: Int64
    var totalBytes: Int64
    var stagingDirectory: URL

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesReceived) / Double(totalBytes)) : 0
    }
}

/// The downloader surface `DepthModelStore` depends on, so tests can inject a fake.
/// All methods are safe to call from the main actor and return immediately; results
/// arrive through `delegate` (also on the main actor).
protocol DepthModelDownloading: AnyObject {
    var delegate: (any DepthModelDownloaderDelegate)? { get set }

    /// Starts (or restarts after a failure) every file of the entry. Files already
    /// staged from an earlier attempt are re-verified instead of re-downloaded.
    func startDownload(_ entry: DepthModelCatalogEntry, allowCellular: Bool)
    /// Cancels the in-flight tasks producing resume data; staged files are kept.
    func pause(_ entry: DepthModelCatalogEntry)
    /// Continues a paused or failed download from resume data / staged files.
    func resume(_ entry: DepthModelCatalogEntry, allowCellular: Bool)
    /// Cancels every task and deletes the staging directory.
    func cancel(_ entry: DepthModelCatalogEntry)
    /// Rebuilds in-flight state from the background session (`getAllTasks`) and the
    /// staging directory after a relaunch. Call once at startup, after setting `delegate`.
    func reconcile() async -> [DepthModelDownloadSnapshot]
    /// Stores the completion handler handed to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void)
}

// MARK: - Pure helpers

/// Mirror-fallback bookkeeping for one catalog file. Mirrors are tried in catalog
/// order (Hugging Face first, GitHub Releases second); only after the last one fails
/// does the file report failure.
struct DepthModelMirrorCursor: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        var host: String
        var reason: String
    }

    let urls: [URL]
    private(set) var index: Int
    /// One entry per mirror that failed since the last `restart()`, in order tried.
    private(set) var failures: [Failure] = []

    init(urls: [URL], index: Int = 0) {
        self.urls = urls
        self.index = max(0, index)
    }

    var currentURL: URL? {
        urls.indices.contains(index) ? urls[index] : nil
    }

    var isExhausted: Bool {
        currentURL == nil
    }

    var lastFailureReason: String? {
        failures.last?.reason
    }

    /// Every mirror's reason, e.g. "huggingface.co: HTTP 503; github.com: HTTP 404",
    /// so a fallback failure does not hide why the first choice was skipped.
    var failureSummary: String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.host): \($0.reason)" }.joined(separator: "; ")
    }

    /// Records a failure of the current mirror and moves on. Returns the URL to retry
    /// with, or nil once every mirror has failed (`failureSummary` keeps the reasons).
    mutating func advance(reason: String) -> URL? {
        let host = currentURL.map { $0.host ?? $0.absoluteString } ?? "mirror \(index + 1)"
        failures.append(Failure(host: host, reason: reason))
        index += 1
        return currentURL
    }

    /// Back to the first mirror (used when stale resume data has to be discarded).
    mutating func restart() {
        index = 0
        failures.removeAll()
    }

    /// Any non-success status is a mirror failure: a 404 body is not a model file.
    static func isFailure(statusCode: Int) -> Bool {
        statusCode >= 400
    }
}

/// `URLSessionTask.taskDescription` payload: `<modelID>|<version>|<path>|<mirrorIndex>`.
/// It survives app termination, so in-flight tasks can be matched back to catalog
/// files on relaunch.
struct DepthModelTaskDescriptor: Equatable, Sendable {
    var modelID: String
    var version: String
    var path: String
    var mirrorIndex: Int

    init(modelID: String, version: String, path: String, mirrorIndex: Int) {
        self.modelID = modelID
        self.version = version
        self.path = path
        self.mirrorIndex = mirrorIndex
    }

    init?(_ encoded: String?) {
        guard let encoded else { return nil }
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let mirrorIndex = Int(parts[3]),
              !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        self.init(modelID: String(parts[0]), version: String(parts[1]), path: String(parts[2]), mirrorIndex: mirrorIndex)
    }

    var encoded: String {
        "\(modelID)|\(version)|\(path)|\(mirrorIndex)"
    }

    /// Staging directory name shared by every file of one model version.
    var stagingKey: String {
        Self.stagingKey(modelID: modelID, version: version)
    }

    static func stagingKey(modelID: String, version: String) -> String {
        "\(modelID)-\(version)"
    }
}

/// Streaming SHA-256 so a 700 MB weight file never has to sit in memory at once.
enum DepthModelFileVerifier {
    static let chunkSize = 1_048_576

    /// Lower-case hex digest of the file at `url`, read in 1 MB chunks.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Catalog paths are joined onto the staging directory, so they must stay inside it.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
}

// MARK: - Background downloader

/// Downloads catalog files with a background `URLSession` so transfers of several
/// hundred megabytes survive the app being suspended or terminated.
///
/// One download task per catalog file; each is verified against its SHA-256 as soon as
/// it lands in `Staging/<id>-<version>/<path>`, and every failure (HTTP >= 400,
/// transport error, checksum mismatch) advances to the next mirror before the file
/// gives up. All state lives on `stateQueue`, which is also the session's delegate
/// queue, so delegate callbacks and API calls never race.
///
/// Use `shared`: a background session identifier may exist only once per process.
final class DepthModelDownloader: NSObject, DepthModelDownloading, @unchecked Sendable {
    static let sessionIdentifier = "com.huanglisen.StereoShift.depthmodels"
    static let manifestFileName = "manifest.json"
    static let resumeDataExtension = "resume"
    /// Minimum interval between two progress events for the same model.
    static let progressReportInterval: TimeInterval = 0.2

    static let shared = DepthModelDownloader()

    // MARK: State

    private final class FileDownload {
        enum Phase {
            case pending
            case downloading
            case verifying
            case verified
            case paused
            case failed
        }

        let file: DepthModelCatalogEntry.File
        var mirrors: DepthModelMirrorCursor
        var phase: Phase = .pending
        var task: URLSessionDownloadTask?
        var taskIdentifier: Int?
        var bytesReceived: Int64 = 0
        var expectedBytes: Int64
        /// Created from resume data; a failure restarts from mirror 0 instead of advancing.
        var isResumed = false
        /// Bumped on every hash pass so a stale result cannot flip the phase.
        var verifyGeneration = 0
        /// Why the file is `.failed`, for the relaunch snapshot.
        var failureReason: String?

        init(file: DepthModelCatalogEntry.File) {
            self.file = file
            self.mirrors = DepthModelMirrorCursor(urls: file.urls)
            self.expectedBytes = file.bytes
        }
    }

    private final class ModelDownload {
        let entry: DepthModelCatalogEntry
        let directory: URL
        var files: [FileDownload]
        var allowCellular: Bool
        var isPaused = false
        var lastProgressReport = Date.distantPast

        init(entry: DepthModelCatalogEntry, directory: URL, allowCellular: Bool) {
            self.entry = entry
            self.directory = directory
            self.allowCellular = allowCellular
            self.files = entry.files.map(FileDownload.init(file:))
        }

        var key: String {
            DepthModelTaskDescriptor.stagingKey(modelID: entry.id, version: entry.version)
        }

        var isComplete: Bool {
            !files.isEmpty && files.allSatisfy { $0.phase == .verified }
        }

        var bytesReceived: Int64 {
            files.reduce(0) { $0 + ($1.phase == .verified ? $1.file.bytes : $1.bytesReceived) }
        }

        var totalBytes: Int64 {
            files.reduce(0) { $0 + ($1.phase == .verified ? $1.file.bytes : $1.expectedBytes) }
        }

        func file(path: String) -> FileDownload? {
            files.first { $0.file.path == path }
        }

        func stagedURL(for file: FileDownload) -> URL {
            directory.appendingPathComponent(file.file.path, isDirectory: false)
        }

        func resumeDataURL(for file: FileDownload) -> URL {
            URL(fileURLWithPath: stagedURL(for: file).path + "." + DepthModelDownloader.resumeDataExtension)
        }
    }

    private let stateQueue = DispatchQueue(label: "com.huanglisen.stereoshift.depthmodels.state")
    private let hashQueue = DispatchQueue(label: "com.huanglisen.stereoshift.depthmodels.hash", qos: .utility)
    private let delegateLock = NSLock()
    private weak var weakDelegate: (any DepthModelDownloaderDelegate)?
    private var downloads: [String: ModelDownload] = [:]
    private var session: URLSession!

    /// Called on the main thread once the background session has delivered all of its
    /// pending events (`urlSessionDidFinishEvents`). Main thread only.
    var backgroundCompletionHandler: (() -> Void)?

    var delegate: (any DepthModelDownloaderDelegate)? {
        get {
            delegateLock.lock()
            defer { delegateLock.unlock() }
            return weakDelegate
        }
        set {
            delegateLock.lock()
            weakDelegate = newValue
            delegateLock.unlock()
        }
    }

    override init() {
        super.init()

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        // Cellular policy is decided per request (URLRequest.allowsExpensiveNetworkAccess).
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.huanglisen.stereoshift.depthmodels.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = stateQueue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: Paths

    static func stagingDirectory(modelID: String, version: String, createIfNeeded: Bool = false) throws -> URL {
        let directory = try DepthModelLibrary.stagingDirectory(createIfNeeded: createIfNeeded)
            .appendingPathComponent(DepthModelTaskDescriptor.stagingKey(modelID: modelID, version: version), isDirectory: true)
        if createIfNeeded, !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func stagingDirectory(for entry: DepthModelCatalogEntry, createIfNeeded: Bool = false) throws -> URL {
        try stagingDirectory(modelID: entry.id, version: entry.version, createIfNeeded: createIfNeeded)
    }

    /// The catalog entry snapshot written when the download started, so an install
    /// uses exactly the files that were downloaded even if the catalog changed since.
    static func stagedEntry(in stagingDirectory: URL) -> DepthModelCatalogEntry? {
        let url = stagingDirectory.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DepthModelCatalogEntry.self, from: data)
    }

    private static func writeManifest(_ entry: DepthModelCatalogEntry, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        try data.write(to: directory.appendingPathComponent(manifestFileName), options: .atomic)
    }

    // MARK: DepthModelDownloading

    func startDownload(_ entry: DepthModelCatalogEntry, allowCellular: Bool) {
        stateQueue.async { [self] in
            let key = DepthModelTaskDescriptor.stagingKey(modelID: entry.id, version: entry.version)
            if let existing = downloads[key] {
                // Retry after a failure, or a duplicate tap: continue what is there.
                existing.allowCellular = allowCellular
                existing.isPaused = false
                if !FileManager.default.fileExists(atPath: existing.directory.path) {
                    // An install consumed the staging directory (or storage was
                    // cleared): recreate it so the files land somewhere again.
                    try? FileManager.default.createDirectory(at: existing.directory, withIntermediateDirectories: true)
                    try? Self.writeManifest(existing.entry, in: existing.directory)
                }
                resumeFiles(of: existing)
                return
            }
            guard entry.format != .bundled, !entry.files.isEmpty else {
                emit(.failed(modelID: entry.id, version: entry.version, error: StereoPipelineError.modelDownloadFailed("Nothing to download.")))
                return
            }
            guard entry.files.allSatisfy({ DepthModelFileVerifier.isSafeRelativePath($0.path) && !$0.urls.isEmpty }) else {
                emit(.failed(modelID: entry.id, version: entry.version, error: StereoPipelineError.modelDownloadFailed("Invalid catalog entry.")))
                return
            }
            do {
                let directory = try Self.stagingDirectory(for: entry, createIfNeeded: true)
                try Self.writeManifest(entry, in: directory)
                let download = ModelDownload(entry: entry, directory: directory, allowCellular: allowCellular)
                downloads[key] = download
                resumeFiles(of: download)
            } catch {
                emit(.failed(modelID: entry.id, version: entry.version, error: StereoPipelineError.modelDownloadFailed(error.localizedDescription)))
            }
        }
    }

    func pause(_ entry: DepthModelCatalogEntry) {
        stateQueue.async { [self] in
            guard let download = downloads[DepthModelTaskDescriptor.stagingKey(modelID: entry.id, version: entry.version)] else { return }
            pauseTransfers(of: download)
        }
    }

    func resume(_ entry: DepthModelCatalogEntry, allowCellular: Bool) {
        stateQueue.async { [self] in
            let key = DepthModelTaskDescriptor.stagingKey(modelID: entry.id, version: entry.version)
            let download: ModelDownload
            if let existing = downloads[key] {
                download = existing
            } else if let loaded = loadDownload(key: key) {
                download = loaded
            } else {
                // Nothing staged any more: behave like a fresh start.
                stateQueue.async { self.startDownload(entry, allowCellular: allowCellular) }
                return
            }
            download.allowCellular = allowCellular
            download.isPaused = false
            resumeFiles(of: download)
        }
    }

    func cancel(_ entry: DepthModelCatalogEntry) {
        stateQueue.async { [self] in
            let key = DepthModelTaskDescriptor.stagingKey(modelID: entry.id, version: entry.version)
            if let download = downloads[key] {
                for file in download.files {
                    file.task?.cancel()
                    file.task = nil
                    file.taskIdentifier = nil
                }
                downloads[key] = nil
            }
            if let directory = try? Self.stagingDirectory(for: entry), FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func reconcile() async -> [DepthModelDownloadSnapshot] {
        await withCheckedContinuation { continuation in
            // getAllTasks calls back on the delegate queue, i.e. on stateQueue.
            session.getAllTasks { [self] tasks in
                // Adopt tasks the session kept alive while the app was gone.
                for task in tasks where task.state == .running || task.state == .suspended {
                    if resolve(task) == nil {
                        task.cancel()
                    }
                }

                // Staging directories without any live task (paused, or all bytes down).
                if let staging = try? DepthModelLibrary.stagingDirectory(createIfNeeded: false),
                   let children = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for child in children where downloads[child.lastPathComponent] == nil {
                        _ = loadDownload(key: child.lastPathComponent)
                    }
                }

                var snapshots: [DepthModelDownloadSnapshot] = []
                for download in downloads.values {
                    let hasTransfer = download.files.contains { $0.phase == .downloading }
                    download.isPaused = !hasTransfer

                    for file in download.files {
                        switch file.phase {
                        case .downloading:
                            if let task = file.task {
                                file.bytesReceived = max(file.bytesReceived, task.countOfBytesReceived)
                                if task.countOfBytesExpectedToReceive > 0 {
                                    file.expectedBytes = task.countOfBytesExpectedToReceive
                                }
                            }
                        case .pending:
                            let staged = download.stagedURL(for: file)
                            if FileManager.default.fileExists(atPath: staged.path) {
                                verify(file, of: download)
                            } else if FileManager.default.fileExists(atPath: download.resumeDataURL(for: file).path) {
                                file.phase = .paused
                            } else if hasTransfer {
                                // Sibling files are live, so this one should be too.
                                startTask(for: file, of: download)
                            }
                        case .verifying, .verified, .paused, .failed:
                            break
                        }
                    }

                    let phase: DepthModelDownloadSnapshot.Phase
                    if let failed = download.files.first(where: { $0.phase == .failed }) {
                        // A replayed failure (`orphanedFile`) landed before this scan
                        // adopted the siblings: pause them as an in-process failure would.
                        pauseTransfers(of: download)
                        phase = .failed(failed.failureReason ?? StereoPipelineError.modelDownloadFailed("Download failed.").localizedDescription)
                    } else if download.files.contains(where: { $0.phase == .downloading }) {
                        phase = .downloading
                    } else if download.files.contains(where: { $0.phase == .verifying }) {
                        phase = .verifying
                    } else if download.isComplete {
                        phase = .complete
                    } else {
                        phase = .paused
                    }
                    snapshots.append(DepthModelDownloadSnapshot(
                        modelID: download.entry.id,
                        version: download.entry.version,
                        phase: phase,
                        bytesReceived: download.bytesReceived,
                        totalBytes: download.totalBytes,
                        stagingDirectory: download.directory
                    ))
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        if Thread.isMainThread {
            backgroundCompletionHandler = completionHandler
        } else {
            DispatchQueue.main.async { self.backgroundCompletionHandler = completionHandler }
        }
    }

    // MARK: Transfer control (stateQueue)

    /// Starts every file that is not already transferring, verifying or verified.
    /// Reports `modelFilesComplete` again when nothing was left to do, so a retry after
    /// an install failure does not sit in "Verifying…" forever.
    private func resumeFiles(of download: ModelDownload) {
        for file in download.files {
            switch file.phase {
            case .downloading, .verifying:
                continue
            case .verified:
                // Verified files can vanish behind our back (an install consumed the
                // staging directory, storage was cleared): fetch them again.
                if FileManager.default.fileExists(atPath: download.stagedURL(for: file).path) {
                    continue
                }
                file.phase = .pending
                file.bytesReceived = 0
                file.expectedBytes = file.file.bytes
                startOrVerify(file, of: download)
            case .failed:
                file.mirrors.restart()
                file.failureReason = nil
                fallthrough
            case .pending, .paused:
                startOrVerify(file, of: download)
            }
        }
        reportProgress(of: download, force: true)
        if download.isComplete {
            emit(.modelFilesComplete(modelID: download.entry.id, version: download.entry.version, stagingDirectory: download.directory))
        }
    }

    /// A staged file is hashed instead of fetched again; a resume blob continues the
    /// interrupted transfer; otherwise the file starts from its current mirror.
    private func startOrVerify(_ file: FileDownload, of download: ModelDownload) {
        let staged = download.stagedURL(for: file)
        if FileManager.default.fileExists(atPath: staged.path) {
            verify(file, of: download)
            return
        }

        let resumeURL = download.resumeDataURL(for: file)
        if let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            let task = session.downloadTask(withResumeData: data)
            attach(task, to: file, of: download, resumed: true)
            task.resume()
            return
        }

        startTask(for: file, of: download)
    }

    private func startTask(for file: FileDownload, of download: ModelDownload) {
        if file.mirrors.isExhausted {
            file.mirrors.restart()
        }
        guard let url = file.mirrors.currentURL else {
            fail(file, of: download, reason: "No download location.")
            return
        }

        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = download.allowCellular
        request.allowsConstrainedNetworkAccess = download.allowCellular
        request.setValue("StereoShift", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        task.countOfBytesClientExpectsToSend = 0
        task.countOfBytesClientExpectsToReceive = file.file.bytes
        attach(task, to: file, of: download, resumed: false)
        task.resume()
    }

    private func attach(_ task: URLSessionDownloadTask, to file: FileDownload, of download: ModelDownload, resumed: Bool) {
        task.taskDescription = DepthModelTaskDescriptor(
            modelID: download.entry.id,
            version: download.entry.version,
            path: file.file.path,
            mirrorIndex: file.mirrors.index
        ).encoded
        file.task = task
        file.taskIdentifier = task.taskIdentifier
        file.phase = .downloading
        file.isResumed = resumed
        if !resumed {
            file.bytesReceived = 0
            file.expectedBytes = file.file.bytes
        }
    }

    /// Cancels the live tasks. The file stays `.downloading` until the session confirms
    /// the cancellation in `didCompleteWithError`, which parks it as `.paused` (and
    /// restarts it at once if a Resume already raced ahead).
    private func pauseTransfers(of download: ModelDownload) {
        download.isPaused = true
        for file in download.files where file.phase == .downloading {
            guard let task = file.task else {
                file.phase = .paused
                continue
            }
            let resumeURL = download.resumeDataURL(for: file)
            task.cancel { data in
                // Not guaranteed to run on any particular queue, nor before or after
                // didCompleteWithError, which also carries the resume data. Skip the
                // write once the file has moved on to a newer task, or a stale blob
                // would shadow the one that task was built from.
                self.stateQueue.async {
                    guard let data, file.task == nil || file.task === task else { return }
                    try? data.write(to: resumeURL, options: .atomic)
                }
            }
        }
    }

    // MARK: Verification

    private func verify(_ file: FileDownload, of download: ModelDownload) {
        file.task = nil
        file.taskIdentifier = nil
        file.phase = .verifying
        file.verifyGeneration += 1
        let generation = file.verifyGeneration
        let url = download.stagedURL(for: file)
        let expected = file.file.sha256.lowercased()
        let key = download.key

        hashQueue.async { [self] in
            let result = Result { try DepthModelFileVerifier.sha256Hex(of: url) }
            stateQueue.async { [self] in
                guard downloads[key] === download, file.phase == .verifying, file.verifyGeneration == generation else {
                    return
                }
                switch result {
                case let .success(digest) where digest == expected:
                    file.phase = .verified
                    file.bytesReceived = file.file.bytes
                    file.expectedBytes = file.file.bytes
                    emit(.fileVerified(modelID: download.entry.id, path: file.file.path))
                    reportProgress(of: download, force: true)
                    if download.isComplete {
                        emit(.modelFilesComplete(modelID: download.entry.id, version: download.entry.version, stagingDirectory: download.directory))
                    }
                case .success:
                    try? FileManager.default.removeItem(at: url)
                    handleFailure(of: file, in: download, reason: StereoPipelineError.modelChecksumMismatch.localizedDescription)
                case let .failure(error):
                    try? FileManager.default.removeItem(at: url)
                    handleFailure(of: file, in: download, reason: error.localizedDescription)
                }
            }
        }
    }

    // MARK: Failure handling

    /// Mirror fallback: stale resume data restarts from mirror 0, anything else moves
    /// to the next mirror; the file fails only when every mirror has failed.
    ///
    /// `orphaned` marks a task the process that started it did not live to see finish
    /// (see `orphanedFile(for:)`). Nothing else is transferring then, and the store may
    /// already show the model as paused, so instead of silently parking the file the
    /// failure is reported with its reason; an explicit retry runs the mirrors again.
    private func handleFailure(of file: FileDownload, in download: ModelDownload, reason: String, orphaned: Bool = false) {
        file.task = nil
        file.taskIdentifier = nil
        file.bytesReceived = 0
        file.expectedBytes = file.file.bytes

        if download.isPaused {
            if orphaned {
                fail(file, of: download, reason: reason)
            } else {
                file.phase = .paused
            }
            return
        }
        if file.isResumed {
            file.isResumed = false
            file.mirrors.restart()
            startTask(for: file, of: download)
            return
        }
        if file.mirrors.advance(reason: reason) != nil {
            startTask(for: file, of: download)
            return
        }
        fail(file, of: download, reason: file.mirrors.failureSummary ?? reason)
    }

    private func fail(_ file: FileDownload, of download: ModelDownload, reason: String) {
        file.phase = .failed
        file.failureReason = reason
        // Keep the other files' progress for a retry.
        pauseTransfers(of: download)
        emit(.failed(modelID: download.entry.id, version: download.entry.version, error: StereoPipelineError.modelDownloadFailed(reason)))
    }

    // MARK: Lookup

    /// Finds the file a task belongs to, adopting tasks the session kept alive across a
    /// relaunch (their model state is rebuilt from the staging manifest). Returns nil
    /// for stale tasks, e.g. one replaced by the next mirror.
    private func resolve(_ task: URLSessionTask) -> (ModelDownload, FileDownload)? {
        guard let descriptor = DepthModelTaskDescriptor(task.taskDescription) else { return nil }
        let key = descriptor.stagingKey
        guard let download = downloads[key] ?? loadDownload(key: key),
              let file = download.file(path: descriptor.path) else {
            return nil
        }

        if file.taskIdentifier == nil, file.phase == .pending || file.phase == .paused,
           let downloadTask = task as? URLSessionDownloadTask,
           task.state == .running || task.state == .suspended {
            file.task = downloadTask
            file.taskIdentifier = task.taskIdentifier
            file.phase = .downloading
            file.mirrors = DepthModelMirrorCursor(urls: file.file.urls, index: descriptor.mirrorIndex)
            download.isPaused = false
        }

        guard file.taskIdentifier == task.taskIdentifier else { return nil }
        return (download, file)
    }

    /// The file a task that already finished belongs to, for tasks `resolve` could not
    /// adopt: one that completed while the app was terminated is no longer running by
    /// the time its delegate callbacks are replayed, so without this its result (a
    /// finished file, or the reason it stopped) would be dropped. Only a file with no
    /// live task of its own qualifies; its mirror cursor is restored from the descriptor.
    private func orphanedFile(for task: URLSessionTask) -> (ModelDownload, FileDownload)? {
        guard let descriptor = DepthModelTaskDescriptor(task.taskDescription),
              let download = downloads[descriptor.stagingKey] ?? loadDownload(key: descriptor.stagingKey),
              let file = download.file(path: descriptor.path),
              file.task == nil, file.taskIdentifier == nil,
              file.phase == .pending || file.phase == .paused else {
            return nil
        }
        file.mirrors = DepthModelMirrorCursor(urls: file.file.urls, index: descriptor.mirrorIndex)
        return (download, file)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Rebuilds a model's download state from `Staging/<key>/manifest.json`.
    private func loadDownload(key: String) -> ModelDownload? {
        guard let staging = try? DepthModelLibrary.stagingDirectory(createIfNeeded: false) else { return nil }
        let directory = staging.appendingPathComponent(key, isDirectory: true)
        guard let entry = Self.stagedEntry(in: directory),
              DepthModelTaskDescriptor.stagingKey(modelID: entry.id, version: entry.version) == key,
              entry.files.allSatisfy({ DepthModelFileVerifier.isSafeRelativePath($0.path) }) else {
            return nil
        }
        let download = ModelDownload(entry: entry, directory: directory, allowCellular: false)
        download.isPaused = true
        downloads[key] = download
        return download
    }

    private static func httpStatus(of task: URLSessionTask) -> Int? {
        (task.response as? HTTPURLResponse)?.statusCode
    }

    // MARK: Reporting

    private func reportProgress(of download: ModelDownload, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(download.lastProgressReport) >= Self.progressReportInterval else { return }
        download.lastProgressReport = now
        let received = download.bytesReceived
        let total = download.totalBytes
        emit(.progress(
            modelID: download.entry.id,
            fraction: total > 0 ? min(1, Double(received) / Double(total)) : 0,
            bytesReceived: received,
            totalBytes: total
        ))
    }

    private func emit(_ event: DepthModelDownloadEvent) {
        guard let delegate else { return }
        Task { @MainActor in
            delegate.downloader(self, didReceive: event)
        }
    }
}

// MARK: - URLSession delegate (called on stateQueue)

extension DepthModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let resolved = resolve(downloadTask)
        let orphaned = resolved == nil
        guard let (download, file) = resolved ?? orphanedFile(for: downloadTask) else { return }

        if let status = Self.httpStatus(of: downloadTask), DepthModelMirrorCursor.isFailure(statusCode: status) {
            // The body is an error page, not a model file.
            handleFailure(of: file, in: download, reason: "HTTP \(status)", orphaned: orphaned)
            return
        }

        // The temporary file is gone once this method returns: move it now.
        let destination = download.stagedURL(for: file)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            handleFailure(of: file, in: download, reason: error.localizedDescription, orphaned: orphaned)
            return
        }

        // A finished file needs no resume blob; one left over would only mislead a retry.
        try? FileManager.default.removeItem(at: download.resumeDataURL(for: file))
        file.bytesReceived = file.file.bytes
        verify(file, of: download)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let (download, file) = resolve(downloadTask), file.phase == .downloading else { return }
        file.bytesReceived = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            file.expectedBytes = totalBytesExpectedToWrite
        }
        reportProgress(of: download, force: false)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let (download, file) = resolve(downloadTask), file.phase == .downloading else { return }
        file.bytesReceived = fileOffset
        if expectedTotalBytes > 0 {
            file.expectedBytes = expectedTotalBytes
        }
        reportProgress(of: download, force: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (download, file) = resolve(task) else {
            // A transport error from a task that outlived the process that started it:
            // report it instead of leaving the model in Paused with the reason lost.
            // Cancellations are ours (pause, cancel, or reconcile discarding a stale
            // task) and successes were handled in didFinishDownloadingTo.
            if let error, !Self.isCancellation(error), let (download, file) = orphanedFile(for: task) {
                handleFailure(of: file, in: download, reason: error.localizedDescription, orphaned: true)
            }
            return
        }
        guard let error else {
            // Success and HTTP errors were handled in didFinishDownloadingTo.
            return
        }

        if Self.isCancellation(error) {
            // Our own pause. Keep the resume data and park the file whether or not the
            // download is still paused: a Resume that raced ahead of this callback
            // skipped the file (it was still `.downloading` with a dead task), so
            // restart it from that data right away instead of leaving it stuck.
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: download.resumeDataURL(for: file), options: .atomic)
            }
            file.task = nil
            file.taskIdentifier = nil
            file.phase = .paused
            if !download.isPaused {
                startOrVerify(file, of: download)
            }
            return
        }

        handleFailure(of: file, in: download, reason: error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
