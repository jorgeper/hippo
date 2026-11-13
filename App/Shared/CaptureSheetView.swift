import SwiftUI
import ImageIO
import HippoPresentation

/// The capture sheet: Cancel / Hippo / Save, a preview of the capture, an optional comment, the voice
/// comment and the line saying where it goes. The Share Extension shows it with the mic handing off to
/// the app; the app shows it (camera, pending share) with the mic recording in place. The host supplies
/// the actions.
struct CaptureSheetView: View {
    enum Voice {
        /// Share Extension: the mic hands the draft off to the app.
        case handoff(() -> Void)
        /// App: the mic records the voice comment in place.
        case record(RecordingSession)
    }

    let model: ShareSessionModel
    let voice: Voice
    /// Saves inside a background-activity assertion; the host owns that.
    let save: (_ acceptPartial: Bool) async -> Void
    /// For a pending share the view never calls this: its left button reads "Save without comment" and
    /// calls `save(false)` instead.
    let cancel: () -> Void
    /// Called about a second after "Saved" or the hand-off message, to close the sheet.
    let finish: () -> Void

    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.state {
            case .saved: centered("✓ Saved on this iPhone")
            case .deferred: centered(ShareSessionModel.handoffMessage)
            default: content
            }
        }
        .background(Color(.systemBackground))
        .task { await model.prepare() }
        .task(id: isClosing) {
            guard isClosing else { return }
            // A cancelled task (the view went away) throws here, so it never calls `finish()`.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            finish()
        }
        .alert(partialMessage ?? "", isPresented: partialAlertShown) {
            Button("Save the rest") { Task { await save(true) } }
            // Dismissing only returns to editing; the share stays open.
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Saved, or handed off to the app: either way the sheet closes after a second.
    private var isClosing: Bool { model.state == .saved || model.state == .deferred }

    private var partialAlertShown: Binding<Bool> {
        Binding(get: { partialMessage != nil },
                set: { if !$0 { model.declinePartial() } })
    }

    private var partialMessage: String? {
        if case .confirmPartial(let message) = model.state { message } else { nil }
    }

    private var header: some View {
        HStack {
            if model.isPendingShare {
                // A pending share has no discard: the left button saves it without the voice comment.
                Button("Save without comment") {
                    if case .record(let session) = voice { session.discard() }
                    Task { await save(false) }
                }
                .disabled(!canSave)
            } else {
                Button("Cancel", action: cancel)
                    .disabled(model.state == .saving || isClosing)
            }
            Spacer()
            Text("Hippo").font(.headline)
            Spacer()
            Button("Save") { Task { await save(false) } }
                .fontWeight(.semibold)
                .disabled(!canSave)
                .accessibilityIdentifier("capture-sheet-save")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var canSave: Bool {
        switch model.state {
        case .ready: true
        case .failed(_, let canSave): canSave
        default: false
        }
    }

    /// Nothing can start a recording or a hand-off unless the sheet is editable.
    private var voiceDisabled: Bool {
        switch model.state {
        case .ready, .confirmPartial: false
        default: true
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.state {
                case .preparing(let done, let total):
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Preparing \(done) of \(total)…").foregroundStyle(.secondary)
                    }
                case .failed(let message, _):
                    Text(message).foregroundStyle(.red)
                default:
                    preview
                    if let notice = model.partialNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Add a comment (optional)", text: Bindable(model).comment, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($commentFocused)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(model.state == .saving)
                VoiceCommentControl(voice: voice, disabled: voiceDisabled)
                if model.handoffFailed {
                    Text(ShareSessionModel.handoffFailedMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                Text(model.destinationLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var preview: some View {
        HStack(spacing: 12) {
            SharePreviewThumbnail(url: model.previewImageURL, symbol: model.previewSymbol)
            Text(model.summary).font(.body)
            Spacer(minLength: 0)
        }
    }

    private func centered(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

/// A 300 px downsample of the shared image, decoded off the main thread so the extension never holds
/// the full-size bitmap. Without an image (or if it can't be decoded) it shows a document symbol.
private struct SharePreviewThumbnail: View {
    let url: URL?
    let symbol: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .userInitiated) { Self.downsample(url) }.value
        }
    }

    private nonisolated static func downsample(_ url: URL) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 300,
        ]
        // `ShouldCache: false` on the source keeps ImageIO from decoding the full image into its cache.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
