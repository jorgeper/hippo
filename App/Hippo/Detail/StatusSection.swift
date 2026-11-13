import SwiftUI
import HippoPresentation

/// Detail's Status section: what happened to this capture, step by step, then the upload rows.
struct StatusSection: View {
    let detail: CaptureDetail
    let showsStripes: Bool
    let retrying: Bool
    let onRetry: () -> Void
    var uploadingAgain = false
    var onUploadAgain: () -> Void = {}

    /// No section at all when every line it could show is switched off or absent.
    var body: some View {
        if detail.hasStatusContent { section }
    }

    private var section: some View {
        Section("Status") {
            ForEach(Array(detail.status.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(line.text).font(.subheadline)
                        .foregroundStyle(line.state == .off ? .secondary : .primary)
                    Spacer(minLength: 8)
                    symbol(line.state)
                }
                .layerStripe(line.layer, shown: showsStripes)
            }
            if let storage = detail.storage {
                HStack(spacing: 8) {
                    Text(storage.text).font(.subheadline)
                    Spacer(minLength: 8)
                    symbol(storage.state)
                }
                .layerStripe(storage.layer, shown: showsStripes)
                if !detail.changedPaths.isEmpty {
                    Button("Upload again from iPhone", action: onUploadAgain)
                        .buttonStyle(.bordered).disabled(uploadingAgain)
                        .layerStripe(.sync, shown: showsStripes)
                        .accessibilityIdentifier("detail-upload-again")
                }
                if let note = detail.unrestorableNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                        .layerStripe(.sync, shown: showsStripes)
                }
            }
            ForEach(Array(detail.sync.enumerated()), id: \.offset) { _, row in
                syncRow(row).layerStripe(.sync, shown: showsStripes)
            }
        }
    }

    @ViewBuilder private func symbol(_ state: StatusState) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityHidden(true)
        case .working: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityLabel("Failed")
        case .off: EmptyView()
        }
    }

    private func syncRow(_ row: SyncRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let name = row.destinationName {
                    Text(name).font(.headline)
                    Spacer()
                }
                Text(row.label.title).font(.subheadline).foregroundStyle(color(row.label))
                if row.destinationName == nil { Spacer() }
            }
            if let message = row.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if row.canRetry {
                Button("Retry", action: onRetry).buttonStyle(.bordered).disabled(retrying)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ label: SyncLabel) -> Color {
        switch label {
        case .onIPhone: .secondary
        case .synced: .green
        case .needsAttention: .orange
        }
    }
}
