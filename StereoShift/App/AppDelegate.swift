#if canImport(UIKit)
import UIKit

/// UIKit delegate bridged into the SwiftUI app so background `URLSession` launch
/// events (depth model downloads finishing while the app is gone) reach the downloader.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Completion handler the system expects back once the session's events have
    /// been delivered. Kept here in case the store is created after the callback;
    /// the shared downloader receives it directly as well.
    @MainActor static var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DepthModelDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundSessionCompletionHandler = completionHandler
        // Touching `shared` recreates the session, which makes it deliver the pending
        // events; the downloader calls the handler once they are all in.
        DepthModelDownloader.shared.handleBackgroundSessionEvents {
            // The downloader invokes this on the main thread.
            MainActor.assumeIsolated {
                Self.backgroundSessionCompletionHandler = nil
            }
            completionHandler()
        }
    }
}
#endif
