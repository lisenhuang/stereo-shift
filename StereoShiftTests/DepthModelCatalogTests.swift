import Foundation
import Testing
@testable import StereoShift

/// The bundled `depth-models.json` is the only thing the download flow trusts for URLs,
/// sizes and hashes, so these tests pin its shape, the merge rules that keep a remote
/// copy from ever breaking the bundled model, and the pure device-compatibility rules.
struct DepthModelCatalogTests {
    private static let mebibyte: Int64 = 1_048_576
    private static let gibibyte: Double = 1_073_741_824

    // MARK: Fixtures

    private static func makeFile(path: String, bytes: Int64) -> DepthModelCatalogEntry.File {
        let asset = path.replacingOccurrences(of: "/", with: "_")
        return DepthModelCatalogEntry.File(
            path: path,
            urls: [
                URL(string: "https://huggingface.co/example/repo/resolve/0123abcd/Model.mlpackage/\(path)")!,
                URL(string: "https://github.com/lisenhuang/stereo-shift/releases/download/models-v1/Test-1-\(asset)")!
            ],
            bytes: bytes,
            sha256: String(repeating: "a", count: 64)
        )
    }

    private static func makeEntry(
        id: String = DepthModel.depthAnythingV3SmallF16.rawValue,
        version: String = "2026.09.1",
        format: DepthModelCatalogEntry.ArtifactFormat = .mlpackage,
        license: String = "Apache-2.0",
        minimumOS: String? = "17.0",
        minimumRAM: Double? = 3,
        recommendedRAM: Double? = 4,
        visible: Bool = true,
        recommended: Bool = false,
        videoRecommended: Bool = false,
        totalBytes: Int64 = 100 * mebibyte
    ) -> DepthModelCatalogEntry {
        let files: [DepthModelCatalogEntry.File] = format == .bundled ? [] : [
            makeFile(path: "Manifest.json", bytes: 617),
            makeFile(path: "Data/com.apple.CoreML/model.mlmodel", bytes: 300_000),
            makeFile(path: "Data/com.apple.CoreML/weights/weight.bin", bytes: totalBytes - 617 - 300_000)
        ]
        return DepthModelCatalogEntry(
            id: id,
            version: version,
            format: format,
            packageName: format == .mlmodelc ? "Model.mlmodelc" : "Model.mlpackage",
            tier: .small,
            license: license,
            licenseURL: nil,
            sourceURL: nil,
            inputWidth: 504,
            inputHeight: 504,
            minimumOS: minimumOS,
            minimumPhysicalMemoryGB: minimumRAM,
            recommendedPhysicalMemoryGB: recommendedRAM,
            estimatedPeakMemoryMB: nil,
            visible: visible,
            recommended: recommended,
            videoRecommended: videoRecommended,
            files: files,
            provenance: nil
        )
    }

    private static func makeBundledEntry(recommended: Bool = true, videoRecommended: Bool = true) -> DepthModelCatalogEntry {
        makeEntry(
            id: DepthModel.bundledDefault.rawValue,
            version: "bundled",
            format: .bundled,
            minimumOS: nil,
            minimumRAM: nil,
            recommendedRAM: nil,
            recommended: recommended,
            videoRecommended: videoRecommended
        )
    }

    /// A stand-in for the shipped catalog: the bundled model plus one download.
    private static func makeBundledCatalog() -> DepthModelCatalog {
        DepthModelCatalog(
            schemaVersion: DepthModelCatalog.currentSchemaVersion,
            minAppBuild: 25,
            models: [makeBundledEntry(), makeEntry()]
        )
    }

