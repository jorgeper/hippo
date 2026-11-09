import SwiftUI
import AVKit
import ImageIO
import HippoPresentation

/// The large preview at the top of the details screen.
struct AttachmentPreview: View {
    let kind: PreviewKind
    let model: CaptureDetailModel
    @State private var quickLook: QuickLookItem?
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch kind {
        case .image(let url): ImagePreview(url: url)
        case .video(let url): VideoPreview(url: url)
        case .audio(let url): AudioPreview(url: url)
        case .pdf(let url): fileCard(url: url, symbol: "doc.richtext", previewable: true, name: nil)
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
        case .file(let url, let previewable, let name):
            fileCard(url: url, symbol: "doc", previewable: previewable, name: name)
        case .remoteOnly(let attachment): RemoteOnlyAttachmentView(attachment: attachment, model: model, large: true)
        case .none: EmptyView()
        }
    }

    @ViewBuilder private func fileCard(url: URL, symbol: String, previewable: Bool, name: String?) -> some View {
        let card = HStack(spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? url.lastPathComponent).font(.headline).lineLimit(2)
                if previewable { Text("Tap to open").font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        if previewable {
            Button { quickLook = QuickLookItem(url: url) } label: { card }
                .buttonStyle(.plain)
                .fullScreenCover(item: $quickLook) { item in
                    QuickLookView(url: item.url) { quickLook = nil }.ignoresSafeArea()
                }
        } else {
            card
        }
    }
}

private struct QuickLookItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Playback must sound with the ring/silent switch off, so it uses `.playback`. The session is active only
/// while something plays, so other apps' audio is interrupted no longer than necessary. Playback and
/// recording never overlap: detail players pause when the screen goes away.
@MainActor private enum PlaybackSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Owns one lazily created player and mirrors whether it is playing.
@MainActor @Observable private final class PlayerModel {
    private(set) var player: AVPlayer?
    private(set) var playing = false
    private(set) var duration: Double?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func prepare(url: URL) {
        guard player == nil else { return }
        let player = AVPlayer(url: url)
        self.player = player
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.statusChanged(playing: status != .paused) }
        }
    }

    private func statusChanged(playing now: Bool) {
        guard now != playing else { return }
        playing = now
        if now { PlaybackSession.activate() } else { PlaybackSession.deactivate() }
    }

    func loadDuration() async {
        if let time = try? await player?.currentItem?.asset.load(.duration), time.seconds.isFinite {
            duration = time.seconds
        }
    }

    func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .paused { PlaybackSession.activate(); player.play() } else { player.pause() }
    }

    func rewind() { player?.seek(to: .zero) }
    func pause() {
        player?.pause()
        if playing { playing = false }
        PlaybackSession.deactivate()
    }
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
    let url: URL
    @State private var model = PlayerModel()

    var body: some View {
        Group {
            if let player = model.player {
                VideoPlayer(player: player)
            } else {
                Color.clear
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { model.prepare(url: url) }
        .onDisappear { model.pause() }
    }
}

private struct AudioPreview: View {
    let url: URL
    @State private var model = PlayerModel()

    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggle() } label: {
                Image(systemName: model.playing ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
            }
            .accessibilityLabel(model.playing ? "Pause" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice recording").font(.headline)
                if let duration = model.duration { Text(Self.format(duration)).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            model.prepare(url: url)
            await model.loadDuration()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification,
                                                        object: model.player?.currentItem)) { _ in
            model.rewind()
        }
        .onDisappear { model.pause() }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }
}
