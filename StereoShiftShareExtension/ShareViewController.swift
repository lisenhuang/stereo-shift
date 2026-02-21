import Foundation
import os
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let appGroupIdentifier = "group.com.huanglisen.StereoShift"
    private static let logger = Logger(subsystem: "com.huanglisen.StereoShift", category: "ShareExtension")

    private var didStartImport = false
    private var importTask: Task<Void, Never>?

    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        spinner.hidesWhenStopped = true
        spinner.startAnimating()

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.text = "Adding to In-App Gallery…"

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.9),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartImport else { return }
        didStartImport = true
        startImport()
    }

    @objc private func cancelTapped() {
        importTask?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func startImport() {
        let providerCount = inputItemProviders().count
        if providerCount > 0 {
            messageLabel.text = "Adding \(providerCount) item(s) to In-App Gallery…"
        }

        importTask = Task { [weak self] in
            guard let self else { return }

            do {
                let imported = try await importAllAttachments()
                Self.logger.info("Imported \(imported, privacy: .public) item(s) into shared gallery")

                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.cancelButton.isEnabled = false
                    self.messageLabel.text = imported > 0 ? "Added to In-App Gallery." : "No supported photos or videos found."
                }

                try? await Task.sleep(nanoseconds: 400_000_000)
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                Self.logger.error("Import failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.cancelButton.setTitle("Close", for: .normal)
                    self.messageLabel.text = "Failed to add to In-App Gallery."
                }
            }
        }
    }

    private enum SharedMediaType {
        case image
        case video

        var filePrefix: String {
            switch self {
            case .image:
                return "photo"
            case .video:
                return "video"
            }
        }
    }

    private func importAllAttachments() async throws -> Int {
        guard let galleryDirectory = sharedGalleryDirectory() else {
            throw NSError(domain: "StereoShiftShareExtension", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "Missing App Group configuration."
            ])
        }

        let providers = inputItemProviders()
        guard !providers.isEmpty else {
            return 0
        }

        var imported = 0
        for provider in providers {
            if Task.isCancelled {
                break
            }

            do {
                if try await importProvider(provider, to: galleryDirectory) {
                    imported += 1
                }
            } catch {
                continue
            }
        }

        return imported
    }

    private func inputItemProviders() -> [NSItemProvider] {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    private func sharedGalleryDirectory() -> URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            return nil
        }

        let directory = containerURL
            .appendingPathComponent("StereoShift", isDirectory: true)
            .appendingPathComponent("Gallery", isDirectory: true)

        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return directory
        } catch {
            return nil
        }
    }

    private func importProvider(_ provider: NSItemProvider, to galleryDirectory: URL) async throws -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
            try await copyRepresentation(from: provider, candidateTypes: [UTType.movie, UTType.video], mediaType: .video, to: galleryDirectory)
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            try await copyRepresentation(from: provider, candidateTypes: [UTType.image], mediaType: .image, to: galleryDirectory)
            return true
        }

        return false
    }

    private func copyRepresentation(
        from provider: NSItemProvider,
        candidateTypes: [UTType],
        mediaType: SharedMediaType,
        to galleryDirectory: URL
    ) async throws {
        var lastError: Error?

        for type in candidateTypes {
            do {
                try await copyRepresentation(from: provider, typeIdentifier: type.identifier, mediaType: mediaType, to: galleryDirectory)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(domain: "StereoShiftShareExtension", code: 1002, userInfo: [
            NSLocalizedDescriptionKey: "Unable to load shared item."
        ])
    }

    private func copyRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        mediaType: SharedMediaType,
        to galleryDirectory: URL
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url else {
                    continuation.resume(throwing: NSError(domain: "StereoShiftShareExtension", code: 1003, userInfo: [
                        NSLocalizedDescriptionKey: "Shared file missing."
                    ]))
                    return
                }

                do {
                    let destinationURL = try Self.makeDestinationURL(for: url, typeIdentifier: typeIdentifier, mediaType: mediaType, galleryDirectory: galleryDirectory)
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeDestinationURL(
        for sourceURL: URL,
        typeIdentifier: String,
        mediaType: SharedMediaType,
        galleryDirectory: URL
    ) throws -> URL {
        let fileExtension = normalizedFileExtension(for: sourceURL, typeIdentifier: typeIdentifier, mediaType: mediaType)
        let filename = "\(mediaType.filePrefix)-\(UUID().uuidString).\(fileExtension)"
        return galleryDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func normalizedFileExtension(for sourceURL: URL, typeIdentifier: String, mediaType: SharedMediaType) -> String {
        let existing = sourceURL.pathExtension.lowercased()
        if !existing.isEmpty {
            return existing
        }

        if let preferred = UTType(typeIdentifier)?.preferredFilenameExtension {
            return preferred
        }

        switch mediaType {
        case .image:
            return "jpg"
        case .video:
            return "mov"
        }
    }
}

