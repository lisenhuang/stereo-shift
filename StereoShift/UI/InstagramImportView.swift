import SwiftUI

struct InstagramImportView: View {
    let request: PendingInstagramImport
    let onImported: (ImportedInstagramMedia) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("Retry", action: startImport)
                        .buttonStyle(.borderedProminent)
                } else {
                    ProgressView("Loading...")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Shared from Instagram")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { startImport() }
            .onDisappear { importTask?.cancel() }
            .interactiveDismissDisabled(isImporting)
        }
    }

    private func startImport() {
        guard !isImporting else { return }
        errorMessage = nil
        isImporting = true
        importTask = Task {
            defer { isImporting = false }
            do {
                let media = try await InstagramMediaImporter.download(postURL: request.url)
                guard !Task.isCancelled else {
                    TempFiles.removeItemIfExists(at: media.url)
                    return
                }
                // Failed or cancelled imports stay queued for a later app launch.
                try? InstagramShareInbox.remove(request)
                onImported(media)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
