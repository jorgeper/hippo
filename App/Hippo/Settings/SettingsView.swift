import SwiftUI
import CaptureCore
import LocalRepository
import SyncEngine
import HippoPresentation

/// Storage destination, sync status, location preference, local storage use and app version.
struct SettingsView: View {
    @State private var model: SettingsModel
    private let registry: ProviderRegistry
    private let coordinator: SyncCoordinator
    private let store: HippoStore

    @State private var confirmingSignOut = false
    @State private var confirmingUpload = false
    @State private var failed = false
    @State private var busy = false
    @State private var locationDenied = false
    /// Local mirror of the stored switches so a toggle moves at once.
    @State private var enrichmentOn: [FacetKind: Bool] = [:]
    @State private var stripesOn = LocationService.settings.showsLayerStripes
    #if DEBUG
    @State private var sampleMessage: String?
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// `onEnrichmentEnabled` runs when a kind is switched on, to backfill existing captures.
    init(store: HippoStore, registry: ProviderRegistry, coordinator: SyncCoordinator,
         onEnrichmentEnabled: @escaping @Sendable (FacetKind) async -> Void = { _ in }) {
        self.registry = registry
        self.store = store
        self.coordinator = coordinator
        _model = State(initialValue: SettingsModel(
            store: store, registry: registry, coordinator: coordinator, settings: LocationService.settings,
            requestLocationPermission: { await LocationService.shared.requestPermission() },
            onEnrichmentEnabled: onEnrichmentEnabled,
            isOnline: { EnrichmentScheduling.isOnline }))
    }

    var body: some View {
        Form {
            storageSection
            syncSection
            locationSection
            enrichmentSection
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
            #if DEBUG
                if destination.providerKind == "filesystem" {
                    Button("Write sample server enrichment") { writeSampleGold() }
                        .disabled(busy)
                }
            #endif
            } else if registry.providers.isEmpty {
                Text("No storage providers are available in this build yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(registry.providers, id: \.kind) { provider in
                    Button("Connect \(provider.displayName)") {
                        perform("settings-connect") { try await model.connect(provider) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("settings-connect-\(provider.kind)")
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            if usesDeveloperFolder {
                Text("Developer · debug builds only. Uploads stay on this iPhone.")
            }
            #if DEBUG
            if let sampleMessage { Text(sampleMessage) }
            #endif
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
        Section {
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
        } header: {
            Text("Sync")
        } footer: {
            if let summary = model.statusSummary { Text(summary) }
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

    // MARK: Enrichment

    @ViewBuilder private var enrichmentSection: some View {
        Section {
            ForEach(SettingsModel.enrichmentSwitches) { item in
                Toggle(item.title, isOn: Binding(
                    get: { enrichmentOn[item.kind] ?? model.isEnrichmentEnabled(item.kind) },
                    set: { value in
                        enrichmentOn[item.kind] = value
                        let model = model
                        Task {
                            await model.setEnrichment(item.kind, on: value)
                            enrichmentOn[item.kind] = nil
                        }
                    }))
            }
            Toggle("Show where details came from", isOn: Binding(
                get: { stripesOn },
                set: { value in
                    stripesOn = value
                    model.setShowsLayerStripes(value)
                }))
        } header: {
            Text("Enrichment")
        } footer: {
            Text("\(SettingsModel.enrichmentFooter) \(SettingsModel.layerStripesFooter)")
        }
    }

    #if DEBUG
    /// Writes a small server-layer enrichment for the newest capture into the developer folder, then
    /// syncs so the gold pull picks it up. Needs that capture to have synced there first.
    private func writeSampleGold() {
        let store = store, coordinator = coordinator
        Task {
            let wrote = await DevFolderProvider.writeSampleGold(store: store)
            sampleMessage = wrote ? nil : "Sync this capture first."
            if wrote { await SyncScheduling.runPass(coordinator, name: "debug-gold-sample") }
        }
    }
    #endif

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
