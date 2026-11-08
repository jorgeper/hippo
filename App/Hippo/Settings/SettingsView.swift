import SwiftUI
import LocalRepository
import SyncEngine
import HippoPresentation

/// Storage destination, sync status, location preference, local storage use and app version.
struct SettingsView: View {
    @State private var model: SettingsModel
    private let registry: ProviderRegistry
    private let coordinator: SyncCoordinator

    @State private var confirmingSignOut = false
    @State private var confirmingUpload = false
    @State private var failed = false
    @State private var busy = false
    @State private var locationDenied = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(store: HippoStore, registry: ProviderRegistry, coordinator: SyncCoordinator) {
        self.registry = registry
        self.coordinator = coordinator
        _model = State(initialValue: SettingsModel(
            store: store, registry: registry, coordinator: coordinator, settings: LocationService.settings,
            requestLocationPermission: { await LocationService.shared.requestPermission() }))
    }

    var body: some View {
        Form {
            storageSection
            syncSection
            locationSection
            onThisPhoneSection
            aboutSection
        }
        .navigationTitle("Settings")
        .task {
            await model.refresh()
            await reconcileLocation()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.refresh()
                await reconcileLocation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncCoordinator.passFinished)) { _ in
            Task {
                await model.refresh()
                await reconcileLocation()
            }
        }
        .alert("Something went wrong", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Hippo couldn't finish that. Your captures are safe on this iPhone.")
        }
    }

    // MARK: Storage

    @ViewBuilder private var storageSection: some View {
        let destination = model.activeDestination
        Section {
            if let destination {
                if providerName(destination) == destination.displayName {
                    Text(destination.displayName)
                } else {
                    LabeledContent(destination.displayName, value: providerName(destination))
                }
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .disabled(busy)
                    .confirmationDialog("Sign out of \(destination.displayName)? Captures stay on this iPhone; uploads pause until you sign in again.",
                                        isPresented: $confirmingSignOut, titleVisibility: .visible) {
                        Button("Sign out", role: .destructive) { perform("settings-sign-out") { try await model.signOut() } }
                    }
            } else if registry.providers.isEmpty {
                Text("No storage providers are available in this build yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(registry.providers, id: \.kind) { provider in
                    Button("Connect \(provider.displayName)") {
                        perform("settings-connect") { try await model.connect(provider) }
                    }
                    .disabled(busy)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            if usesDeveloperFolder {
                Text("Developer · debug builds only. Uploads stay on this iPhone.")
            }
        }
    }

    private var usesDeveloperFolder: Bool {
        if let kind = model.activeDestination?.providerKind { return kind == "filesystem" }
        return registry.providers.contains { $0.kind == "filesystem" }
    }

    private func providerName(_ d: Destination) -> String {
        registry.provider(kind: d.providerKind)?.displayName ?? d.providerKind
    }

    // MARK: Sync

    @ViewBuilder private var syncSection: some View {
        Section("Sync") {
            HStack {
                Text(model.summary)
                if busy {
                    Spacer()
                    ProgressView()
                }
            }
            Button("Retry now") { perform("settings-retry") { try await model.retryAll() } }
                .disabled(busy)
            if let destination = model.activeDestination {
                Button("Upload existing captures to \(destination.displayName)…") { confirmingUpload = true }
                    .disabled(busy)
                    .confirmationDialog("Hippo will upload every capture on this iPhone to \(destination.displayName). Copies already uploaded elsewhere stay where they are.",
                                        isPresented: $confirmingUpload, titleVisibility: .visible) {
                        Button("Upload existing captures") {
                            perform("settings-upload-existing") { _ = try await model.uploadExisting() }
                        }
                    }
            }
        }
    }

    // MARK: Location

    @ViewBuilder private var locationSection: some View {
        Section {
            Toggle("Save location with captures", isOn: Binding(
                get: { model.locationEnabled && !locationDenied },
                set: { on in
                    Task {
                        await model.setLocationEnabled(on)
                        locationDenied = LocationService.shared.isDenied
                    }
                }))
            if locationDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } header: {
            Text("Location")
        } footer: {
            if locationDenied {
                Text("Location is turned off for Hippo in iOS Settings.")
            } else {
                Text("Uses your location only at the moment you save. Never in the background.")
            }
        }
    }

    /// A denied iOS permission shows as off: the stored preference is cleared to match.
    private func reconcileLocation() async {
        locationDenied = LocationService.shared.isDenied
        if locationDenied && model.locationEnabled { await model.setLocationEnabled(false) }
    }

    // MARK: On this iPhone / About

    private var onThisPhoneSection: some View {
        Section("On this iPhone") {
            LabeledContent("Storage used",
                           value: ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file))
            LabeledContent("Captures", value: model.counts.values.reduce(0, +).formatted())
        }
    }

    private var aboutSection: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return Section {
            Text("Version \(version) (\(build))")
        } footer: {
            Text("Hippo installs from Xcode expire after 7 days. Reinstalling keeps your captures.")
        }
    }

    // MARK: Actions

    /// Runs `action` inside a background assertion that stops syncing if time runs out; failures show
    /// one fixed alert.
    private func perform(_ name: String, _ action: @escaping @MainActor @Sendable () async throws -> Void) {
        guard !busy else { return }
        busy = true
        let coordinator = coordinator
        Task {
            defer { busy = false }
            do {
                try await BackgroundActivity.run(name: name, onExpire: SyncScheduling.stopper(coordinator)) {
                    try await action()
                }
            } catch {
                failed = true
            }
        }
    }
}
