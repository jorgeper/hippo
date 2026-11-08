import SwiftUI
import os

@main
struct HippoApp: App {
    private let startup: Result<AppEnvironment, StartupError>

    /// Messages are fixed strings only.
    nonisolated private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "launch")

    init() {
        startup = AppEnvironment.open(processKind: .app)
        if case .success(let environment) = startup {
            SyncScheduling.registerBackgroundTask(environment)
            Self.startLaunchRecovery(environment)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(startup: startup)
        }
    }

    /// Registers packages the index doesn't know yet (spec §4), clears day-old intake leftovers, and
    /// refreshes `diagnostics.json` so the store can be checked from the Mac with `make diagnostics`.
    private static func startLaunchRecovery(_ environment: AppEnvironment) {
        Task.detached {
            await BackgroundActivity.run(name: "launch-recovery") {
                do {
                    _ = try environment.store.recover()
                } catch {
                    log.error("\("recover_failed", privacy: .public)")
                }
                environment.intake.sweep(olderThan: 86_400, now: Date())
                do {
                    try environment.store.writeDiagnostics(appVersion: environment.producer.appVersion)
                } catch {
                    log.error("\("diagnostics_failed", privacy: .public)")
                }
            }
            await SyncScheduling.syncAfterLaunchRecovery(environment)
        }
    }
}
