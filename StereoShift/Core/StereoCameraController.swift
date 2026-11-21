import ARKit
import AVFoundation
import Combine
import UIKit

@MainActor
final class StereoCameraController: NSObject, ObservableObject {
    enum Access { case preparing, ready, denied, unavailable, failed }
    enum Tracking { case starting, normal, movingTooFast, needsDetail, interrupted }

    let session = ARSession()
    @Published private(set) var access: Access = .preparing
    @Published private(set) var tracking: Tracking = .starting
    @Published private(set) var leftImage: CGImage?
    @Published private(set) var rightImage: CGImage?
    @Published private(set) var guide: StereoCaptureGuide?
    @Published private(set) var isCapturing = false
    @Published private(set) var orientationMatches = true
    @Published var errorMessage: String?
    @Published var restartNotice = false

    private var firstPose: simd_float4x4?
    private var cameraToScreen = matrix_identity_float4x4
    private var firstOrientation: UIInterfaceOrientation?
    private var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var configuration: ARWorldTrackingConfiguration?
    private var generation = UUID()
    private var isActive = false
    private var lastUpdate: TimeInterval = 0
    private var wasReady = false
    private var shouldResumeAfterInterruption = false

    var canRetakeRight: Bool { isActive && firstPose != nil }

    var pair: StereoImagePair? {
        guard let leftImage, let rightImage else { return nil }
        return StereoImagePair(left: leftImage, right: rightImage)
    }

    var canCapture: Bool {
        isActive && access == .ready && !isCapturing && rightImage == nil && orientationMatches
            && (leftImage == nil ? tracking == .normal : tracking != .interrupted)
    }

    // Alignment is guidance only; the right shutter remains available off target.
    var isOnTarget: Bool {
        leftImage != nil && tracking == .normal && orientationMatches && guide?.isReady == true
    }

    override init() {
        super.init()
        session.delegate = self
    }

    func start() async {
        guard !isActive, pair == nil else { return }
        isActive = true
        access = .preparing
        let token = generation
#if DEBUG && targetEnvironment(simulator)
        if StereoCameraFixture.isEnabled {
            access = .ready
            tracking = .normal
            return
        }
#endif
        guard ARWorldTrackingConfiguration.isSupported else {
            access = .unavailable
            isActive = false
            return
        }
        let authorised: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorised = true
        case .notDetermined: authorised = await AVCaptureDevice.requestAccess(for: .video)
        default: authorised = false
        }
        guard token == generation, isActive else { return }
        guard authorised else {
            access = .denied
            isActive = false
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        configuration.isAutoFocusEnabled = true
        self.configuration = configuration
        tracking = .starting
        lastUpdate = 0
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        access = .ready
    }

