import UIKit

enum CommunityLinks {
    static let subreddit = URL(string: "https://www.reddit.com/r/StereoShift/")!

    static let submission = subreddit.appendingPathComponent("submit")

    @MainActor
    static func openPostComposer() {
        openInRedditOrBrowser(submission)
    }

    /// Opens r/StereoShift in the Reddit app when it is installed (reddit.com claims `/r/*` as a
    /// universal link), otherwise in the default browser.
    @MainActor
    static func openSubreddit() {
        openInRedditOrBrowser(subreddit)
    }

    @MainActor
    private static func openInRedditOrBrowser(_ url: URL) {
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { openedInApp in
            guard !openedInApp else { return }
            UIApplication.shared.open(url)
        }
    }
}
