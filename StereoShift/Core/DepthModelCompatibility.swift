import Foundation

/// A snapshot of the device the compatibility rules are evaluated against. Injected so
/// the rules are pure and unit-testable.
struct DeviceProfile: Sendable {
    var physicalMemoryBytes: UInt64
    var osVersion: OperatingSystemVersion
    /// Mac runtimes (Catalyst / "Designed for iPad") have desktop-class memory.
    var isMac: Bool
    /// Free space available for important (user-initiated) usage, if known.
    var availableBytes: Int64?

    var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824
    }

    static func current() -> DeviceProfile {
        let processInfo = ProcessInfo.processInfo
        var isMac = false
#if targetEnvironment(macCatalyst)
        isMac = true
#else
        isMac = processInfo.isiOSAppOnMac
#endif
        return DeviceProfile(
            physicalMemoryBytes: processInfo.physicalMemory,
            osVersion: processInfo.operatingSystemVersion,
            isMac: isMac,
            availableBytes: availableCapacityForImportantUsage()
        )
    }

    /// Free space on the volume the model library lives on. The library directory does
    /// not exist until the first download, so the user Application Support directory
    /// (created on demand) is asked instead, with the home directory as the last
    /// resort. Both are file URLs: a plain path wrapped in `URL(string:)` is not, and
    /// answers nil for every resource key.
    private static func availableCapacityForImportantUsage() -> Int64? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
            candidates.append(appSupport)
        }
        candidates.append(URL(fileURLWithPath: NSHomeDirectory()))

        for url in candidates {
            if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        }
        return nil
    }
}

/// Pure compatibility rules for a catalog entry on a device. Blocked rows stay visible
/// in Settings with the reason instead of disappearing.
enum DepthModelCompatibility {
    enum Verdict: Equatable, Sendable {
        case ok
        /// Downloadable, but the user should be told (e.g. below recommended memory).
        case warning(String)
        /// Not downloadable on this device / app version.
        case blocked(String)

        var isBlocked: Bool {
            if case .blocked = self { return true }
            return false
        }

        var message: String? {
            switch self {
            case .ok: return nil
            case let .warning(message), let .blocked(message): return message
            }
        }
    }

    /// Free space needed to download and install: package + compiled copy + slack for
    /// `.mlpackage` (compile writes a second tree), package + slack for `.mlmodelc`.
    static func requiredFreeBytes(for entry: DepthModelCatalogEntry) -> Int64 {
        let slack: Int64 = 100 * 1_048_576
        switch entry.format {
        case .bundled:
            return 0
        case .mlpackage:
            return Int64(Double(entry.totalBytes) * 2.2) + slack
        case .mlmodelc:
            return Int64(Double(entry.totalBytes) * 1.1) + slack
        }
    }

    static func evaluate(
        _ entry: DepthModelCatalogEntry,
        device: DeviceProfile,
        appBuild: Int,
        catalogMinAppBuild: Int
    ) -> Verdict {
        if entry.isBundled {
            return .ok
        }
        guard entry.model != nil else {
            return .blocked(requiresAppUpdateMessage)
        }
        guard entry.isLicenseAllowed else {
            return .blocked(NSLocalizedString(
                "License does not permit distribution in this app.",
                comment: "Depth model blocked: license is not on the allow-list"
            ))
        }
        if catalogMinAppBuild > appBuild {
            return .blocked(requiresAppUpdateMessage)
        }
        if let minimumOS = entry.minimumOSVersion,
           !isVersion(device.osVersion, atLeast: minimumOS) {
            return .blocked(String(
                format: NSLocalizedString("Requires iOS %@ or later.", comment: "Depth model blocked: minimum OS version"),
                entry.minimumOS ?? ""
            ))
        }

        if !device.isMac {
            if let minimum = entry.minimumPhysicalMemoryGB, device.physicalMemoryGB + 0.05 < minimum {
                return .blocked(String(
                    format: NSLocalizedString("Needs a device with at least %@ of memory.", comment: "Depth model blocked: minimum physical memory"),
                    formatGB(minimum)
                ))
            }
        }

        if let available = device.availableBytes, available < requiredFreeBytes(for: entry) {
            return .blocked(insufficientFreeSpaceMessage(for: entry))
        }

        if !device.isMac,
           let recommended = entry.recommendedPhysicalMemoryGB,
           device.physicalMemoryGB + 0.05 < recommended {
            return .warning(String(
                format: NSLocalizedString(
                    "Works best on devices with %@ or more memory. May be slow or unstable here.",
                    comment: "Depth model warning: below recommended physical memory"
                ),
                formatGB(recommended)
            ))
        }

        return .ok
    }

    // MARK: - Copy

    /// Shared by the unknown-id and catalog-too-new rules; also the right text for a
    /// model the catalog does not list at all.
    static var requiresAppUpdateMessage: String {
        NSLocalizedString("Requires an app update.", comment: "Depth model blocked: needs a newer app build")
    }

    /// The free-space reason for `entry`, built from the entry alone so it can be
    /// recognised again (`isInsufficientFreeSpaceMessage`).
    static func insufficientFreeSpaceMessage(for entry: DepthModelCatalogEntry) -> String {
        let formatted = ByteCountFormatter.string(fromByteCount: requiredFreeBytes(for: entry), countStyle: .file)
        return String(
            format: NSLocalizedString("Not enough free space. About %@ is required.", comment: "Depth model blocked: insufficient free space"),
            formatted
        )
    }

    /// Whether a blocked reason is the free-space one for `entry`. `InstallState.blocked`
    /// carries only the text, so the row tells this case apart (it clears itself once
    /// the user frees space, unlike the others) by regenerating the message.
    static func isInsufficientFreeSpaceMessage(_ message: String, for entry: DepthModelCatalogEntry) -> Bool {
        !entry.isBundled && message == insufficientFreeSpaceMessage(for: entry)
    }

    private static func formatGB(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) GB" : String(format: "%.1f GB", value)
    }

    private static func isVersion(_ version: OperatingSystemVersion, atLeast minimum: OperatingSystemVersion) -> Bool {
        if version.majorVersion != minimum.majorVersion { return version.majorVersion > minimum.majorVersion }
        if version.minorVersion != minimum.minorVersion { return version.minorVersion > minimum.minorVersion }
        return version.patchVersion >= minimum.patchVersion
    }
}
