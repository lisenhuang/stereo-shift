import SwiftUI

struct ProgressViewOverlay: View {
    let title: String
    let progress: Double
    let detail: String
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.headline)

            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let onCancel {
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 12)
    }
}
