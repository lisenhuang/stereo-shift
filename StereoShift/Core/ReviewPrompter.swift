import Foundation

/// Requests a review after three successful paid photo or video saves/shares.
@MainActor
final class ReviewPrompter {
    static let shared = ReviewPrompter()
    static let minimumExports = 3

    static let cooldownDays = 90

    /// The system sheet can silently fail to present while a save confirmation or a share
    /// sheet is still animating, so call sites wait this long after the success settles.
    static let promptDelay: Duration = .seconds(1.5)

    /// Everything the decision depends on, so the rules can be exercised in isolation.
    struct Snapshot: Sendable {
        var successfulExports: Int
        var lastPromptedVersion: String?
        var lastPromptedAt: Date?
        var currentVersion: String
        var now: Date
        var didPromptThisSession: Bool
    }

    private static let exportCountKey = "review_prompt_successful_video_exports"
    private static let lastPromptedVersionKey = "review_prompt_last_version"
    private static let lastPromptedAtKey = "review_prompt_last_date"

    private let userDefaults: UserDefaults
    private let currentVersion: String
    private var didPromptThisSession = false

    init(userDefaults: UserDefaults = .standard, currentVersion: String? = nil) {
        self.userDefaults = userDefaults
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
    }

    static func shouldPrompt(for snapshot: Snapshot) -> Bool {
        guard !snapshot.didPromptThisSession else { return false }
        guard snapshot.successfulExports >= minimumExports else { return false }
        // A new release is a fresh, legitimate opportunity; the same one is not.
        guard snapshot.lastPromptedVersion != snapshot.currentVersion else { return false }

        guard let lastPromptedAt = snapshot.lastPromptedAt else { return true }
        // A clock moved backwards (manually, or by restoring onto a skewed device) would
        // otherwise park the user behind a cooldown that never elapses.
        guard lastPromptedAt <= snapshot.now else { return true }

        let cooldown = Double(cooldownDays) * 24 * 60 * 60
        return snapshot.now.timeIntervalSince(lastPromptedAt) >= cooldown
    }

    var shouldPromptNow: Bool {
        Self.shouldPrompt(for: snapshot())
    }

    func recordSuccessfulExport(isPaidUser: Bool) {
        guard isPaidUser else { return }
        let count = userDefaults.integer(forKey: Self.exportCountKey)
        userDefaults.set(count + 1, forKey: Self.exportCountKey)
    }

    /// Call this immediately before presenting: StoreKit never reports back whether the
    /// sheet actually appeared, so a request has to be treated as spent either way.
    func recordPromptShown(at date: Date = Date()) {
        didPromptThisSession = true
        userDefaults.set(currentVersion, forKey: Self.lastPromptedVersionKey)
        userDefaults.set(date.timeIntervalSince1970, forKey: Self.lastPromptedAtKey)
    }

    private func snapshot(now: Date = Date()) -> Snapshot {
        let storedTimestamp = userDefaults.object(forKey: Self.lastPromptedAtKey) as? Double
        return Snapshot(
            successfulExports: userDefaults.integer(forKey: Self.exportCountKey),
            lastPromptedVersion: userDefaults.string(forKey: Self.lastPromptedVersionKey),
            lastPromptedAt: storedTimestamp.map { Date(timeIntervalSince1970: $0) },
            currentVersion: currentVersion,
            now: now,
            didPromptThisSession: didPromptThisSession
        )
    }
}
