import UIKit

@MainActor
enum ContainingAppLauncher {
    /// Experimental, user-requested handoff. UIKit does not promise that a Share
    /// Extension's responder chain exposes UIApplication. Keep a visible fallback
    /// and do not treat a successful build as proof this works on a device.
    static func open(_ url: URL, from controller: UIViewController, completion: @escaping (Bool) -> Void) {
        var responder: UIResponder? = controller
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: completion)
                return
            }
            responder = current.next
        }
        completion(false)
    }
}
