import SwiftUI

/// One catalog entry in Settings: name, tier badge, size, license link, install state
/// and the actions that make sense for that state. Pure presentation — every action
/// is a closure, so the row knows nothing about the store.
struct DepthModelRow: View {
    let entry: DepthModelCatalogEntry
    let state: DepthModelStore.InstallState
    let compatibility: DepthModelCompatibility.Verdict
    let isSelected: Bool
    let isUpdateAvailable: Bool
    /// Actions that replace installed files (Update, Remove) wait for conversions.
    let isConversionRunning: Bool
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: entry.displayName)
                    .font(.headline)
                tierBadge
                Spacer(minLength: 0)
                if isSelected {
                    Label("In Use", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 6) {
                sizeText
                if let licenseURL = entry.licenseURL {
                    Text("•")
                    Link(destination: licenseURL) {
                        Text(verbatim: entry.license)
                    }
                }
                if let sourceURL = entry.sourceURL {
                    Text("•")
                    Link("Source", destination: sourceURL)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Independent hit areas inside a Form row; the default style would make
            // the whole row react to the first button.
            .buttonStyle(.borderless)

            statusView

            if case let .warning(message) = compatibility {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            actionButtons
        }
        .padding(.vertical, 4)
    }

    // MARK: - Pieces

    private var tierBadge: some View {
        Text(tierKey)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }

    private var tierKey: LocalizedStringKey {
        switch entry.tier {
        case .small:
            return "Small"
        case .base:
            return "Base"
        case .large:
            return "Large"
        }
    }

    @ViewBuilder
    private var sizeText: some View {
        if entry.isBundled {
            Text("Built-in")
        } else {
            Text(verbatim: Self.formatBytes(entry.totalBytes))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .builtIn:
            statusLine("Installed", systemImage: "checkmark.circle", tint: .green)
        case .notInstalled:
            statusLine("Not downloaded", systemImage: "arrow.down.circle", tint: .secondary)
        case let .blocked(reason):
            // Free space is the one block the user can clear; say so instead of
            // implying the device itself is unsuitable.
            if DepthModelCompatibility.isInsufficientFreeSpaceMessage(reason, for: entry) {
                statusLine("Not enough free space", systemImage: "externaldrive.badge.exclamationmark", tint: .secondary)
            } else {
                statusLine("Unavailable on this device", systemImage: "exclamationmark.triangle", tint: .secondary)
            }
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .queued:
            statusLine("Waiting to download…", systemImage: "clock", tint: .secondary)
        case let .downloading(fraction, bytesReceived, totalBytes):
            statusLine(
                "Downloading \(Self.formatPercent(fraction))",
                systemImage: "arrow.down.circle",
                tint: .secondary
            )
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
            Text("\(Self.formatBytes(bytesReceived)) of \(Self.formatBytes(totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .paused(fraction):
            statusLine("Paused at \(Self.formatPercent(fraction))", systemImage: "pause.circle", tint: .secondary)
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
        case .verifying:
            statusLine("Verifying…", systemImage: "checkmark.shield", tint: .secondary)
        case .preparing:
            statusLine("Preparing…", systemImage: "gearshape.2", tint: .secondary)
        case .installed:
            statusLine("Installed", systemImage: "checkmark.circle", tint: .green)
            if isUpdateAvailable {
                Text("A newer version is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(reason):
            statusLine("Failed", systemImage: "xmark.octagon", tint: .red)
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ key: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        Label(key, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            switch state {
            case .builtIn:
                useButton
            case .notInstalled:
                Button("Download", action: onDownload)
            case .blocked:
                Button("Download", action: onDownload)
                    .disabled(true)
            case .queued, .downloading:
                Button("Pause", action: onPause)
                Button("Cancel", role: .cancel, action: onCancel)
            case .paused:
                Button("Resume", action: onResume)
                Button("Cancel", role: .cancel, action: onCancel)
            case .verifying:
                Button("Cancel", role: .cancel, action: onCancel)
            case .preparing:
                EmptyView()
            case .installed:
                useButton
                if isUpdateAvailable {
                    Button("Update", action: onUpdate)
                        .disabled(isConversionRunning)
                }
                Button("Remove", role: .destructive, action: onRemove)
                    .disabled(isConversionRunning)
            case .failed:
                Button("Retry", action: onDownload)
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var useButton: some View {
        if !isSelected {
            Button("Use", action: onSelect)
        }
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func formatPercent(_ fraction: Double) -> String {
        max(0, min(1, fraction)).formatted(.percent.precision(.fractionLength(0)))
    }
}
