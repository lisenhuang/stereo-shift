#if DEBUG
import Foundation
import Testing
@testable import StereoShift

@MainActor
struct DebugPaidAccessTests {
    @Test func overrideSurvivesRefreshWithoutPersistingPaidState() async throws {
        let suite = "DebugPaidAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SubscriptionManager(productIDs: [], userDefaults: defaults)
        await manager.refreshEntitlements()
        #expect(!manager.canAccessVideo)

        manager.enableDebugPaidAccessForSession()
        #expect(manager.canAccessVideo)
        #expect(manager.isDebugPaidAccessEnabled)
        await manager.refreshEntitlements()
        #expect(manager.canAccessVideo)
        #expect(!manager.isSubscribed)
        #expect(!defaults.bool(forKey: "cached_video_subscription_state"))
        #expect(!defaults.bool(forKey: "has_ever_subscribed_to_video"))

        let freshManager = SubscriptionManager(productIDs: [], userDefaults: defaults)
        await freshManager.refreshEntitlements()
        #expect(!freshManager.isDebugPaidAccessEnabled)
        #expect(!freshManager.canAccessVideo)
    }
}
#endif
