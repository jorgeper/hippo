import SwiftUI
import HippoPresentation

struct TimelineView: View {
    let environment: AppEnvironment
    @Binding var path: NavigationPath

    @State private var model: TimelineModel
    @State private var thumbnailer: Thumbnailer
    @State private var showingFilters = false
    @State private var presented: Compose?
    @Environment(\.scenePhase) private var scenePhase

    private enum Compose: String, Identifiable {
        case note, record
        var id: String { rawValue }
    }

    private enum Destination: Hashable {
        case detail(String)
        case settings
    }

    init(environment: AppEnvironment, path: Binding<NavigationPath>) {
        self.environment = environment
        _path = path
        _model = State(initialValue: TimelineModel(store: environment.store))
        let layout = environment.store.layout
        _thumbnailer = State(initialValue: Thumbnailer(layoutURL: { layout.packageURL(relativeDirectory: $0) }))
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
                case .settings: Text("Settings").navigationTitle("Settings")
                }
            }
            .sheet(isPresented: $showingFilters) {
                FiltersSheet(filters: $model.filter.sheet)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $presented, onDismiss: { Task { await model.reload() } }) { compose in
                // Task 12 replaces these with the note editor and the recorder.
                NavigationStack {
                    Text(compose == .note ? "Note" : "Record")
                        .navigationTitle(compose == .note ? "Note" : "Record")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = nil } } }
                }
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
                _ = await BackgroundActivity.run(name: "timeline-sync") { await coordinator.syncNow() }
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
                                       description: Text("Share something to Hippo from any app, or tap Note or Record."))
            }
        }
    }
}
