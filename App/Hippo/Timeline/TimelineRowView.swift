import SwiftUI
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
                SyncBadge(label: row.sync)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.time), \(row.sync.title)")
    }

    @ViewBuilder private var trailing: some View {
        switch row.kind {
        case .media:
            ThumbnailView(row: row, path: row.thumbnailAttachmentPaths.first, side: 60, symbol: "photo",
                          thumbnailer: thumbnailer)
        case .multi:
            HStack(spacing: 4) {
                ForEach(row.thumbnailAttachmentPaths, id: \.self) { path in
                    ThumbnailView(row: row, path: path, side: 28, symbol: "photo", thumbnailer: thumbnailer)
                }
                if row.extraCount > 0 {
                    Text("+\(row.extraCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .link: kindSymbol("link")
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
    let symbol: String
    let thumbnailer: Thumbnailer

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

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
            guard let path else { return }
            image = await thumbnailer.thumbnail(relativeDirectory: row.relativeDirectory, path: path, scale: scale)
        }
    }
}
