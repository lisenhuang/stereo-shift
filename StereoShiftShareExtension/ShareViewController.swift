import Foundation
import os
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let appGroupIdentifier = "group.com.huanglisen.StereoShift"
    private static let logger = Logger(subsystem: "com.huanglisen.StereoShift", category: "ShareExtension")

    private var isFinished = false
    private var importTask: Task<Void, Never>?
    private var queuedInstagramLinks = false
    private var queuedRequests: [PendingInstagramImport] = []
    private var didStartAutomatically = false
    private var handoffTimeoutTask: Task<Void, Never>?
    private var handoffResolved = false

    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        spinner.hidesWhenStopped = true
        spinner.stopAnimating()

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.text = NSLocalizedString("Add media or an Instagram link to StereoShift?", comment: "")

        confirmButton.setTitle(NSLocalizedString("Confirm", comment: ""), for: .normal)
        confirmButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

        cancelButton.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [confirmButton, cancelButton])
        buttons.axis = .horizontal
        buttons.spacing = 24
        buttons.alignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, buttons])
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
        guard !didStartAutomatically, importTask == nil else { return }
        let hasLink = inputItemProviders().contains {
            ($0.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
             !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)) ||
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        } || (extensionContext?.inputItems as? [NSExtensionItem] ?? []).contains {
            !InstagramLink.extract(from: $0.attributedContentText?.string ?? "").isEmpty
        }
        guard hasLink else { return }
        didStartAutomatically = true
        confirmButton.isHidden = true
        startImport()
    }

    @objc private func confirmTapped() {
        if !queuedRequests.isEmpty {
            openContainingApp()
            return
        }
        confirmButton.isEnabled = false
        startImport()
    }

    @objc private func cancelTapped() {
        handoffResolved = true
        handoffTimeoutTask?.cancel()
        if isFinished {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            importTask?.cancel()
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }

    private func startImport() {
        spinner.startAnimating()
        messageLabel.text = NSLocalizedString("Importing…", comment: "")

        importTask = Task { [weak self] in
            guard let self else { return }

            do {
                let imported = try await importAllAttachments()
                try Task.checkCancellation()
                Self.logger.info("Imported \(imported, privacy: .public) item(s) into shared gallery")

                if queuedInstagramLinks {
                    await MainActor.run { self.openContainingApp() }
                    return
                }

                await MainActor.run {
                    self.isFinished = true
                    self.spinner.stopAnimating()
                    self.cancelButton.isEnabled = true
                    self.cancelButton.setTitle(NSLocalizedString("Close", comment: ""), for: .normal)
                    self.confirmButton.isHidden = true
                    self.messageLabel.text = imported > 0
                        ? NSLocalizedString("Added to In-App Gallery.", comment: "")
                        : NSLocalizedString("No supported media found. Share an Instagram post or Reel link, or a photo or video file.", comment: "")
                }

                if imported == 0 { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                if Task.isCancelled { return }
                Self.logger.error("Import failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.isFinished = true
                    self.spinner.stopAnimating()
                    self.confirmButton.isHidden = true
                    self.cancelButton.setTitle(NSLocalizedString("Close", comment: ""), for: .normal)
                    self.messageLabel.text = NSLocalizedString("Failed to add to In-App Gallery.", comment: "")
                }
            }
        }
    }

    private func openContainingApp() {
        guard let request = queuedRequests.last else { return }
        isFinished = true
        handoffResolved = false
        spinner.startAnimating()
        confirmButton.isHidden = true
        cancelButton.setTitle(NSLocalizedString("Close", comment: ""), for: .normal)
        messageLabel.text = NSLocalizedString("Opening StereoShift…", comment: "")
        handoffTimeoutTask?.cancel()
        handoffTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishHandoff(opened: false)
        }
        ContainingAppLauncher.open(request.handoffURL, from: self) { [weak self] opened in
            self?.finishHandoff(opened: opened)
        }
    }

    private func finishHandoff(opened: Bool) {
        guard !handoffResolved else { return }
        handoffResolved = true
        handoffTimeoutTask?.cancel()
        Self.logger.info("Containing app handoff accepted: \(opened, privacy: .public)")
        spinner.stopAnimating()
        if opened {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            messageLabel.text = NSLocalizedString("Link saved. Open StereoShift to continue automatically.", comment: "")
            confirmButton.setTitle(NSLocalizedString("Open StereoShift", comment: ""), for: .normal)
            confirmButton.isEnabled = true
            confirmButton.isHidden = false
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
        let providers = inputItemProviders()
        var links: [URL] = []
        var containsWebLink = false
        for provider in providers {
            // Prefer the post link over any preview image provided by the host app.
            let isURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
                !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let type = isURL ? UTType.url : UTType.plainText
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            let text = try await sharedText(from: provider, type: type)
            containsWebLink = containsWebLink || isURL
            links.append(contentsOf: InstagramLink.extract(from: text))
        }
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if let text = item.attributedContentText?.string {
                links.append(contentsOf: InstagramLink.extract(from: text))
            }
        }
        if !links.isEmpty {
            var seen = Set<URL>()
            let uniqueLinks = links.filter { seen.insert($0).inserted }
            for link in uniqueLinks {
                try Task.checkCancellation()
                queuedRequests.append(try InstagramShareInbox.enqueue(link))
            }
            queuedInstagramLinks = true
            return uniqueLinks.count
        }
        if containsWebLink { return 0 }

        guard let galleryDirectory = sharedGalleryDirectory() else {
            throw NSError(domain: "StereoShiftShareExtension", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "Missing App Group configuration."
            ])
        }

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

    private func sharedText(from provider: NSItemProvider, type: UTType) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
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
