import SwiftUI
import EventKit
import EventKitUI
import HippoPresentation

/// A local image file shown decoded off the main thread. Decorative: hidden from accessibility.
struct FileThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 8 : 6))
        .accessibilityHidden(true)
        .task(id: url) {
            let path = url.path
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value
        }
    }
}

/// Link cards, summary and tags, found items and recognised text for one capture.
struct EnrichmentSections: View {
    let detail: CaptureDetail
    @Environment(\.openURL) private var openURL
    @State private var calendarDraft: CalendarDraft?

    struct CalendarDraft: Identifiable {
        let id = UUID()
        let start: Date
        let title: String
    }

    var body: some View {
        if !detail.linkCards.isEmpty {
            Section("Link previews") {
                ForEach(detail.linkCards, id: \.url) { card in linkCard(card) }
            }
        }
        if let summary = detail.summary {
            Section("Summary") { Text(summary).textSelection(.enabled) }
        }
        if !detail.tags.isEmpty {
            Section("Tags") {
                Text(detail.tags.map { "#\($0)" }.joined(separator: "  ")).textSelection(.enabled)
            }
        }
        if !detail.found.isEmpty {
            Section("Found in this capture") {
                ForEach(Array(detail.found.enumerated()), id: \.offset) { _, item in found(item) }
                    .sheet(item: $calendarDraft) { draft in
                        CalendarEventEditor(title: draft.title, start: draft.start).ignoresSafeArea()
                    }
            }
        }
        if !detail.transcripts.isEmpty {
            Section("Transcript") {
                ForEach(detail.transcripts, id: \.title) { disclosure($0) }
            }
        }
        if !detail.recognizedText.isEmpty {
            Section("Text in image") {
                ForEach(detail.recognizedText, id: \.title) { disclosure($0) }
            }
        }
    }

    private func disclosure(_ t: TitledText) -> some View {
        DisclosureGroup(t.title) {
            Text(t.text).textSelection(.enabled)
        }
    }

    private func linkCard(_ card: ResolvedLink) -> some View {
        let url = URL(string: card.url).flatMap { webURL($0) }
        return Button {
            if let url { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if let thumb = card.thumbnailURL { FileThumbnail(url: thumb, side: 64) }
                VStack(alignment: .leading, spacing: 3) {
                    if let title = card.title { Text(title).font(.headline).lineLimit(2) }
                    if let source = card.channel ?? card.siteName {
                        Text(source).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let text = card.summary {
                        Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    private func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    @ViewBuilder private func found(_ item: FoundItem) -> some View {
        let label = LabeledContent(item.kind.capitalized) {
            Text(item.text).multilineTextAlignment(.trailing)
        }
        switch item.action {
        case .call(let url), .map(let url), .open(let url):
            Button { openURL(url) } label: { label }
                .buttonStyle(.plain)
        case .addToCalendar(let start, let title):
            Button { calendarDraft = CalendarDraft(start: start, title: title) } label: { label }
                .buttonStyle(.plain)
        case nil:
            label.textSelection(.enabled)
        }
    }
}

/// Apple's event editor, prefilled. Since iOS 17 the edit UI runs out of process, so adding an event
/// needs no calendar permission.
struct CalendarEventEditor: UIViewControllerRepresentable {
    let title: String
    let start: Date
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}
