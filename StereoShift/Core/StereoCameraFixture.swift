#if DEBUG && targetEnvironment(simulator)
import UIKit

/// Simulator-only fixtures exercise the capture UI without a camera or AR hardware.
enum StereoCameraFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["STEREOSHIFT_CAMERA_FIXTURE"] == "1" }

    static var isOffTarget: Bool { ProcessInfo.processInfo.environment["STEREOSHIFT_CAMERA_OFF_TARGET"] == "1" }
    static var hasLimitedTracking: Bool { ProcessInfo.processInfo.environment["STEREOSHIFT_CAMERA_LIMITED_TRACKING"] == "1" }

    static func image(rightEye: Bool) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 750, height: 1000))
        return renderer.image { context in
            let canvas = context.cgContext
            UIColor(red: 0.58, green: 0.73, blue: 0.79, alpha: 1).setFill()
            canvas.fill(CGRect(x: 0, y: 0, width: 750, height: 1000))
            UIColor(red: 0.25, green: 0.39, blue: 0.38, alpha: 1).setFill()
            canvas.move(to: CGPoint(x: 0, y: 660))
            canvas.addLine(to: CGPoint(x: 380, y: 270))
            canvas.addLine(to: CGPoint(x: 750, y: 660))
            canvas.addLine(to: CGPoint(x: 750, y: 1000))
            canvas.addLine(to: CGPoint(x: 0, y: 1000))
            canvas.fillPath()
            UIColor(red: 0.68, green: 0.72, blue: 0.49, alpha: 1).setFill()
            canvas.fill(CGRect(x: 0, y: 750, width: 750, height: 250))
            UIColor(red: 0.91, green: 0.69, blue: 0.46, alpha: 1).setFill()
            canvas.fill(CGRect(x: rightEye ? 260 : 285, y: 610, width: 170, height: 190))
            UIColor(red: 0.18, green: 0.27, blue: 0.27, alpha: 1).setFill()
            canvas.move(to: CGPoint(x: rightEye ? 235 : 260, y: 615))
            canvas.addLine(to: CGPoint(x: rightEye ? 345 : 370, y: 525))
            canvas.addLine(to: CGPoint(x: rightEye ? 455 : 480, y: 615))
            canvas.fillPath()
        }.cgImage!
    }
}
#endif
