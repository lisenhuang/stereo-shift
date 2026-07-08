import CoreImage
import CoreMotion
import MetalKit
import SwiftUI

/// Full-screen "Live 3D Preview": re-renders the photo from a virtual camera driven by
/// device tilt (or drag, where no gyroscope is available), using the same Metal warp
/// that produces the exported SBS pair. Preview only — saving and sharing stay SBS.
struct MotionParallaxPreviewView: View {
    let sourceImage: CGImage
    let depth: CVPixelBuffer
    let strength: Float
    let renderer: StereoRenderer

    @Environment(\.dismiss) private var dismiss

    @State private var session: MetalStereoRenderer.ParallaxPreviewSession?
    @State private var prepareFailed = false
    @State private var isHintVisible = true
    @State private var motionSource = MotionTiltSource()
    @State private var dragTilt = DragTiltBox()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if let session {
                    ParallaxMetalView(session: session, tiltTarget: { orientation in
                        let motion = motionSource.direction(for: orientation) ?? 0
                        return max(-1, min(1, motion + dragTilt.value))
                    })
                    .aspectRatio(CGSize(width: session.width, height: session.height), contentMode: .fit)
                    .gesture(dragGesture)
                } else if prepareFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("3D preview is unavailable for this photo.")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView("Preparing 3D preview…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .zIndex(10)
            .padding(12)
            .safeAreaPadding([.top, .trailing])
        }
        .overlay(alignment: .bottom) {
            if session != nil, isHintVisible {
                Label(hintKey, systemImage: motionSource.isAvailable ? "iphone.gen3.motion" : "hand.draw")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .task {
            await prepareSession()
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeInOut(duration: 0.6)) {
                isHintVisible = false
            }
        }
        .onAppear {
            motionSource.start()
        }
        .onDisappear {
            motionSource.stop()
        }
    }

    private var hintKey: LocalizedStringKey {
        motionSource.isAvailable ? "Tilt your phone to look around" : "Drag to look around"
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragTilt.value = Float(value.translation.width / 220)
            }
            .onEnded { _ in
                dragTilt.value = 0
            }
    }

    private func prepareSession() async {
        guard session == nil else { return }

        let image = sourceImage
        let depthBuffer = depth
        let appliedStrength = strength
        let stereoRenderer = renderer
        // Long side cap ≈ the tallest iPhone screen; keeps the per-frame warp cheap
        // without visible softness in the aspect-fit preview.
        let longSideCap = 2796

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let rgbBuffer = try PixelBufferUtilities.makePixelBuffer(from: image, longSideCap: longSideCap)
                return try stereoRenderer.makeParallaxPreviewSession(
                    rgb: rgbBuffer,
                    depth: depthBuffer,
                    strength: appliedStrength
                )
            }.value
            session = prepared
        } catch {
            prepareFailed = true
        }
    }
}

/// Latest drag-driven parallax offset. A plain reference type so the Metal draw loop
/// can read it every frame without triggering SwiftUI updates.
private final class DragTiltBox {
    var value: Float = 0
}

/// Reads device attitude relative to the pose the preview opened in, and maps the
/// "peek around" tilt to a horizontal parallax direction in [-1, 1].
private final class MotionTiltSource {
    private let motionManager = CMMotionManager()
    private var baseline: CMAttitude?
    /// Tilt (radians, ~11°) that reaches the full stereo baseline (|direction| = 1).
    private let fullTiltAngle = 0.20

    var isAvailable: Bool {
        motionManager.isDeviceMotionAvailable
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        baseline = nil
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        baseline = nil
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }

    /// Polled from the draw loop. Returns nil until the first attitude sample arrives.
    func direction(for orientation: UIInterfaceOrientation) -> Float? {
        guard let attitude = motionManager.deviceMotion?.attitude else { return nil }
        guard let baseline else {
            self.baseline = attitude.copy() as? CMAttitude
            return 0
        }
        guard let relative = attitude.copy() as? CMAttitude else { return nil }
        relative.multiply(byInverseOf: baseline)

        // Window metaphor: rotating the device rotates a window onto the scene, so the
        // virtual camera moves opposite the way the screen normal swings. The rotation
        // axis that produces horizontal parallax is the axis vertical to the viewer:
        // the device Y axis (roll) in portrait, the device X axis (pitch) in landscape.
        let tilt: Double
        switch orientation {
        case .landscapeLeft:
            tilt = relative.pitch
        case .landscapeRight:
            tilt = -relative.pitch
        case .portraitUpsideDown:
            tilt = relative.roll
        default:
            tilt = -relative.roll
        }
        return Float(max(-1.0, min(1.0, tilt / fullTiltAngle)))
    }
}

private struct ParallaxMetalView: UIViewRepresentable {
    let session: MetalStereoRenderer.ParallaxPreviewSession
    let tiltTarget: (UIInterfaceOrientation) -> Float

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: session.device)
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.tiltTarget = tiltTarget
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, tiltTarget: tiltTarget)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let session: MetalStereoRenderer.ParallaxPreviewSession
        var tiltTarget: (UIInterfaceOrientation) -> Float
        private let ciContext: CIContext
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        private var displayedDirection: Float = 0

        init(session: MetalStereoRenderer.ParallaxPreviewSession, tiltTarget: @escaping (UIInterfaceOrientation) -> Float) {
            self.session = session
            self.tiltTarget = tiltTarget
            self.ciContext = CIContext(mtlDevice: session.device, options: [.cacheIntermediates: false])
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let drawableSize = view.drawableSize
            guard drawableSize.width > 1, drawableSize.height > 1,
                  let drawable = view.currentDrawable,
                  let commandBuffer = session.makeCommandBuffer() else { return }

            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let target = tiltTarget(orientation)
            // Low-pass toward the target so sensor noise and drag release stay smooth.
            displayedDirection += (target - displayedDirection) * 0.22

            session.encodeNovelView(direction: displayedDirection, commandBuffer: commandBuffer)

            guard var image = CIImage(mtlTexture: session.outputTexture, options: [.colorSpace: colorSpace]) else {
                commandBuffer.commit()
                return
            }
            // Metal textures are top-left origin; Core Image is bottom-left.
            image = image.oriented(.downMirrored)

            let scale = min(drawableSize.width / image.extent.width, drawableSize.height / image.extent.height)
            let dx = (drawableSize.width - (image.extent.width * scale)) / 2
            let dy = (drawableSize.height - (image.extent.height * scale)) / 2
            image = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy)))
                .composited(over: CIImage(color: .black))

            ciContext.render(
                image,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: drawableSize),
                colorSpace: colorSpace
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
