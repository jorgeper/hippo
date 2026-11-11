import CoreLocation
import Foundation
import os
import CaptureCore
import SyncEngine
import ShareIntake
import HippoPresentation
#if !HIPPO_SHARE_EXTENSION
import DropboxAdapter
#endif

/// Which process opened the environment. Both open the same store in the App Group.
enum ProcessKind: Sendable {
    case app
    case shareExtension
}

enum StartupError: Error, Sendable, Equatable {
    /// The App Group container is missing, which means the install's signing or entitlements are wrong.
    case appGroupUnavailable
    /// The store's directories or database could not be created or opened.
    case storeUnavailable

    /// Shown instead of the app's screens; startup never crashes.
    var message: String {
        switch self {
        case .appGroupUnavailable: "Hippo can't open its storage. Reinstall with `make device`."
        case .storeUnavailable: "Hippo couldn't open its captures database. Try restarting the app."
        }
    }
}

/// Everything a process needs to read and write captures: the shared store and the intake directory,
/// both under `<App Group container>/Library/Application Support/Hippo/`.
struct AppEnvironment: Sendable {
    static let appGroupID = "group.com.jorgeper.hippo"

    let processKind: ProcessKind
    let storeRoot: URL
    let producer: Producer
    let store: HippoStore
    let intake: IntakeDirectory
    /// Storage providers and the sync coordinator exist in the app process only; the Share Extension
    /// never syncs, so both are nil there.
    let registry: ProviderRegistry?
    let coordinator: SyncCoordinator?

    /// Messages are fixed strings only: never paths or error descriptions.
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "startup")

    static func open(processKind: ProcessKind) -> Result<AppEnvironment, StartupError> {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            log.error("\("app_group_unavailable", privacy: .public)")
            return .failure(.appGroupUnavailable)
        }
        let storeRoot = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Hippo", isDirectory: true)

        #if DEBUG
        // UI tests launch the app with `-HippoResetStore YES` to start from an empty store.
        if processKind == .app, UserDefaults.standard.bool(forKey: "HippoResetStore") {
            try? fm.removeItem(at: storeRoot)
            try? fm.removeItem(at: storeRoot.deletingLastPathComponent()
                .appendingPathComponent("HippoDevRemote", isDirectory: true))
        }
        #endif

        let producer = currentProducer()
        do {
            let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            let intakeRoot = storeRoot.appendingPathComponent("intake", isDirectory: true)
            for dir in [storeRoot, intakeRoot] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: protection)
            }
            let store = try HippoStore.open(root: storeRoot, producer: producer,
                                          process: processKind == .shareExtension ? .share : .app,
                                            context: captureContextHooks())
            #if HIPPO_SHARE_EXTENSION
            let providers: [any StorageProvider] = []
            #else
            let providers = processKind == .app ? appProviders(storeRoot: storeRoot) : []
            #endif
            let registry = processKind == .app ? ProviderRegistry(providers) : nil
            let coordinator = registry.map {
                SyncCoordinator(store: store, registry: $0, ownerPrefix: "app", appVersion: producer.appVersion,
                                settings: LocationService.settings,
                                isConstrained: { NetworkStatus.shared.isExpensive })
            }
            return .success(AppEnvironment(processKind: processKind, storeRoot: storeRoot, producer: producer,
                                           store: store, intake: IntakeDirectory(storeRoot: storeRoot),
                                           registry: registry, coordinator: coordinator))
        } catch {
            log.error("\("store_open_failed", privacy: .public)")
            return .failure(.storeUnavailable)
        }
    }

    /// Both processes read the same App Group settings. Location authorization is read, never requested.
    private static func captureContextHooks() -> CaptureContextHooks {
        CaptureContextHooks(
            enabledGroups: {
                let settings = LocationService.settings
                let status = CLLocationManager().authorizationStatus
                let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
                return (settings.deviceContextEnabled, settings.locationEnabled && authorized)
            },
            lastSaved: { LocationService.settings.lastSaved },
            recordSaved: { LocationService.settings.lastSaved = $0 })
    }

    #if !HIPPO_SHARE_EXTENSION
    /// Dropbox first (absent when the build has no app key, i.e. no `Config/Secrets.xcconfig`), then the
    /// Developer folder in debug builds.
    private static func appProviders(storeRoot: URL) -> [any StorageProvider] {
        var providers: [any StorageProvider] = []
        if let dropbox = DropboxProvider(appKey: Bundle.main.infoDictionary?["HippoDropboxAppKey"] as? String ?? "",
                                         storeRoot: storeRoot, accessGroup: KeychainTokenStore.sharedAccessGroup()) {
            providers.append(dropbox)
        }
        #if DEBUG
        providers.append(DevFolderProvider())
        #endif
        return providers
    }
    #endif

    /// App version and build from this bundle's Info.plist (the app and extension share them), and the
    /// OS version as major.minor.patch.
    private static func currentProducer() -> Producer {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Producer(appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
                        build: info["CFBundleVersion"] as? String ?? "0",
                        osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}
