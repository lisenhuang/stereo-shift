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
                        .allowsHitTesting(false)
                        .onAppear {
                            if player?.currentItem?.asset as? AVURLAsset == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != url {
                                player = AVPlayer(url: url)
                            }
                            player?.actionAtItemEnd = .pause
                            player?.pause()
                            player?.seek(to: .zero)
                        }
                        .onChange(of: url) { _, newURL in
                            if player?.currentItem?.asset as? AVURLAsset == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != newURL {
                                player = AVPlayer(url: newURL)
                            }
                            player?.actionAtItemEnd = .pause
                            player?.pause()
                            player?.seek(to: .zero)
                        }
                        .onDisappear {
                            player?.pause()
                            player?.seek(to: .zero)
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
                    if let previewImage = previewUIImage {
                        ZoomableImageView(image: previewImage)
                    } else if case let .video(url) = media {
                        VideoPlayer(player: player)
                            .onAppear {
                                if player?.currentItem == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != url {
                                    player = AVPlayer(url: url)
                                }
                                player?.actionAtItemEnd = .none
                                player?.play()
                            }
                            .onChange(of: url) { _, newURL in
                                if player?.currentItem == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != newURL {
                                    player = AVPlayer(url: newURL)
                                }
                                player?.actionAtItemEnd = .none
                                player?.play()
                            }
                            .onDisappear {
                                player?.pause()
                                player?.seek(to: .zero)
                            }
                            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                                guard let currentItem = player?.currentItem else { return }
                                guard let endedItem = notification.object as? AVPlayerItem, endedItem == currentItem else { return }
                                player?.seek(to: .zero)
                                player?.play()
                            }
                    } else {
                        unavailable
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

    private var previewUIImage: UIImage? {
        switch media {
        case let .image(cgImage):
            return UIImage(cgImage: cgImage)
        case let .imageFile(url):
            return UIImage(contentsOfFile: url.path)
        case .video:
            return nil
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.zoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        if scrollView.zoomScale < scrollView.minimumZoomScale || scrollView.zoomScale > scrollView.maximumZoomScale {
            scrollView.setZoomScale(1.0, animated: false)
        }
        context.coordinator.centerImage(in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        func centerImage(in scrollView: UIScrollView) {
            let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) * 0.5)
            let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) * 0.5)
            scrollView.contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
        }

        @objc
        func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let zoomScale = min(scrollView.maximumZoomScale, 2.5)
            let point = gesture.location(in: imageView)
            let zoomSize = CGSize(width: scrollView.bounds.width / zoomScale, height: scrollView.bounds.height / zoomScale)
            let zoomRect = CGRect(
                x: point.x - (zoomSize.width * 0.5),
                y: point.y - (zoomSize.height * 0.5),
                width: zoomSize.width,
                height: zoomSize.height
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }
    }
}
