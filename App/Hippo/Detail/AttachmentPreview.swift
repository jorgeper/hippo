import SwiftUI
import AVKit
import ImageIO
import HippoPresentation

/// The large preview at the top of the details screen.
struct AttachmentPreview: View {
    let kind: PreviewKind
    @State private var quickLookURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch kind {
        case .image(let url): ImagePreview(url: url)
        case .video(let url): VideoPreview(url: url)
        case .audio(let url): AudioPreview(url: url)
        case .pdf(let url): fileCard(url: url, symbol: "doc.richtext", hint: "Tap to open", previewable: true)
        case .text(let body):
            Text(body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .link(let url):
            Button { openURL(url) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "link").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.host() ?? url.absoluteString).font(.headline)
                        Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                }
                .padding()
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        case .file(let url, let previewable): fileCard(url: url, symbol: "doc", hint: nil, previewable: previewable)
        case .none: EmptyView()
        }
    }

    @ViewBuilder private func fileCard(url: URL, symbol: String, hint: String?, previewable: Bool) -> some View {
        let card = HStack(spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.headline).lineLimit(2)
                if previewable, let hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        if previewable {
            Button { quickLookURL = url } label: { card }
                .buttonStyle(.plain)
                .fullScreenCover(item: $quickLookURL) { url in
                    QuickLookView(url: url).ignoresSafeArea()
                }
        } else {
            card
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct ImagePreview: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Image preview")
            } else if failed {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: url) {
            let decoded = await Task.detached(priority: .userInitiated) { Self.downsample(url) }.value
            image = decoded
            failed = decoded == nil
        }
    }

    /// Decodes at most 1600 px on the long side; the full-size bitmap is never created.
    private nonisolated static func downsample(_ url: URL) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct VideoPreview: View {
    @State private var player: AVPlayer

    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onDisappear { player.pause() }
    }
}

private struct AudioPreview: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var playing = false
    @State private var duration: Double?

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if playing { player.pause() } else { player.play() }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
            }
            .accessibilityLabel(playing ? "Pause" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice recording").font(.headline)
                if let duration { Text(Self.format(duration)).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            if let time = try? await player.currentItem?.asset.load(.duration), time.seconds.isFinite {
                duration = time.seconds
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { _ in
            playing = false
            player.seek(to: .zero)
        }
        .onDisappear { player.pause(); playing = false }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }
}
