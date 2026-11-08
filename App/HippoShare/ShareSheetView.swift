import SwiftUI
import ImageIO
import HippoPresentation

/// The Share Extension's sheet: Cancel / Hippo / Save, a preview of what was shared, an optional comment
/// and the line saying where it goes. The controller supplies the actions.
struct ShareSheetView: View {
    let model: ShareSessionModel
    /// Saves inside a background-activity assertion; the controller owns that.
    let save: (_ acceptPartial: Bool) async -> Void
    let cancel: () -> Void
    /// Called about a second after "Saved", to close the sheet.
    let finish: () -> Void

    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.state == .saved {
                savedConfirmation
            } else {
                content
            }
        }
        .background(Color(.systemBackground))
        .task { await model.prepare() }
        .task(id: model.state == .saved) {
            guard model.state == .saved else { return }
            try? await Task.sleep(for: .seconds(1))
            finish()
        }
        .alert(partialMessage ?? "", isPresented: .constant(partialMessage != nil)) {
            Button("Save the rest") { Task { await save(true) } }
            Button("Cancel", role: .cancel) { cancel() }
        }
    }

    private var partialMessage: String? {
        if case .confirmPartial(let message) = model.state { message } else { nil }
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: cancel)
                .disabled(model.state == .saving)
            Spacer()
            Text("Hippo").font(.headline)
            Spacer()
            Button("Save") { Task { await save(false) } }
                .fontWeight(.semibold)
                .disabled(!canSave)
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
                }
                TextField("Add a comment (optional)", text: Bindable(model).comment, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($commentFocused)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(model.state == .saving)
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
            SharePreviewThumbnail(url: model.previewImageURL)
            Text(model.summary).font(.body)
            Spacer(minLength: 0)
        }
    }

    private var savedConfirmation: some View {
        VStack {
            Spacer()
            Text("✓ Saved on this iPhone").font(.title3.weight(.semibold))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A 300 px downsample of the shared image, decoded off the main thread so the extension never holds
/// the full-size bitmap. Without an image (or if it can't be decoded) it shows a document symbol.
private struct SharePreviewThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: url == nil ? "doc" : "photo")
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

/// Shown instead of the sheet when the shared store can't be opened.
struct ShareStartupFailureView: View {
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Hippo").font(.headline)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close", action: close).buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
