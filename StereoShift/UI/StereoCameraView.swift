import ARKit
import SwiftUI

struct StereoCameraView: View {
    let onComplete: (StereoImagePair) -> Void
    @StateObject private var camera = StereoCameraController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showGhost = true
    @State private var showDiscardConfirmation = false
    @State private var holdsAwakeLock = false

    private let accent = Color(red: 0.62, green: 0.94, blue: 0.76)
    private var isReviewing: Bool { camera.pair != nil }
    private var isRight: Bool { camera.leftImage != nil }

    var body: some View {
        VStack(spacing: 16) {
            header
            if isReviewing {
                review
            } else if camera.access == .ready {
                GeometryReader { geometry in
                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView {
                            VStack(spacing: 20) {
                                viewfinder.frame(height: 220)
                                captureControls
                            }
                        }
                    } else if geometry.size.width > geometry.size.height {
                        HStack(spacing: 20) {
                            viewfinder
                            ScrollView { captureControls }
                                .frame(width: min(320, geometry.size.width * 0.42))
                        }
                    } else {
                        VStack(spacing: 20) {
                            viewfinder
                            captureControls
                        }
                    }
                }
            } else {
                accessView
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .background(Color(red: 0.035, green: 0.055, blue: 0.065).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task {
            if !holdsAwakeLock {
                ScreenAwakeManager.shared.acquire()
                holdsAwakeLock = true
            }
            await camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await camera.start() }
            } else if phase == .background {
                camera.suspend()
            }
        }
        .onDisappear {
            camera.stop()
            if holdsAwakeLock {
                ScreenAwakeManager.shared.release()
                holdsAwakeLock = false
            }
        }
        .alert("Discard these photos?", isPresented: $showDiscardConfirmation) {
            Button("Discard photos", role: .destructive) { dismiss() }
            Button("Keep taking photos", role: .cancel) {}
        }
        .alert("Camera", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            Button("OK", role: .cancel) { camera.errorMessage = nil }
        } message: {
            Text(LocalizedStringKey(camera.errorMessage ?? ""))
        }
        .alert("Let's take a fresh pair", isPresented: $camera.restartNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Camera tracking was interrupted. Take the left photo again so the movement guide can start from the right place.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if isRight { showDiscardConfirmation = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Close camera")
            if dynamicTypeSize.isAccessibilitySize {
                Text(LocalizedStringKey(isReviewing ? "Review pair" : (isRight ? "Right photo" : "Left photo")))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer(minLength: 0)
                step("Left", number: 1, selected: !isRight, completed: isRight)
                step("Right", number: 2, selected: isRight && !isReviewing, completed: isReviewing)
                step("Review", number: 3, selected: isReviewing, completed: false)
                Spacer(minLength: 0)
            }
        }
    }

    private func step(_ title: LocalizedStringKey, number: Int, selected: Bool, completed: Bool) -> some View {
        VStack(spacing: 5) {
            Group {
                if completed { Image(systemName: "checkmark") } else { Text(number, format: .number) }
            }
            .font(.caption.weight(.bold))
            .frame(width: 26, height: 26)
            .foregroundStyle(selected || completed ? Color.black : Color.white.opacity(0.6))
            .background(selected || completed ? accent : .white.opacity(0.08), in: Circle())
            Text(title).font(.caption2.weight(selected ? .bold : .regular))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack {
                cameraBackground
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if showGhost, let left = camera.leftImage {
                    Image(decorative: left, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(0.22)
                        .allowsHitTesting(false)
                }
                // A quiet thirds grid helps preserve height without hiding the subject.
                Path { path in
                    for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                        path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                        path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                    }
                }
                .stroke(.white.opacity(0.25), lineWidth: 0.5)
                .allowsHitTesting(false)
                Image(systemName: "plus")
                    .font(.title3.weight(.ultraLight))
                    .shadow(color: .black, radius: 3)
                    .accessibilityHidden(true)
                VStack {
                    HStack {
                        Label(LocalizedStringKey(isRight ? "RIGHT VIEW" : "LEFT VIEW"), systemImage: "camera")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                        if isRight {
                            Button { showGhost.toggle() } label: {
                                Image(systemName: showGhost ? "square.on.square.fill" : "square.on.square")
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.5), in: Circle())
                            }
                            .accessibilityLabel("Left photo overlay")
                            .accessibilityValue(Text(LocalizedStringKey(showGhost ? "On" : "Off")))
                            .accessibilityIdentifier("stereoCameraOverlay")
                        }
                    }
                    Spacer()
                    if isRight, let left = camera.leftImage {
                        HStack {
                            Image(decorative: left, scale: 1)
                                .resizable().scaledToFill()
                                .frame(width: 40, height: 48).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("Left photo saved").font(.caption.weight(.medium))
                            Spacer()
                            if camera.isOnTarget {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                            }
                        }
                        .padding(10)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(12)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(camera.isOnTarget ? accent : .white.opacity(0.12), lineWidth: 2))
        }
        .frame(minHeight: 140)
    }

    @ViewBuilder private var cameraBackground: some View {
#if DEBUG && targetEnvironment(simulator)
        if StereoCameraFixture.isEnabled {
            Image(decorative: StereoCameraFixture.image(rightEye: isRight), scale: 1)
                .resizable().scaledToFill()
        } else {
            StereoCameraPreview(session: camera.session, onOrientation: camera.setOrientation)
        }
#else
        StereoCameraPreview(session: camera.session, onOrientation: camera.setOrientation)
#endif
    }

    private var captureControls: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(instructionTitle).font(.title2.bold()).multilineTextAlignment(.center)
                Text(instructionDetail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if isRight { movementGuide }
            if dynamicTypeSize.isAccessibilitySize {
                Button(action: camera.capture) {
                    Label(LocalizedStringKey(isRight ? "Take right photo" : "Take left photo"), systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                .disabled(!camera.canCapture)
                .accessibilityIdentifier("stereoCameraShutter")
                if isRight {
                    Button("Start over") { camera.retakePair() }
                        .font(.body).frame(minHeight: 44).disabled(camera.isCapturing)
                }
            } else {
                shutterControls
            }
        }
    }

    private var shutterControls: some View {
        HStack {
            Group {
                if isRight {
                    Button { camera.retakePair() } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise").font(.title3)
                            Text("Start over").font(.caption2)
                        }
                        .frame(minWidth: 70, minHeight: 52)
                    }
                    .disabled(camera.isCapturing)
                } else {
                    Text("1×").font(.subheadline.weight(.semibold)).frame(width: 70)
                }
            }
            Spacer()
            Button(action: camera.capture) {
                ZStack {
                    Circle().stroke(.white.opacity(camera.canCapture ? 1 : 0.3), lineWidth: 3)
                    Circle().fill(camera.canCapture ? accent : .white.opacity(0.2)).padding(7)
                    if camera.isCapturing { ProgressView().tint(.white) }
                    else { Image(systemName: "camera.fill").font(.system(size: 24)).foregroundStyle(camera.canCapture ? .black : .white.opacity(0.4)) }
                }
                .frame(width: 76, height: 76)
            }
            .disabled(!camera.canCapture)
            .accessibilityLabel(Text(LocalizedStringKey(isRight ? "Take right photo" : "Take left photo")))
            .accessibilityIdentifier("stereoCameraShutter")
            Spacer()
            Text(LocalizedStringKey(isRight ? "2 of 2" : "1 of 2"))
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6)).frame(width: 70)
        }
    }

    @ViewBuilder private var distanceReading: some View {
        if camera.tracking == .normal, let guide = camera.guide {
            Text("~\(max(0, Double(guide.horizontal * 100)), specifier: "%.1f") / 6.4 cm")
                .font(.caption.monospacedDigit().weight(.semibold))
        } else {
            Text("Finding position…").font(.caption)
        }
    }

    private var movementGuide: some View {
        VStack(spacing: 9) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey(camera.isOnTarget ? "On target" : "Sideways movement")).font(.caption.weight(.bold))
                    distanceReading
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text(LocalizedStringKey(camera.isOnTarget ? "ON TARGET" : "SIDEWAYS MOVEMENT")).font(.caption2.weight(.bold)).tracking(1.4)
                    Spacer()
                    distanceReading
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                    Capsule().fill(accent).frame(width: max(4, geometry.size.width * (camera.guide?.progress ?? 0)), height: 4)
                    Circle().stroke(accent.opacity(0.5), lineWidth: 2).frame(width: 22, height: 22)
                        .offset(x: geometry.size.width - 22)
                    Image(systemName: camera.isOnTarget ? "checkmark" : ((camera.guide?.horizontal ?? 0) > StereoCaptureGuide.targetDistance ? "arrow.left" : "arrow.right"))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 28, height: 28).background(accent, in: Circle())
                        .offset(x: (geometry.size.width - 28) * (camera.guide?.progress ?? 0))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 28)
            .environment(\.layoutDirection, .leftToRight)
            Text("Optional guide • keep the phone parallel")
                .font(.caption2).foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var instructionTitle: LocalizedStringKey {
        if !camera.orientationMatches { return "Keep the same orientation" }
        if isRight, camera.tracking != .normal { return "Line up with the first photo" }
        if camera.tracking != .normal { return "Find a steady view" }
        guard isRight, let guide = camera.guide else { return "Take the left photo" }
        if guide.angleDegrees > 3 { return "Keep the phone parallel" }
        if abs(guide.vertical) > 0.012 { return guide.vertical > 0 ? "Move slightly down" : "Move slightly up" }
        if abs(guide.forward) > 0.02 { return guide.forward > 0 ? "Move slightly forward" : "Move slightly back" }
        if guide.horizontal > StereoCaptureGuide.targetDistance + 0.01 { return "A little back to the left" }
        if guide.isReady { return "Hold still. Take the right photo." }
        return "Slide about 6.4 cm right"
    }

    private var instructionDetail: LocalizedStringKey {
        if !camera.orientationMatches { return "Rotate your phone back to the orientation of the left photo." }
        if isRight {
            return "Use the shadow to line up your view. The guide is optional; tap the shutter when you are ready."
        }
        switch camera.tracking {
        case .starting, .interrupted: return "Move slowly to help the camera find its position."
        case .movingTooFast: return "Slow down and hold your phone steady."
        case .needsDetail: return "Point at a well-lit scene with more detail. Avoid blank walls."
        case .normal: break
        }
        return "Choose a still subject at least 2 metres away. Hold your phone steady."
    }

    private var review: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(accent)
                    Text("Your stereo pair").font(.largeTitle.bold())
                    Text("Check that your subject stayed still and both photos are sharp.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                }
                HStack(alignment: .top, spacing: 12) {
                    reviewEye(camera.leftImage, title: "Left eye")
                    reviewEye(camera.rightImage, title: "Right eye")
                }
                .environment(\.layoutDirection, .leftToRight)
                Text("Left photo → left eye. Right photo → right eye.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                Button {
                    guard let pair = camera.pair else { return }
                    onComplete(pair)
                    dismiss()
                } label: {
                    Label("Create SBS photo", systemImage: "rectangle.split.2x1")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).controlSize(.large)
                .accessibilityIdentifier("createCameraSBS")
                HStack(spacing: 16) {
                    Button("Retake left & right") { camera.retakePair() }.frame(minHeight: 44)
                    Spacer()
                    Button("Retake right") { camera.retakeRight() }.frame(minHeight: 44).disabled(!camera.canRetakeRight)
                }
                .font(.subheadline).tint(.white).padding(.vertical, 8)
            }
            .padding(.vertical, 20)
        }
    }

    private func reviewEye(_ image: CGImage?, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Label(title, systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(accent)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var accessView: some View {
        Spacer()
        VStack(spacing: 18) {
            Image(systemName: camera.access == .denied ? "camera.fill" : "camera.viewfinder")
                .font(.system(size: 48, weight: .light)).foregroundStyle(accent)
            if camera.access == .preparing {
                ProgressView("Starting camera…")
            } else if camera.access == .denied {
                Text("Allow camera access").font(.title2.bold())
                Text("StereoShift uses your camera to take a left and right photo. Your photos stay on your device.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
            } else if camera.access == .unavailable {
                Text("Stereo Camera needs an iPhone or iPad with motion tracking.")
                    .multilineTextAlignment(.center)
                Text("You can still convert existing photos from the Photo tab.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Couldn't start the camera").font(.title2.bold())
                Text("Close other camera apps, then try again.").font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await camera.start() } }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
            }
        }
        Spacer()
    }
}

private struct StereoCameraPreview: UIViewRepresentable {
    let session: ARSession
    let onOrientation: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.session = session
        view.onOrientation = onOrientation
        view.automaticallyUpdatesLighting = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: ARSCNView {
        var onOrientation: ((UIInterfaceOrientation) -> Void)?
        private var previousOrientation: UIInterfaceOrientation?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let orientation = window?.windowScene?.interfaceOrientation,
                  orientation != previousOrientation else { return }
            previousOrientation = orientation
            DispatchQueue.main.async { [weak self] in self?.onOrientation?(orientation) }
        }
    }
}
