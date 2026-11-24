import SwiftUI

struct LiveVideoPreviewView: View {
    let url: URL
    let spatial: Bool
    let processor: VideoProcessor
    let strength: Float
    let options: Stereo3DOptions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preview = LiveVideoPreview()
    @State private var attempt = 0
    @State private var scrubPosition: Double?
    @State private var resumeAfterScrub = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("SBS Preview").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal)
            ZStack {
                if let message = preview.errorMessage {
                    VStack {
                        Text(message).multilineTextAlignment(.center)
                        Button("Retry") { attempt += 1 }.buttonStyle(.bordered)
                    }
                    .padding()
                } else if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(false)
                        .accessibilityLabel(Text("SBS Preview"))
                        .accessibilityIdentifier("liveStereoFrame")
                } else {
                    ProgressView("Preparing preview…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if preview.errorMessage == nil {
                HStack {
                    Button(action: preview.togglePlayback) {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill").frame(width: 38, height: 44)
                    }
                    .accessibilityLabel(preview.isPlaying ? Text("Pause") : Text("Play"))

                    Slider(value: Binding(get: { scrubPosition ?? preview.position }, set: { scrubPosition = $0 }),
                           in: 0...max(preview.duration, 0.001)) { editing in
                        if editing {
                            resumeAfterScrub = preview.isPlaying
                            preview.pause()
                        } else if let scrubPosition {
                            preview.seek(to: scrubPosition, resume: resumeAfterScrub)
                            self.scrubPosition = nil
                        }
                    }
                    .accessibilityLabel(Text("Playback position"))

                    Text(Duration.seconds(scrubPosition ?? preview.position).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit())
                    Button(action: preview.toggleSound) {
                        Image(systemName: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 38, height: 44)
                    }
                    .accessibilityLabel(preview.isMuted ? Text("Unmute") : Text("Mute"))
                }
                .disabled(preview.image == nil)
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .tint(.white)
        .background(.black)
        .preferredColorScheme(.dark)
        .task(id: attempt) {
            await preview.run(url: url, spatial: spatial, processor: processor, strength: strength, options: options)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { preview.pause() }
        }
        .onDisappear { preview.stop() }
    }
}
