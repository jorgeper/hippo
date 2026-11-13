import Foundation

/// Which tiers the details screen shows: Raw (what was captured), Phone (this iPhone's enrichment), Server (the
/// desktop's enrichment), Sync, and the capture's Log lines. App-wide, saved in `AppSettings`.
public struct TierVisibility: Equatable, Sendable {
    public var raw = true, phone = true, server = true, sync = true, log = false

    /// Raw, Phone, Server and Sync on; Log off.
    public static let standard = TierVisibility()

    public init(raw: Bool = true, phone: Bool = true, server: Bool = true, sync: Bool = true, log: Bool = false) {
        self.raw = raw; self.phone = phone; self.server = server; self.sync = sync; self.log = log
    }

    /// Bronze is Raw, silver is Phone, gold is Server, sync is Sync.
    public func shows(_ layer: Layer) -> Bool {
        switch layer {
        case .bronze: raw
        case .silver: phone
        case .gold: server
        case .sync: sync
        }
    }
}

extension CaptureDetail {
    /// Whether Detail's Status section has anything to show: status lines, the storage line (which carries the
    /// changed files and the unrestorable note) or sync rows.
    public var hasStatusContent: Bool { !status.isEmpty || storage != nil || !sync.isEmpty }

    /// The detail without any row, entry or section whose tier is switched off. `preview` and `exportURLs` are
    /// always kept, and so is the preview's own trimmed file (its download works from the preview).
    public func filtered(by v: TierVisibility) -> CaptureDetail {
        if v.raw && v.phone && v.server && v.sync { return self }
        var d = self
        func keep(_ rows: [DetailRow]) -> [DetailRow] { rows.filter { v.shows($0.layer) } }

        // Raw: what was captured.
        if !v.raw {
            d.sharedTitle = nil
            d.sharedText = nil
            d.links = []
            var previewTrim: String?
            if case .remoteOnly(let r) = preview { previewTrim = r.attachmentID }
            d.remoteOnly = remoteOnly.filter { $0.key == previewTrim }
        }
        d.comments = comments.compactMap { c in
            var c = c
            if c.transcript != nil, !v.shows(c.transcriptLayer ?? .silver) {
                c.transcript = nil
                c.transcriptLayer = nil
            }
            if !v.raw {
                guard c.transcript != nil else { return nil }
                c.showsBody = false
                c.caption = nil
                c.remoteOnly = nil
            }
            return c
        }
        d.captured = keep(captured)
        d.context = keep(context)
        d.attachments = attachments.map(keep).filter { !$0.isEmpty }

        // Enrichment, by the layer each value came from.
        d.linkCards = linkCards.filter { v.shows($0.fromServer ? .gold : .silver) }
        d.transcripts = transcripts.filter { v.shows($0.layer) }
        d.recognizedText = recognizedText.filter { v.shows($0.layer) }
        d.imageDescriptions = imageDescriptions.filter { v.shows($0.layer) }
        if !v.shows(foundLayer) { d.found = [] }
        if !v.shows(summaryLayer) { d.summary = nil }
        if !v.shows(tagsLayer) { d.tags = [] }
        if !v.shows(titleLayer) { d.title = nil }
        if !v.shows(topicLayer) { d.topic = nil }
        d.people = people.filter { v.shows($0.layer) }
        d.likely = likely.filter { v.shows($0.layer) }
        // Pending lines are this iPhone's steps still to finish.
        if !v.phone { d.pending = [:] }

        // Sync, and the status lines by their own layer.
        if !v.sync {
            d.sync = []
            d.storage = nil
            d.changedPaths = []
            d.unrestorableNote = nil
        }
        d.status = status.filter { v.shows($0.layer) }
        return d
    }
}
