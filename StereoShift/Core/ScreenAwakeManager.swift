import Foundation
import UIKit

final class ScreenAwakeManager {
    static let shared = ScreenAwakeManager()

    private var activeLocks = 0

    private init() {}

    func acquire() {
        DispatchQueue.main.async {
            self.activeLocks += 1
            UIApplication.shared.isIdleTimerDisabled = self.activeLocks > 0
        }
    }

    func release() {
        DispatchQueue.main.async {
            self.activeLocks = max(0, self.activeLocks - 1)
            UIApplication.shared.isIdleTimerDisabled = self.activeLocks > 0
        }
    }
}
