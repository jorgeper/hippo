import UIKit

/// Receives the launch iOS makes when a background upload session has events for Hippo.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // The transport calls it on the main queue, where UIKit expects it.
        let completion = UncheckedCompletion(completionHandler)
        DropboxProvider.handleBackgroundEvents(identifier: identifier) {
            MainActor.assumeIsolated { completion.call() }
        }
    }
}

/// Carries UIKit's completion handler into the `@Sendable` closure the transport stores.
private struct UncheckedCompletion: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
