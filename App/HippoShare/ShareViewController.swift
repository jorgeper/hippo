import UIKit

/// Placeholder Share Extension: accepts the share and finishes at once, saving nothing yet.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
