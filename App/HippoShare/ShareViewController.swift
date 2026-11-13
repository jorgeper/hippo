import SwiftUI
import UIKit
import ShareIntake
import HippoPresentation

/// Hosts the share sheet. The extension commits the capture before it calls `completeRequest`, never
/// syncs, never shows sign-in UI and requests a fresh fix but never waits for it.
final class ShareViewController: UIViewController {
    /// Exactly one of `completeRequest` / `cancelRequest` runs, once.
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let host: UIViewController
        switch AppEnvironment.open(processKind: .shareExtension) {
        case .failure(let error):
            host = UIHostingController(rootView: ShareStartupFailureView(message: error.message) { [weak self] in
                self?.cancelRequest()
            })
        case .success(let environment):
            LocationService.shared.beginSessionFix()
            let input = ShareInput.from(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            // A store read error means "no destination": the sheet then says it only saves on the iPhone.
            let destinationName = (try? environment.store.destinations.active())?.displayName
            let model = ShareSessionModel(
                store: environment.store, intake: environment.intake, input: input, destinationName: destinationName,
                location: { LocationService.shared.location(startedAt: $0) })
            host = UIHostingController(rootView: CaptureSheetView(
                model: model,
                voice: nil,
                save: { acceptPartial in
                    await BackgroundActivity.run(name: "share-save") { await model.save(acceptPartial: acceptPartial) }
                },
                cancel: { [weak self] in
                    model.cancel()
                    self?.cancelRequest()
                },
                finish: { [weak self] in
                    guard let self, !finished else { return }
                    finished = true
                    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }))
        }

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func cancelRequest() {
        guard !finished else { return }
        finished = true
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

/// Shown instead of the sheet when the shared store can't be opened.
struct ShareStartupFailureView: View {
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Hippo").font(.headline)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close", action: close).buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
