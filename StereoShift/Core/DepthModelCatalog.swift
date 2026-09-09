import Foundation

/// The list of depth models the app can offer for download, decoded from the bundled
/// `depth-models.json` and optionally refreshed from a remote copy.
///
/// The catalog is deliberately NOT trusted for anything that could break rendering:
/// output semantics, tuning and compute units live on `DepthModel` (compiled in). The
/// catalog only carries download locations, sizes, hashes, device requirements and
/// presentation flags, and an entry is usable only when its `id` matches a compiled-in
/// `DepthModel` case and its license is on the allow-list.
struct DepthModelCatalog: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Entries are ignored when the running app is older than this build number.
    var minAppBuild: Int
    var models: [DepthModelCatalogEntry]

    /// Entries whose id maps to a compiled-in model with an allowed license.
    var supportedEntries: [DepthModelCatalogEntry] {
        models.filter { $0.model != nil && $0.isLicenseAllowed }
    }

    func entry(for model: DepthModel) -> DepthModelCatalogEntry? {
        models.first { $0.id == model.rawValue }
    }
}

struct DepthModelCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    enum ArtifactFormat: String, Codable, Hashable, Sendable {
        /// Shipped inside the app bundle; nothing to download.
        case bundled
        /// `.mlpackage` tree downloaded file by file, compiled on device.
        case mlpackage
        /// Pre-compiled `.mlmodelc` tree downloaded file by file, loaded as-is.
        case mlmodelc
    }

    enum Tier: String, Codable, Hashable, Sendable {
        case small
        case base
        case large
    }

    struct File: Codable, Hashable, Sendable {
        /// Path inside the package directory, e.g. `Data/com.apple.CoreML/weights/weight.bin`.
        var path: String
        /// Mirrors in priority order (Hugging Face first, GitHub Releases second).
        var urls: [URL]
        var bytes: Int64
        /// Lower-case hex SHA-256 of the file contents.
        var sha256: String
    }

    struct Provenance: Codable, Hashable, Sendable {
        var sourceRepo: String?
        var sourceRevision: String?
        var converter: String?
    }

    /// Must equal a `DepthModel.rawValue`; unknown ids are shown as "Requires app update".
    var id: String
    /// Bumping the version forces a re-download; also the on-disk directory name.
    var version: String
    var format: ArtifactFormat
    /// Directory name of the package on disk, e.g. `DepthAnythingV3_small_504.mlpackage`.
    var packageName: String
    var tier: Tier
    /// SPDX identifier. Only entries on `DepthModelCatalogEntry.allowedLicenses` decode as usable.
    var license: String
    var licenseURL: URL?
    var sourceURL: URL?
    var inputWidth: Int
    var inputHeight: Int
    var minimumOS: String?
    var minimumPhysicalMemoryGB: Double?
    var recommendedPhysicalMemoryGB: Double?
    /// Measured on device once known; nil until then.
    var estimatedPeakMemoryMB: Int?
    var visible: Bool
    var recommended: Bool
    var videoRecommended: Bool
    var files: [File]
    var provenance: Provenance?

    /// Licenses that may be redistributed inside a commercial app. CC-BY-NC models
    /// (Depth Anything 3 Large/Giant/Nested, Depth Anything V2 Base/Large) and
    /// research-only weights (Apple Depth Pro) can never appear here.
    static let allowedLicenses: Set<String> = ["Apache-2.0", "MIT"]

    var model: DepthModel? {
        DepthModel(rawValue: id)
    }

    var isLicenseAllowed: Bool {
        Self.allowedLicenses.contains(license)
    }

    var isBundled: Bool {
        format == .bundled
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    var displayName: String {
        model?.displayName ?? id
    }

    var minimumOSVersion: OperatingSystemVersion? {
        guard let minimumOS else { return nil }
        let parts = minimumOS.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
    }
}

enum DepthModelCatalogLoader {
    static let bundledResourceName = "depth-models"
    static let remoteCatalogDefaultsKey = "depthModelCatalogLastFetch"

    /// Decodes the catalog shipped in the app bundle. A missing or malformed bundled
    /// catalog is a packaging error, so this throws rather than returning an empty list.
    static func loadBundled(bundle: Bundle = .main) throws -> DepthModelCatalog {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json")
            ?? bundle.url(forResource: bundledResourceName, withExtension: "json", subdirectory: "Resources") else {
            throw StereoPipelineError.modelNotFound
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> DepthModelCatalog {
        try JSONDecoder().decode(DepthModelCatalog.self, from: data)
    }

    /// Merges a remote catalog over the bundled one by id. The remote copy may add
    /// entries or update version/files/flags/requirements, but can never remove or hide
    /// the bundled model, and is ignored entirely when its schema or minimum app build
    /// does not fit the running app.
    static func merge(bundled: DepthModelCatalog, remote: DepthModelCatalog?, appBuild: Int) -> DepthModelCatalog {
        guard let remote,
              remote.schemaVersion == DepthModelCatalog.currentSchemaVersion,
              remote.minAppBuild <= appBuild else {
            return bundled
        }

        var merged = bundled
        var byID = Dictionary(uniqueKeysWithValues: bundled.models.map { ($0.id, $0) })
        var order = bundled.models.map(\.id)

        for entry in remote.models {
            if let existing = byID[entry.id], existing.isBundled {
                // Bundled entry: only presentation flags may change, and it stays visible.
                var updated = existing
                updated.recommended = entry.recommended
                updated.videoRecommended = entry.videoRecommended
                byID[entry.id] = updated
                continue
            }
            if byID[entry.id] == nil {
                order.append(entry.id)
            }
            byID[entry.id] = entry
        }

        merged.models = order.compactMap { byID[$0] }
        merged.minAppBuild = max(bundled.minAppBuild, remote.minAppBuild)
        return merged
    }

    /// The running app's build number (`CFBundleVersion`), for `minAppBuild` checks.
    static func currentAppBuild(bundle: Bundle = .main) -> Int {
        Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }
}
