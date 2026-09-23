import UIKit

enum CommunityLinks {
    static let subreddit = URL(string: "https://www.reddit.com/r/StereoShift/")!

    /// Opens r/StereoShift in the Reddit app when it is installed (reddit.com claims `/r/*` as a
    /// universal link), otherwise in the default browser.
    @MainActor
    static func openSubreddit() {
        UIApplication.shared.open(subreddit, options: [.universalLinksOnly: true]) { openedInApp in
            guard !openedInApp else { return }
            UIApplication.shared.open(subreddit)
        }
    }
}
