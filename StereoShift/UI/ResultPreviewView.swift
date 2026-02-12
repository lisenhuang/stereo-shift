import AVKit
import SwiftUI
import UIKit

enum PreviewMedia {
    case image(CGImage)
    case imageFile(URL)
    case video(URL)
}

struct ResultPreviewView: View {
    let title: LocalizedStringKey
    let media: PreviewMedia
    var allowsFullscreenPreview: Bool = false

    @State private var player: AVPlayer?
    @State private var isShowingFullscreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Group {
                switch media {
                case let .image(cgImage):
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .scaledToFit()

                case let .imageFile(url):
                    if let uiImage = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        previewUnavailableView
                    }

                case let .video(url):
                    VideoPlayer(player: player)
                        .onAppear {
                            if player?.currentItem?.asset as? AVURLAsset == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != url {
                                player = AVPlayer(url: url)
                            }
                            player?.actionAtItemEnd = .none
                            player?.play()
                        }
                        .onDisappear {
                            player?.pause()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                            guard let currentItem = player?.currentItem else { return }
                            guard let endedItem = notification.object as? AVPlayerItem, endedItem == currentItem else { return }
                            player?.seek(to: .zero)
                            player?.play()
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 220)
            .contentShape(Rectangle())
            .onTapGesture {
                if allowsFullscreenPreview {
                    isShowingFullscreen = true
                }
            }
            .overlay {
                if allowsFullscreenPreview {
                    Button {
                        isShowingFullscreen = true
                    } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2))
            }
            .overlay(alignment: .topTrailing) {
                if allowsFullscreenPreview {
                    Button {
                        isShowingFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .fullScreenCover(isPresented: $isShowingFullscreen) {
            FullscreenPreviewView(media: media)
        }
    }

    private var previewUnavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text("Preview unavailable")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}

private struct FullscreenPreviewView: View {
    let media: PreviewMedia
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                Group {
                    switch media {
                    case let .image(cgImage):
                        Image(decorative: cgImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                    case let .imageFile(url):
                        if let uiImage = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                        } else {
                            unavailable
                        }
                    case let .video(url):
                        VideoPlayer(player: player)
                            .onAppear {
                                if player?.currentItem == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != url {
                                    player = AVPlayer(url: url)
                                }
                                player?.actionAtItemEnd = .none
                                player?.play()
                            }
                            .onDisappear {
                                player?.pause()
                            }
                            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                                guard let currentItem = player?.currentItem else { return }
                                guard let endedItem = notification.object as? AVPlayerItem, endedItem == currentItem else { return }
                                player?.seek(to: .zero)
                                player?.play()
                            }
                    }
                }
                .frame(width: geometry.size.width, alignment: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text("Preview unavailable")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}
