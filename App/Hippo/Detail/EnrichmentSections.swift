import SwiftUI
import EventKit
import EventKitUI
import CaptureCore
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

/// Title, link cards, summary, topic and tags, people, likely circumstances, found items, recognised text and
/// picture descriptions for one capture.
struct EnrichmentSections: View {
    let detail: CaptureDetail
    let showsStripes: Bool
    @Environment(\.openURL) private var openURL
    @State private var calendarDraft: CalendarDraft?

    struct CalendarDraft: Identifiable {
        let id = UUID()
        let start: Date
        let title: String
    }

    var body: some View {
        if let title = detail.title {
            Section("Title") {
                Text(title).textSelection(.enabled).layerStripe(detail.titleLayer, shown: showsStripes)
            }
        }
        if !detail.linkCards.isEmpty || detail.pending[.linkPreview] != nil {
            Section("Link previews") {
                ForEach(detail.linkCards, id: \.url) { card in
                    linkCard(card).layerStripe(card.fromServer ? .gold : .silver, shown: showsStripes)
                }
                pending(.linkPreview)
            }
        }
        if let summary = detail.summary {
            Section("Summary") {
                Text(summary).textSelection(.enabled).layerStripe(detail.summaryLayer, shown: showsStripes)
            }
        }
        if let topic = detail.topic {
            Section("Topic") {
                Text(topic).textSelection(.enabled).layerStripe(detail.topicLayer, shown: showsStripes)
            }
        }
        if !detail.tags.isEmpty {
            Section("Tags") {
                Text(detail.tags.map { "#\($0)" }.joined(separator: "  ")).textSelection(.enabled)
                    .layerStripe(detail.tagsLayer, shown: showsStripes)
            }
        }
        if !detail.people.isEmpty {
            Section("People") {
                ForEach(detail.people) { person($0).layerStripe($0.layer, shown: showsStripes) }
            }
        }
        if !detail.likely.isEmpty {
            Section {
                ForEach(detail.likely) { likely($0).layerStripe($0.layer, shown: showsStripes) }
            } header: {
                Text("Likely")
            } footer: {
                Text("Worked out from signals. Likely, not certain.")
            }
        }
        if !detail.found.isEmpty || detail.pending[.dataDetection] != nil {
            Section("Found in this capture") {
                ForEach(Array(detail.found.enumerated()), id: \.offset) { _, item in
                    found(item).layerStripe(detail.foundLayer, shown: showsStripes)
                }
                pending(.dataDetection)
            }
            .sheet(item: $calendarDraft) { draft in
                CalendarEventEditor(title: draft.title, start: draft.start).ignoresSafeArea()
            }
        }
        if !detail.transcripts.isEmpty || detail.pending[.transcript] != nil {
            Section("Transcript") {
                ForEach(detail.transcripts, id: \.title) { disclosure($0).layerStripe($0.layer, shown: showsStripes) }
                pending(.transcript)
            }
        }
        if !detail.recognizedText.isEmpty || detail.pending[.textRecognition] != nil {
            Section("Text in image") {
                ForEach(detail.recognizedText, id: \.title) { disclosure($0).layerStripe($0.layer, shown: showsStripes) }
                pending(.textRecognition)
            }
        }
        if !detail.imageDescriptions.isEmpty {
            Section("In the picture") {
                ForEach(detail.imageDescriptions, id: \.title) { disclosure($0).layerStripe($0.layer, shown: showsStripes) }
            }
        }
    }

    /// The pending line for `kind`, in the spot where its result will appear. Silver: added on this iPhone.
    @ViewBuilder private func pending(_ kind: FacetKind) -> some View {
        if let line = detail.pending[kind] {
            PendingLineView(line: line).layerStripe(.silver, shown: showsStripes)
        }
    }

    /// The name, with where it was found as small secondary text when known.
    private func person(_ p: PersonRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.name)
            if !p.foundIn.isEmpty {
                Text(p.foundIn).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The circumstance in words with its confidence; the evidence lines when expanded. No evidence: a plain row.
    @ViewBuilder private func likely(_ row: LikelyRow) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(row.text)
            Text(row.confidence).font(.footnote).foregroundStyle(.secondary)
        }
        if row.evidence.isEmpty {
            label.accessibilityElement(children: .combine)
        } else {
            DisclosureGroup {
                ForEach(Array(row.evidence.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).textSelection(.enabled)
                }
            } label: {
                // One element, like the row with no evidence: the circumstance and its confidence together.
                label.accessibilityElement(children: .combine)
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
        context.coordinator.dismiss = { dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
        // Environment values are only current here, so refresh the closure on every update.
        context.coordinator.dismiss = { dismiss() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        var dismiss: () -> Void = {}
        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}
