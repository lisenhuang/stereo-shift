import AVKit
import SwiftUI

enum PreviewMedia {
    case image(CGImage)
    case video(URL)
}

struct ResultPreviewView: View {
    let title: String
    let media: PreviewMedia

    @State private var player: AVPlayer?

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

                case let .video(url):
                    VideoPlayer(player: player)
                        .onAppear {
                            if player?.currentItem?.asset as? AVURLAsset == nil || (player?.currentItem?.asset as? AVURLAsset)?.url != url {
                                player = AVPlayer(url: url)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2))
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
