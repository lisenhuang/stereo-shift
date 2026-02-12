import SwiftUI

struct ProgressViewOverlay: View {
    let title: Text
    let progress: Double
    let detail: Text
    let onCancel: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 14) {
                title
                    .font(.headline)

                ProgressView(value: max(0, min(1, progress)))
                    .progressViewStyle(.linear)

                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let onCancel {
                    Button("Stop", role: .destructive, action: onCancel)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
}
