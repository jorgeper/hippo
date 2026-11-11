import SwiftUI
import os
import LocalRepository

@main
struct HippoApp: App {
    /// Forwards background upload-session events to the Dropbox provider.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let startup: Result<AppEnvironment, StartupError>

    /// Messages are fixed strings only.
    nonisolated private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "launch")

    init() {
        startup = AppEnvironment.open(processKind: .app)
        ContextReader.startBatteryMonitoring()
        if case .success(let environment) = startup {
            SyncScheduling.registerBackgroundTask(environment)
            SyncScheduling.startConnectivityTrigger(environment)
            Self.startLaunchRecovery(environment)
        } else {
            SyncScheduling.registerBackgroundTask(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(startup: startup)
        }
    }

    /// Registers packages the index doesn't know yet (spec §4), clears day-old intake leftovers, and
    /// refreshes `diagnostics.json` so the store can be checked from the Mac with `make diagnostics`.
    /// Then syncs, then runs enrichment.
    private static func startLaunchRecovery(_ environment: AppEnvironment) {
        let info = Bundle.main.infoDictionary ?? [:]
        let release = "\(info["CFBundleShortVersionString"] as? String ?? "0")-\(info["CFBundleVersion"] as? String ?? "0")"
        Task.detached {
            environment.store.log.append(LogEvent(event: .appLaunch, code: Diagnostics.safeCode(release)))
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
            environment.store.log.prune()
            await SyncScheduling.syncAfterLaunchRecovery(environment)
            // Enrichment waits for recovery (which sweeps enrichment staging) and the first sync, then
            // backfills anything not yet enriched, newest first.
            await EnrichmentScheduling.markLaunchRecovered()
            await EnrichmentScheduling.run(environment, reason: "launch")
        }
    }
}
