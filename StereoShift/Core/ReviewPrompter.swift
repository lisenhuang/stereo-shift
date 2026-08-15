import Foundation

/// Decides whether asking for an App Store review is worth it right now.
///
/// StoreKit silently drops requests past three per 365 days, so an ask is not free: one
/// spent at a forgettable moment is one that is no longer available at a good one. Every
/// rule below exists to keep the yearly budget for users who already like the app.
@MainActor
final class ReviewPrompter {
    static let shared = ReviewPrompter()

    /// Video is the paid feature and every export costs the user real minutes of waiting,
    /// so three finished videos already marks an invested user. A photo-based threshold
    /// would have to be far higher — a photo is a couple of seconds of effort.
    static let minimumVideoExports = 3

    static let cooldownDays = 90

    /// The system sheet can silently fail to present while a save confirmation or a share
    /// sheet is still animating, so call sites wait this long after the success settles.
    static let promptDelay: Duration = .seconds(1.5)

    /// Everything the decision depends on, so the rules can be exercised in isolation.
    struct Snapshot: Sendable {
        var successfulVideoExports: Int
        var lastPromptedVersion: String?
        var lastPromptedAt: Date?
        var currentVersion: String
        var now: Date
        var didPromptThisSession: Bool
    }

    private static let videoExportCountKey = "review_prompt_successful_video_exports"
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
        guard snapshot.successfulVideoExports >= minimumVideoExports else { return false }
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

    func recordSuccessfulVideoExport() {
        let count = userDefaults.integer(forKey: Self.videoExportCountKey)
        userDefaults.set(count + 1, forKey: Self.videoExportCountKey)
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
            successfulVideoExports: userDefaults.integer(forKey: Self.videoExportCountKey),
            lastPromptedVersion: userDefaults.string(forKey: Self.lastPromptedVersionKey),
            lastPromptedAt: storedTimestamp.map { Date(timeIntervalSince1970: $0) },
            currentVersion: currentVersion,
            now: now,
            didPromptThisSession: didPromptThisSession
        )
    }
}
