import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Custom inline controls keep fullscreen entry exclusively in ResultPreviewView.
struct InlineVideoPreview: View {
    let player: AVPlayer?
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var position = 0.0
    @State private var duration = 0.0
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            InlinePlayerSurface(player: player)
                .frame(height: 200)
            HStack {
                Button {
                    guard let player else { return }
                    if player.timeControlStatus == .paused {
                        if duration > 0, position >= duration - 0.1 {
                            player.seek(to: .zero)
                        }
                        player.play()
                        isPlaying = true
                    } else {
                        player.pause()
                        isPlaying = false
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
                .disabled(player == nil)

                Slider(value: $position, in: 0...max(duration, 0.001)) { editing in
                    isScrubbing = editing
                    if !editing {
                        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                .accessibilityLabel(Text("Playback position"))
                .disabled(duration <= 0)
            }
            .padding(.horizontal, 8)
        }
        .onReceive(timer) { _ in
            let seconds = player?.currentItem?.duration.seconds ?? 0
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
            if !isScrubbing {
                let current = player?.currentTime().seconds ?? 0
                position = current.isFinite ? min(max(current, 0), duration) : 0
            }
            isPlaying = player.map { $0.timeControlStatus != .paused } ?? false
        }
        .onDisappear { player?.pause() }
    }
}

private struct InlinePlayerSurface: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerSurface, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
