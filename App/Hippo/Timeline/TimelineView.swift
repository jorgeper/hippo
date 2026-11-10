import SwiftUI
import HippoPresentation
import Enrichment

struct TimelineView: View {
    let environment: AppEnvironment
    @Binding var path: NavigationPath

    @State private var model: TimelineModel
    @State private var thumbnailer: Thumbnailer
    @State private var showingFilters = false
    @State private var reviewing = false
    @State private var presented: Compose?
    @State private var taskReload: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private enum Compose: String, Identifiable {
        case note, camera, record
        var id: String { rawValue }
    }

    private enum Destination: Hashable {
        case detail(String)
        case settings
    }

    init(environment: AppEnvironment, path: Binding<NavigationPath>) {
        self.environment = environment
        _path = path
        _model = State(initialValue: TimelineModel(
            store: environment.store,
            isEnabled: { LocationService.settings.isEnrichmentEnabled($0) },
            isOnline: { EnrichmentScheduling.isOnline }))
        let layout = environment.store.layout
        _thumbnailer = State(initialValue: Thumbnailer(layoutURL: { layout.packageURL(relativeDirectory: $0) },
                                                                thumbnailURL: { layout.thumbnailURL(attachmentID: $0) }))
    }

    var body: some View {
        content
            .navigationTitle("Captures")
            .searchable(text: searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search captures")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Destination.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .detail(let id):
                    CaptureDetailView(environment: environment, captureID: id) { Task { await model.reload() } }
                case .settings:
                    if let registry = environment.registry, let coordinator = environment.coordinator {
                        SettingsView(store: environment.store, registry: registry, coordinator: coordinator,
                                     onEnrichmentEnabled: { [environment] _ in
                                         // Don't hold the switch while the backfill runs.
                                         Task { await EnrichmentScheduling.run(environment, reason: "setting") }
                                     })
                    }
                }
            }
            .sheet(isPresented: $reviewing) {
                RemoteReviewSheet(store: environment.store, coordinator: environment.coordinator)
            }
            .sheet(isPresented: $showingFilters) {
                FiltersSheet(filters: $model.filter.sheet)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: sheetCompose, onDismiss: { Task { await model.reload() } }) { compose in
                switch compose {
                case .note:
                    NoteEditorView(environment: environment, location: LocationService.shared)
                case .record:
                    RecorderView(environment: environment, location: LocationService.shared)
                        .presentationDetents([.medium])
                case .camera:
                    // Never shown: `sheetCompose` maps the camera to nil; it has the cover below.
                    EmptyView()
                }
            }
            // The camera needs the whole screen; its capture sheet follows inside the same cover.
            .fullScreenCover(isPresented: cameraPresented, onDismiss: { Task { await model.reload() } }) {
                CameraCaptureView(environment: environment, location: LocationService.shared)
            }
            .task {
                await model.reload()
                #if DEBUG
                openCaptureFromLaunchArgument()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.reload() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: SyncCoordinator.passFinished)) { _ in
                Task { await model.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: TimelineModel.enrichmentChanged)) { _ in
                Task { await model.reload() }
            }
            // A task finishes every few seconds during a backfill: coalesce reloads to one per 500 ms.
            .onReceive(NotificationCenter.default.publisher(for: EnrichmentRunner.taskFinished)) { _ in
                guard taskReload == nil else { return }
                taskReload = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    taskReload = nil
                    await model.reload()
                }
            }
            .onDisappear { taskReload?.cancel(); taskReload = nil }
    }

    #if DEBUG
    /// `-HippoOpenCapture <id>` pushes that capture's details once, for screenshots and UI checks.
    private func openCaptureFromLaunchArgument() {
        guard path.isEmpty, !Self.openedLaunchCapture,
              let id = UserDefaults.standard.string(forKey: "HippoOpenCapture") else { return }
        Self.openedLaunchCapture = true
        path.append(Destination.detail(id))
    }
    private static var openedLaunchCapture = false
    #endif

    private var bottomBar: some View {
        HStack {
            Button { presented = .note } label: { Label("Note", systemImage: "square.and.pencil") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("note-button")
            Spacer()
            Button { presented = .camera } label: { Label("Camera", systemImage: "camera") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("camera-button")
            Spacer()
            Button { presented = .record } label: { Label("Record", systemImage: "record.circle") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Note and Record show as sheets; the camera as a full-screen cover.
    private var sheetCompose: Binding<Compose?> {
        Binding(get: { presented == .camera ? nil : presented }, set: { presented = $0 })
    }

    private var cameraPresented: Binding<Bool> {
        Binding(get: { presented == .camera }, set: { if !$0 { presented = nil } })
    }

    private var searchText: Binding<String> {
        Binding(get: { model.filter.search }, set: { model.searchChanged($0) })
    }

    private var filtersActive: Bool {
        model.filter.sheet.activeCount > 0 || model.filter.activeChip != .all || !model.filter.search.isEmpty
    }

    @ViewBuilder private var content: some View {
        List {
            FilterChipsView(filter: $model.filter) { showingFilters = true }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if model.reviewPending > 0, let name = model.reviewDestinationName {
                ReviewBanner(name: name) { reviewing = true }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
                Section(section.header) {
                    ForEach(section.rows) { row in
                        NavigationLink(value: Destination.detail(row.id)) {
                            TimelineRowView(row: row, thumbnailer: thumbnailer)
                        }
                        .task { await model.rowAppeared(id: row.id) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            if let coordinator = environment.coordinator {
                await SyncScheduling.runPass(coordinator, name: "timeline-sync", trigger: "manual")
            }
            await model.reload()
        }
        .overlay { emptyState }
    }

    @ViewBuilder private var emptyState: some View {
        if model.loadFailed {
            ContentUnavailableView {
                Label("Couldn't load captures", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Retry") { Task { await model.reload() } }
            }
        } else if model.isEmpty {
            if filtersActive {
                ContentUnavailableView {
                    Label("No captures match", systemImage: "magnifyingglass")
                } actions: {
                    Button("Clear filters") { model.filter = TimelineFilterState() }
                }
            } else {
                ContentUnavailableView("No captures yet", systemImage: "tray",
                                       description: Text("Share something to Hippo from any app, or tap Note, Camera or Record."))
            }
        }
    }
}
