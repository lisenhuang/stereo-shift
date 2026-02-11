import SwiftUI

struct HomeView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case photo = "Photo"
        case video = "Video"
        case gallery = "In-App Gallaey"

        var id: String { rawValue }
    }

    @StateObject private var pipeline = StereoPipeline()
    @StateObject private var galleryLibrary = AppGalleryLibrary()
    @State private var mode: Mode = .photo
    @State private var strength: Float = 0.9
    @State private var sbsLayoutEnabled = true
    private let bottomAnchorID = "content-bottom-anchor"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        modePicker

                        if mode == .photo {
                            PhotoFlowView(
                                pipeline: pipeline,
                                strength: $strength,
                                sbsLayoutEnabled: $sbsLayoutEnabled,
                                galleryLibrary: galleryLibrary,
                                onGenerated: {
                                    scrollToBottom(using: proxy)
                                }
                            )
                        } else if mode == .video {
                            VideoFlowView(
                                pipeline: pipeline,
                                strength: $strength,
                                sbsLayoutEnabled: $sbsLayoutEnabled,
                                galleryLibrary: galleryLibrary,
                                onGenerated: {
                                    scrollToBottom(using: proxy)
                                }
                            )
                        } else {
                            GalleryView(galleryLibrary: galleryLibrary)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .navigationTitle("StereoShift")
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2D to 3D Side-by-Side")
                .font(.title2.bold())
            Text("Create left-right stereo photos and videos offline with Depth Anything v2.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

#Preview {
    HomeView()
}
