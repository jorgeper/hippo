import SwiftUI
import HippoPresentation

/// A trimmed attachment: its kept thumbnail or type symbol, where it is, and a Download button when the
/// destination is connected. `large` is the details screen's main preview; otherwise a compact row.
struct RemoteOnlyAttachmentView: View {
    let attachment: RemoteOnlyAttachment
    let model: CaptureDetailModel
    let large: Bool

    private var stateText: String {
        switch attachment.state {
        case .available: attachment.storageText
        case .unavailable(let message), .mismatch(let message): message
        }
    }

    private var isAvailable: Bool {
        if case .available = attachment.state { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateText).font(large ? .headline : .subheadline)
                    if let message = model.restoreMessages[attachment.attachmentID], model.restoreProgress[attachment.attachmentID] == nil {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let progress = model.restoreProgress[attachment.attachmentID] {
                ProgressView(value: progress).accessibilityLabel("Downloading")
            } else if isAvailable {
                Button("Download") { Task { await model.restore(attachmentID: attachment.attachmentID) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-download")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var thumbnail: some View {
        let side: CGFloat = large ? 96 : 56
        if let url = attachment.thumbnailURL {
            FileThumbnail(url: url, side: side)
        } else {
            Image(systemName: attachment.symbol).font(large ? .largeTitle : .title2).foregroundStyle(.secondary)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }
}
