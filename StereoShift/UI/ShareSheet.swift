import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = completionHandler
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        _ = context
        // Re-attach so a re-render does not leave the controller holding a stale closure.
        uiViewController.completionWithItemsHandler = completionHandler
    }

    private var completionHandler: UIActivityViewController.CompletionWithItemsHandler {
        { _, completed, _, _ in
            // UIKit reports `completed == false` when the sheet was merely dismissed.
            onComplete?(completed)
        }
    }
}
