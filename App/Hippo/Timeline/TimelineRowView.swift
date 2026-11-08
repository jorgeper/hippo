import SwiftUI
import UniformTypeIdentifiers
import HippoPresentation

struct TimelineRowView: View {
    let row: TimelineRow
    let thumbnailer: Thumbnailer

    @ScaledMetric(relativeTo: .caption) private var timeWidth = 64.0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(2)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let comment = row.comment {
                    Text(comment)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    SyncBadge(label: row.sync)
                    switch row.progress {
                    case .working: ProgressView().controlSize(.mini)
                    case .waiting: Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    case .none: EmptyView()
                    }
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.time), \(row.sync.title)\(progressSuffix)")
    }

    private var progressSuffix: String {
        switch row.progress {
        case .working: ", processing"
        case .waiting: ", waiting"
        case .none: ""
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.kind {
        case .media:
            ThumbnailView(row: row, path: row.thumbnailAttachmentPaths.first, side: 60,
                          thumbnailer: thumbnailer)
        case .multi:
            HStack(spacing: 4) {
                ForEach(row.thumbnailAttachmentPaths, id: \.self) { path in
                    ThumbnailView(row: row, path: path, side: 28, thumbnailer: thumbnailer)
                }
                if row.extraCount > 0 {
                    Text("+\(row.extraCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .link:
            if let url = row.thumbnailURL { FileThumbnail(url: url, side: 44) } else { kindSymbol("link") }
        case .note: kindSymbol("note.text")
        case .voice: kindSymbol("waveform")
        case .file: kindSymbol("doc")
        }
    }

    private func kindSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
    }
}

private struct SyncBadge: View {
    let label: SyncLabel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label.title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch label {
        case .onIPhone: .gray
        case .synced: .green
        case .needsAttention: .orange
        }
    }
}

private struct ThumbnailView: View {
    let row: TimelineRow
    let path: String?
    let side: CGFloat
    let thumbnailer: Thumbnailer

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    private var symbol: String {
        guard let type = path.map({ URL(fileURLWithPath: $0).pathExtension }).flatMap({ UTType(filenameExtension: $0) })
        else { return "doc" }
        if type.conforms(to: .movie) { return "video" }
        if type.conforms(to: .image) { return "photo" }
        return "doc"
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 8 : 5))
        .task(id: path) {
            image = nil
            guard let path else { return }
            image = await thumbnailer.thumbnail(relativeDirectory: row.relativeDirectory, path: path, scale: scale)
        }
    }
}
