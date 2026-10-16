import SwiftUI

struct RedditPostButton: View {
    var body: some View {
        Button(action: CommunityLinks.openPostComposer) {
            HStack {
                Image("RedditIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                Text("Post to r/StereoShift")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