    func setOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown else { return }
        interfaceOrientation = orientation
        orientationMatches = firstOrientation == nil || firstOrientation == orientation
    }

    func capture() {
        guard canCapture else { return }
#if DEBUG && targetEnvironment(simulator)
        if StereoCameraFixture.isEnabled {
            if leftImage == nil {
                leftImage = StereoCameraFixture.image(rightEye: false)
                firstPose = matrix_identity_float4x4
                var target = matrix_identity_float4x4
                target.columns.3.x = StereoCameraFixture.isOffTarget ? 0.025 : StereoCaptureGuide.targetDistance
                target.columns.3.y = StereoCameraFixture.isOffTarget ? 0.04 : 0
                guide = StereoCaptureGuide(origin: matrix_identity_float4x4, current: target)
                if StereoCameraFixture.hasLimitedTracking { tracking = .needsDetail }
            } else {
                rightImage = StereoCameraFixture.image(rightEye: true)
            }
            return
        }
#endif
        isCapturing = true
        let token = generation
        let orientation = interfaceOrientation
        let isLeft = leftImage == nil
        if isLeft { setCameraLocked(true) }
        Task {
            do {
                let frame = try await session.captureHighResolutionFrame()
                guard token == generation, isActive else { return }
                guard orientation == interfaceOrientation else {
                    isCapturing = false
                    if isLeft { setCameraLocked(false) }
                    errorMessage = "Keep the same orientation and try again."
                    return
                }
                let pose = simd_inverse(frame.camera.viewMatrix(for: orientation))
                // The first pose anchors the guide; later tracking accuracy must not block a photo.
                if isLeft {
                    guard case .normal = frame.camera.trackingState else {
                        isCapturing = false
                        setCameraLocked(false)
                        errorMessage = "Hold your phone steady and try the left photo again."
                        return
                    }
                }
                let buffer = frame.capturedImage
                let image = try await Task.detached(priority: .userInitiated) {
                    try StereoCaptureImage.makeImage(from: buffer, orientation: orientation)
                }.value
                guard token == generation, isActive else { return }
                if isLeft {
                    leftImage = image
                    firstPose = pose
                    cameraToScreen = simd_inverse(frame.camera.transform) * pose
                    firstOrientation = orientation
                    guide = StereoCaptureGuide(origin: pose, current: pose)
                } else {
                    rightImage = image
                    session.pause()
                }
                isCapturing = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch {
                guard token == generation else { return }
                isCapturing = false
                if isLeft { setCameraLocked(false) }
                errorMessage = "Couldn't take the photo. Hold still and try again."
            }
        }
    }

    func retakeRight() {
#if DEBUG && targetEnvironment(simulator)
        if StereoCameraFixture.isEnabled { rightImage = nil; return }
#endif
        guard let configuration, canRetakeRight else { return }
        rightImage = nil
        guide = nil
        tracking = .starting
        wasReady = false
        session.run(configuration)
    }

    func retakePair() {
        generation = UUID()
        leftImage = nil
        rightImage = nil
        firstPose = nil
        firstOrientation = nil
        guide = nil
        isCapturing = false
        orientationMatches = true
        wasReady = false
        setCameraLocked(false)
#if DEBUG && targetEnvironment(simulator)
        if StereoCameraFixture.isEnabled { tracking = .normal; return }
#endif
        if let configuration, isActive {
            tracking = .starting
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            Task { await start() }
        }
    }

    func suspend() {
        guard isActive else { return }
        // A partial pair must never survive a tracking-coordinate reset.
        if leftImage != nil, rightImage == nil {
            retakePair()
            restartNotice = true
        }
        stop()
    }

    func stop() {
        shouldResumeAfterInterruption = false
        generation = UUID()
        isActive = false
        isCapturing = false
        setCameraLocked(false)
        session.pause()
    }

    private func setCameraLocked(_ locked: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let focus: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
            let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
            let balance: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
            if device.isFocusModeSupported(focus) { device.focusMode = focus }
            if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
            if device.isWhiteBalanceModeSupported(balance) { device.whiteBalanceMode = balance }
        } catch {
            // Tracking and capture remain usable when a device cannot lock its settings.
        }
    }

    private func update(pose: simd_float4x4, state: ARCamera.TrackingState, time: TimeInterval) {
        guard isActive, rightImage == nil, time - lastUpdate >= 0.08 else { return }
        lastUpdate = time
        switch state {
        case .normal: tracking = .normal
        case .notAvailable: tracking = .starting
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: tracking = .movingTooFast
            case .insufficientFeatures: tracking = .needsDetail
            default: tracking = .starting
            }
        }
        if let firstPose {
            // viewMatrix(for:) includes the screen rotation. Apply the same rotation to
            // every pose so rightward movement remains rightward in portrait and landscape.
            guide = StereoCaptureGuide(origin: firstPose, current: pose * cameraToScreen)
        }
        let ready = isOnTarget
        if ready && !wasReady { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        wasReady = ready
    }
}

extension StereoCameraController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pose = frame.camera.transform
        let state = frame.camera.trackingState
        let time = frame.timestamp
        Task { @MainActor [weak self] in self?.update(pose: pose, state: state, time: time) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            self.suspend()
            self.shouldResumeAfterInterruption = true
            self.tracking = .interrupted
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            guard let self, self.shouldResumeAfterInterruption,
                  UIApplication.shared.applicationState == .active else { return }
            self.shouldResumeAfterInterruption = false
            await self.start()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            self.suspend()
            self.access = .failed
        }
    }
}