    private static func makeDevice(
        memoryGB: Double,
        isMac: Bool = false,
        availableBytes: Int64? = nil,
        os: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)
    ) -> DeviceProfile {
        DeviceProfile(
            physicalMemoryBytes: UInt64(memoryGB * gibibyte),
            osVersion: os,
            isMac: isMac,
            availableBytes: availableBytes
        )
    }

    private static func isLowercaseHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    // MARK: Bundled catalog

    @Test func bundledCatalogDecodesAndTargetsThisBuild() throws {
        let catalog = try DepthModelCatalogLoader.loadBundled()

        #expect(catalog.schemaVersion == DepthModelCatalog.currentSchemaVersion)
        #expect(catalog.minAppBuild > 0)
        // A catalog the shipping app cannot use would silently hide every download.
        #expect(catalog.minAppBuild <= DepthModelCatalogLoader.currentAppBuild())
        #expect(!catalog.models.isEmpty)

        let bundled = try #require(catalog.entry(for: .bundledDefault))
        #expect(bundled.isBundled)
        #expect(bundled.files.isEmpty)
        #expect(bundled.visible)
        #expect(bundled.recommended)
        #expect(bundled.totalBytes == 0)
    }

    @Test func everyBundledEntryMapsToACompiledInModel() throws {
        let catalog = try DepthModelCatalogLoader.loadBundled()

        for entry in catalog.models {
            #expect(entry.model != nil, "\(entry.id) is not a DepthModel case")
        }
        // Every compiled-in model is offered; ids are unique.
        for model in DepthModel.allCases {
            #expect(catalog.entry(for: model) != nil, "\(model.rawValue) has no catalog entry")
        }
        #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
        #expect(catalog.supportedEntries.count == catalog.models.count)
    }

    @Test func everyBundledEntryHasAnAllowedLicense() throws {
        let catalog = try DepthModelCatalogLoader.loadBundled()

        for entry in catalog.models {
            #expect(entry.isLicenseAllowed, "\(entry.id) license \(entry.license) is not on the allow-list")
            #expect(DepthModelCatalogEntry.allowedLicenses.contains(entry.license))
        }
    }

    @Test func downloadableEntriesDescribeCompletePackages() throws {
        let catalog = try DepthModelCatalogLoader.loadBundled()
        let downloadable = catalog.models.filter { !$0.isBundled }
        #expect(!downloadable.isEmpty)

        for entry in downloadable {
            #expect(entry.format == .mlpackage, "\(entry.id)")
            #expect(entry.packageName.hasSuffix(".mlpackage"), "\(entry.id)")
            #expect(!entry.version.isEmpty, "\(entry.id)")
            #expect(entry.files.count == 3, "\(entry.id) should list Manifest.json, model.mlmodel and weight.bin")
            #expect(entry.minimumOSVersion != nil, "\(entry.id)")
            #expect(entry.minimumPhysicalMemoryGB != nil, "\(entry.id)")
            #expect(entry.recommendedPhysicalMemoryGB != nil, "\(entry.id)")
            #expect(entry.provenance?.sourceRevision?.count == 40, "\(entry.id) must pin a full commit sha")

            let paths = Set(entry.files.map(\.path))
            #expect(paths.contains("Manifest.json"), "\(entry.id)")
            #expect(paths.contains("Data/com.apple.CoreML/model.mlmodel"), "\(entry.id)")
            #expect(paths.contains("Data/com.apple.CoreML/weights/weight.bin"), "\(entry.id)")

            for file in entry.files {
                #expect(Self.isLowercaseHexSHA256(file.sha256), "\(entry.id)/\(file.path) sha256 \(file.sha256)")
                #expect(file.bytes > 0, "\(entry.id)/\(file.path)")
                #expect(file.urls.count == 2, "\(entry.id)/\(file.path) needs a primary and a mirror URL")
                #expect(file.urls.first?.host == "huggingface.co", "\(entry.id)/\(file.path) primary must be Hugging Face")
                #expect(file.urls.last?.host == "github.com", "\(entry.id)/\(file.path) mirror must be GitHub Releases")
                #expect(file.urls.allSatisfy { $0.scheme == "https" })
                // Hugging Face URLs are pinned to the provenance commit and end in the package path.
                #expect(file.urls.first?.path.contains(entry.provenance?.sourceRevision ?? "?") == true)
                #expect(file.urls.first?.path.hasSuffix("\(entry.packageName)/\(file.path)") == true)
                // GitHub assets cannot contain "/", so the path is flattened behind id-version.
                let asset = file.urls.last?.lastPathComponent ?? ""
                #expect(asset == "\(entry.id)-\(entry.version)-\(file.path.replacingOccurrences(of: "/", with: "_"))")
            }
        }
    }

    @Test func smallDepthAnything3EntryIsAtLeast60MB() throws {
        let catalog = try DepthModelCatalogLoader.loadBundled()
        let small = try #require(catalog.entry(for: .depthAnythingV3SmallF16))

        #expect(small.tier == .small)
        #expect(small.videoRecommended)
        #expect(small.totalBytes > 60 * Self.mebibyte)
        // Sizes come from the Hub API; a weight file below this would be a truncated listing.
        let weights = try #require(small.files.first { $0.path.hasSuffix("weight.bin") })
        #expect(weights.bytes > 60 * Self.mebibyte)
    }

    @Test func catalogRoundTripsThroughJSON() throws {
        let original = Self.makeBundledCatalog()
        let data = try JSONEncoder().encode(original)
        let decoded = try DepthModelCatalogLoader.decode(data)

        #expect(decoded == original)
    }

    // MARK: Merge

    @Test func mergeWithoutRemoteReturnsBundled() {
        let bundled = Self.makeBundledCatalog()
        #expect(DepthModelCatalogLoader.merge(bundled: bundled, remote: nil, appBuild: 25) == bundled)
    }

    @Test func mergeCannotRemoveOrHideBundledModel() {
        let bundled = Self.makeBundledCatalog()

        // Remote omits the bundled entry entirely.
        let omitting = DepthModelCatalog(schemaVersion: 1, minAppBuild: 25, models: [Self.makeEntry()])
        let mergedOmitting = DepthModelCatalogLoader.merge(bundled: bundled, remote: omitting, appBuild: 25)
        #expect(mergedOmitting.entry(for: .bundledDefault) == Self.makeBundledEntry())
        #expect(mergedOmitting.models.map(\.id) == bundled.models.map(\.id))

        // Remote tries to hide it and turn it into a download.
        var hostile = Self.makeEntry(id: DepthModel.bundledDefault.rawValue, version: "9.9.9", visible: false, recommended: false)
        hostile.format = .mlpackage
        let hiding = DepthModelCatalog(schemaVersion: 1, minAppBuild: 25, models: [hostile])
        let mergedHiding = DepthModelCatalogLoader.merge(bundled: bundled, remote: hiding, appBuild: 25)
        let survivor = mergedHiding.entry(for: .bundledDefault)
        #expect(survivor?.isBundled == true)
        #expect(survivor?.visible == true)
        #expect(survivor?.files.isEmpty == true)
        #expect(survivor?.version == "bundled")
        // Only the presentation flags may follow the remote copy.
        #expect(survivor?.recommended == false)
    }

    @Test func mergeIgnoresRemoteWithWrongSchemaVersion() {
        let bundled = Self.makeBundledCatalog()
        let remote = DepthModelCatalog(
            schemaVersion: DepthModelCatalog.currentSchemaVersion + 1,
            minAppBuild: 25,
            models: [Self.makeEntry(id: DepthModel.depthAnythingV3BaseF16.rawValue)]
        )

        #expect(DepthModelCatalogLoader.merge(bundled: bundled, remote: remote, appBuild: 25) == bundled)
    }

    @Test func mergeIgnoresRemoteRequiringNewerApp() {
        let bundled = Self.makeBundledCatalog()
        let remote = DepthModelCatalog(
            schemaVersion: DepthModelCatalog.currentSchemaVersion,
            minAppBuild: 26,
            models: [Self.makeEntry(id: DepthModel.depthAnythingV3BaseF16.rawValue)]
        )

        #expect(DepthModelCatalogLoader.merge(bundled: bundled, remote: remote, appBuild: 25) == bundled)
        // The same remote is accepted once the app catches up.
        let accepted = DepthModelCatalogLoader.merge(bundled: bundled, remote: remote, appBuild: 26)
        #expect(accepted.entry(for: .depthAnythingV3BaseF16) != nil)
        #expect(accepted.minAppBuild == 26)
    }

    @Test func mergeAddsEntriesAndBumpsVersions() {
        let bundled = Self.makeBundledCatalog()
        let bumped = Self.makeEntry(version: "2026.10.1", recommended: true, totalBytes: 120 * Self.mebibyte)
        let added = Self.makeEntry(id: DepthModel.depthAnythingV3MonoLargeF16.rawValue, minimumRAM: 6, recommendedRAM: 8)
        let remote = DepthModelCatalog(schemaVersion: 1, minAppBuild: 25, models: [added, bumped])

        let merged = DepthModelCatalogLoader.merge(bundled: bundled, remote: remote, appBuild: 25)

        // Bundled order is kept; new ids are appended.
        #expect(merged.models.map(\.id) == [
            DepthModel.bundledDefault.rawValue,
            DepthModel.depthAnythingV3SmallF16.rawValue,
            DepthModel.depthAnythingV3MonoLargeF16.rawValue
        ])
        #expect(merged.entry(for: .depthAnythingV3SmallF16) == bumped)
        #expect(merged.entry(for: .depthAnythingV3SmallF16)?.version == "2026.10.1")
        #expect(merged.entry(for: .depthAnythingV3MonoLargeF16) == added)
        #expect(merged.entry(for: .bundledDefault)?.isBundled == true)
    }

    // MARK: Compatibility

    // Verdict copy is localized, so these assert on the case (and on the interpolated
    // argument where there is one), never on English words.

    @Test func bundledEntryIsAlwaysCompatible() {
        let verdict = DepthModelCompatibility.evaluate(
            Self.makeBundledEntry(),
            device: Self.makeDevice(memoryGB: 1, availableBytes: 0),
            appBuild: 1,
            catalogMinAppBuild: 99
        )
        #expect(verdict == .ok)
    }

    @Test func blockedBelowMinimumMemory() {
        let entry = Self.makeEntry(minimumRAM: 3, recommendedRAM: 4)
        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 2), appBuild: 25, catalogMinAppBuild: 25)

        #expect(verdict.isBlocked)
        #expect(verdict.message?.contains("3 GB") == true)
        #expect(!DepthModelCompatibility.isInsufficientFreeSpaceMessage(verdict.message ?? "", for: entry))
    }

    @Test func warningBelowRecommendedMemory() {
        let entry = Self.makeEntry(minimumRAM: 3, recommendedRAM: 6)
        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 4), appBuild: 25, catalogMinAppBuild: 25)

        #expect(!verdict.isBlocked)
        if case .warning = verdict {
            #expect(verdict.message?.contains("6 GB") == true)
        } else {
            Issue.record("expected a warning, got \(verdict)")
        }
    }

    @Test func okAtRecommendedMemoryWithReportingTolerance() {
        let entry = Self.makeEntry(minimumRAM: 3, recommendedRAM: 6)

        #expect(DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 6), appBuild: 25, catalogMinAppBuild: 25) == .ok)
        // Devices report slightly under their nominal size (e.g. 5.97 GB on a "6 GB" phone).
        #expect(DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 5.97), appBuild: 25, catalogMinAppBuild: 25) == .ok)
        #expect(DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 2.97), appBuild: 25, catalogMinAppBuild: 25) != .ok)
    }

    @Test func blockedWhenFreeSpaceIsInsufficient() {
        let entry = Self.makeEntry()
        let required = DepthModelCompatibility.requiredFreeBytes(for: entry)

        let tight = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8, availableBytes: required - 1), appBuild: 25, catalogMinAppBuild: 25)
        #expect(tight.isBlocked)
        // The row recognises this one case (it clears once space is freed) from the text.
        #expect(DepthModelCompatibility.isInsufficientFreeSpaceMessage(tight.message ?? "", for: entry))
        #expect(tight.message == DepthModelCompatibility.insufficientFreeSpaceMessage(for: entry))

        let enough = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8, availableBytes: required), appBuild: 25, catalogMinAppBuild: 25)
        #expect(enough == .ok)

        // Unknown free space is not a reason to block.
        let unknown = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8, availableBytes: nil), appBuild: 25, catalogMinAppBuild: 25)
        #expect(unknown == .ok)
    }

    @Test func macIgnoresMemoryRequirements() {
        let entry = Self.makeEntry(minimumRAM: 6, recommendedRAM: 8)
        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 1, isMac: true), appBuild: 25, catalogMinAppBuild: 25)

        #expect(verdict == .ok)
        // Free space still applies on a Mac.
        let full = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 1, isMac: true, availableBytes: 0), appBuild: 25, catalogMinAppBuild: 25)
        #expect(full.isBlocked)
    }

    @Test func unknownModelIDIsBlocked() {
        let entry = Self.makeEntry(id: "DepthAnythingV9UltraF16")
        #expect(entry.model == nil)
        #expect(entry.displayName == "DepthAnythingV9UltraF16")

        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8), appBuild: 25, catalogMinAppBuild: 25)
        #expect(verdict.isBlocked)
        #expect(verdict.message == DepthModelCompatibility.requiresAppUpdateMessage)
    }

    @Test func nonCommercialLicenseIsBlocked() {
        let entry = Self.makeEntry(license: "CC-BY-NC-4.0")
        #expect(!entry.isLicenseAllowed)

        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8), appBuild: 25, catalogMinAppBuild: 25)
        #expect(verdict.isBlocked)
        #expect(verdict.message != DepthModelCompatibility.requiresAppUpdateMessage)

        let catalog = DepthModelCatalog(schemaVersion: 1, minAppBuild: 25, models: [Self.makeBundledEntry(), entry])
        #expect(catalog.supportedEntries.map(\.id) == [DepthModel.bundledDefault.rawValue])
    }

    @Test func catalogRequiringNewerAppIsBlocked() {
        let entry = Self.makeEntry()
        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8), appBuild: 25, catalogMinAppBuild: 26)

        #expect(verdict.isBlocked)
        #expect(verdict.message == DepthModelCompatibility.requiresAppUpdateMessage)
        #expect(DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8), appBuild: 26, catalogMinAppBuild: 26) == .ok)
    }

    @Test func olderOSIsBlocked() {
        let entry = Self.makeEntry(minimumOS: "18.0")
        let older = OperatingSystemVersion(majorVersion: 17, minorVersion: 6, patchVersion: 1)
        let verdict = DepthModelCompatibility.evaluate(entry, device: Self.makeDevice(memoryGB: 8, os: older), appBuild: 25, catalogMinAppBuild: 25)

        #expect(verdict.isBlocked)
        #expect(verdict.message?.contains("18.0") == true)
        #expect(entry.minimumOSVersion?.majorVersion == 18)
    }

    @Test func requiredFreeBytesScalesWithArtifactFormat() {
        let slack = 100 * Self.mebibyte
        let total: Int64 = 100 * Self.mebibyte

        let package = Self.makeEntry(format: .mlpackage, totalBytes: total)
        #expect(package.totalBytes == total)
        #expect(DepthModelCompatibility.requiredFreeBytes(for: package) == Int64(Double(total) * 2.2) + slack)

        let compiled = Self.makeEntry(format: .mlmodelc, totalBytes: total)
        #expect(DepthModelCompatibility.requiredFreeBytes(for: compiled) == Int64(Double(total) * 1.1) + slack)

        #expect(DepthModelCompatibility.requiredFreeBytes(for: Self.makeBundledEntry()) == 0)
    }
}
