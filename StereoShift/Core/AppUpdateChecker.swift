import Combine
import Foundation

struct AvailableAppUpdate: Equatable, Sendable {
    let version: String
    let storeURL: URL
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    nonisolated static let appStoreID = "6759077023"
    nonisolated static let listingURL = URL(string: "https://apps.apple.com/app/id6759077023")!

    @Published private(set) var availableUpdate: AvailableAppUpdate?

    private let userDefaults: UserDefaults
    private let bundle: Bundle
    private let session: URLSession

    nonisolated private static let lastCheckDateKey = "app_update_last_check_date"
    nonisolated private static let lastOfferedVersionKey = "app_update_last_offered_version"
    nonisolated private static let minimumCheckInterval: TimeInterval = 24 * 60 * 60
    nonisolated private static let requestTimeout: TimeInterval = 8

    init(userDefaults: UserDefaults = .standard, bundle: Bundle = .main, session: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.bundle = bundle
        self.session = session
    }

    /// Best-effort App Store version check. Every failure path is silent: a missing
    /// update must never surface an error or delay the UI.
    func check(force: Bool = false) async {
        guard let installedVersion else { return }
        let now = Date()
        guard force || shouldCheck(at: now) else { return }
        guard let url = Self.lookupURL(now: now) else { return }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let payload = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            guard let result = payload.results.first else { return }

            // Only a completed round trip arms the throttle, so a flaky network retries next launch.
            userDefaults.set(now, forKey: Self.lastCheckDateKey)

            let storeVersion = result.version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !storeVersion.isEmpty else { return }
            guard installedVersion.compare(storeVersion, options: .numeric) == .orderedAscending else { return }
            guard userDefaults.string(forKey: Self.lastOfferedVersionKey) != storeVersion else { return }

            let storeURL = result.trackViewUrl.flatMap(URL.init(string:)) ?? Self.listingURL
            availableUpdate = AvailableAppUpdate(version: storeVersion, storeURL: storeURL)
        } catch {
            // Offline, timed out, or a payload we cannot read: stay quiet.
        }
    }

    /// Remembers the offered version so the same one never prompts twice; a higher one still will.
    func dismiss() {
        guard let update = availableUpdate else { return }
        userDefaults.set(update.version, forKey: Self.lastOfferedVersionKey)
        availableUpdate = nil
    }

    private var installedVersion: String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shouldCheck(at date: Date) -> Bool {
        guard let lastCheck = userDefaults.object(forKey: Self.lastCheckDateKey) as? Date else { return true }
        let elapsed = date.timeIntervalSince(lastCheck)
        // A negative elapsed time means the clock moved backwards; treat the throttle as expired.
        return elapsed < 0 || elapsed >= Self.minimumCheckInterval
    }

    nonisolated private static func lookupURL(now: Date) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var queryItems = [URLQueryItem(name: "id", value: appStoreID)]
        // Storefronts publish independently, so ask the user's own country for the truth.
        if let region = Locale.current.region?.identifier, region.count == 2 {
            queryItems.append(URLQueryItem(name: "country", value: region))
        }
        // This endpoint is cached hard by every layer in between; a unique URL defeats that.
        queryItems.append(URLQueryItem(name: "t", value: String(Int(now.timeIntervalSince1970))))
        components?.queryItems = queryItems
        return components?.url
    }
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let version: String
    let trackViewUrl: String?
}
