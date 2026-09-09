import Foundation

/// On-disk home of user-installed depth models.
///
/// ```
/// Application Support/StereoShift/DepthModels/
///   index.json                              installed records keyed by model id
///   catalog.json                            cached remote catalog (optional)
///   <id>/<version>/<packageName>.mlmodelc   compiled model that DepthEstimator loads
///   <id>/<version>/installed.json           install metadata snapshot
///   Staging/<id>-<version>/…                in-flight downloads, purged when stale
/// ```
///
/// Everything here is re-downloadable, so the directory is excluded from backups.
/// Application Support is never purged by the system (unlike Caches).
enum DepthModelLibrary {
    struct InstalledRecord: Codable, Hashable, Sendable {
        var modelID: String
        var version: String
        /// Path of the compiled `.mlmodelc`, relative to the DepthModels directory.
        var compiledRelativePath: String
        var packageName: String
        var installedAt: Date
        var osVersion: String
        var sizeBytes: Int64
        var compileSeconds: Double?
        var warmUpSeconds: Double?
        var inferenceSeconds: Double?
        /// When the install warm-up proved the model loads and produces usable depth.
        /// The record is written before the warm-up (the estimator resolves the model
        /// through the index), so nil means the app died mid-install: the store treats
        /// such a record as broken and removes it. Optional so older records decode.
        var validatedAt: Date? = nil
    }

    static let directoryName = "DepthModels"
    static let stagingDirectoryName = "Staging"
    static let indexFileName = "index.json"
    static let catalogCacheFileName = "catalog.json"
    static let installedMetadataFileName = "installed.json"
    static let staleStagingAge: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Directories

    static func baseDirectory(createIfNeeded: Bool = true) throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StereoPipelineError.temporaryFileCreationFailed
        }
        let directory = appSupport
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)

        if createIfNeeded, !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(values)
        }
        return directory
    }

    static func stagingDirectory(createIfNeeded: Bool = true) throws -> URL {
        let directory = try baseDirectory(createIfNeeded: createIfNeeded)
            .appendingPathComponent(stagingDirectoryName, isDirectory: true)
        if createIfNeeded, !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func modelDirectory(for modelID: String, createIfNeeded: Bool = false) throws -> URL {
        let directory = try baseDirectory(createIfNeeded: createIfNeeded)
            .appendingPathComponent(modelID, isDirectory: true)
        if createIfNeeded, !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func versionDirectory(for modelID: String, version: String, createIfNeeded: Bool = false) throws -> URL {
        let directory = try modelDirectory(for: modelID, createIfNeeded: createIfNeeded)
            .appendingPathComponent(version, isDirectory: true)
        if createIfNeeded, !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    // MARK: Index

    static func loadIndex() -> [String: InstalledRecord] {
        guard let base = try? baseDirectory(createIfNeeded: false) else { return [:] }
        let url = base.appendingPathComponent(indexFileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: InstalledRecord].self, from: data)) ?? [:]
    }

    static func saveIndex(_ index: [String: InstalledRecord]) throws {
        let base = try baseDirectory(createIfNeeded: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: base.appendingPathComponent(indexFileName), options: .atomic)
    }

    static func installedRecord(for model: DepthModel) -> InstalledRecord? {
        loadIndex()[model.rawValue]
    }

    /// The compiled model to load for a user-installed model, or nil when it is not
    /// installed or its files have gone missing.
    static func installedCompiledModelURL(for model: DepthModel) -> URL? {
        installedRecord(for: model).flatMap(compiledModelURL(for:))
    }

    /// The compiled model a record points at, nil when it is no longer on disk.
    static func compiledModelURL(for record: InstalledRecord) -> URL? {
        guard let base = try? baseDirectory(createIfNeeded: false) else { return nil }
        let url = base.appendingPathComponent(record.compiledRelativePath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func installedBytes(for model: DepthModel) -> Int64 {
        installedRecord(for: model)?.sizeBytes ?? 0
    }

    static func totalInstalledBytes() -> Int64 {
        loadIndex().values.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: Removal / cleanup

    /// Deletes every version of an installed model and drops it from the index.
    static func removeInstalledModel(_ model: DepthModel) throws {
        var index = loadIndex()
        index[model.rawValue] = nil
        try saveIndex(index)

        let directory = try modelDirectory(for: model.rawValue, createIfNeeded: false)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Removes staging leftovers older than `staleStagingAge` (abandoned downloads).
    static func purgeStaleStaging(now: Date = Date()) {
        guard let staging = try? stagingDirectory(createIfNeeded: false),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: staging,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > staleStagingAge {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Total size of a file or directory tree in bytes.
    static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
