import Foundation
import CryptoKit
import CaptureCore

public struct LinkMetadata: Sendable {
    public var title: String?
    public var siteName: String?
    public var summary: String?
    public var imageData: Data?
    /// Where the fetch ended up after redirects. A final URL the policy would skip discards the preview.
    public var finalURL: URL?
    public init(title: String? = nil, siteName: String? = nil, summary: String? = nil, imageData: Data? = nil,
                finalURL: URL? = nil) {
        self.title = title; self.siteName = siteName; self.summary = summary; self.imageData = imageData
        self.finalURL = finalURL
    }
}

/// Fetches a page's title and picture (the app wraps LinkPresentation). Throws `EnrichmentError`.
public protocol LinkMetadataFetching: Sendable {
    func metadata(for url: URL, timeout: TimeInterval) async throws -> LinkMetadata
}

/// Link previews for a capture's first five links (design §5.1). Never fetches single-use or private links.
public struct LinkPreviewEnricher: Enricher {
    static let maxURLs = 5
    static let timeout: TimeInterval = 15
    static let maxThumbnailDownload = 5 * 1024 * 1024

    public var kind: FacetKind { .linkPreview }
    public var version: Int { 1 }
    public var usesNetwork: Bool { true }
    public var inputs: Set<FacetKind> { [] }

    private let http: any HTTPFetching
    private let redirects: any RedirectResolving
    private let metadata: any LinkMetadataFetching
    private let tempDirectory: URL

    /// `redirects` vets a link's redirect chain before `metadata` (which follows redirects with no hook)
    /// is called, so a shortener or click tracker never leads it to a link the policy never fetches.
    public init(http: any HTTPFetching, redirects: any RedirectResolving, metadata: any LinkMetadataFetching,
                tempDirectory: URL) {
        self.http = http; self.redirects = redirects; self.metadata = metadata; self.tempDirectory = tempDirectory
    }

    public func applies(to m: CaptureMetadata) -> Bool { !m.urls.isEmpty }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        var items: [LinkPreviewItem] = []
        var assets: [String: URL] = [:]
        var allOEmbed = true
        var attempted = 0
        var failures: [EnrichmentError] = []
        let stagingDir = tempDirectory.appendingPathComponent("tmp-\(UUID().uuidString)")
        // Staged files belong to the runner only after a successful return; any throw removes them.
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: stagingDir) } }

        func store(_ jpeg: Data) throws -> AssetRef {
            let sha = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
            let path = "assets/\(sha).jpg"
            if assets[path] == nil {
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                let file = stagingDir.appendingPathComponent("\(sha).jpg")
                try jpeg.write(to: file)
                assets[path] = file
            }
            return AssetRef(relativePath: path, byteCount: Int64(jpeg.count), sha256: sha, mimeType: "image/jpeg")
        }

        for captured in input.metadata.urls.prefix(Self.maxURLs) {
            try Task.checkCancellation()
            guard let url = URL(string: captured.url) else { continue }
            let decision = LinkFetchPolicy.decide(url)
            if case .skip = decision { continue }
            attempted += 1
            do {
                switch decision {
                case .youTube(let video):
                    let raw = try await http.get(YouTubeOEmbed.requestURL(for: video), timeout: Self.timeout, maxBytes: 1_000_000)
                    let parsed = YouTubeOEmbed.parse(raw)
                    var thumb: AssetRef?
                    if let t = parsed.thumbnailURL, case .skip = LinkFetchPolicy.decide(t) {} else if let t = parsed.thumbnailURL {
                        do {
                            let bytes = try await http.get(t, timeout: Self.timeout, maxBytes: Self.maxThumbnailDownload)
                            thumb = try store(try ThumbnailEncoder.jpeg(from: bytes))
                        } catch is CancellationError { throw CancellationError() } catch {}   // a missing picture is not a failure
                    }
                    if parsed.title == nil && parsed.channel == nil && thumb == nil { continue }
                    items.append(LinkPreviewItem(url: captured.url, title: parsed.title, siteName: "YouTube",
                                                 channel: parsed.channel, thumbnail: thumb))
                case .fetch:
                    // A redirect into a never-fetch link counts as a never-fetch link: not attempted, not fetched.
                    guard case .final(let target) = try await redirects.resolve(url, timeout: Self.timeout),
                          !Self.skips(target) else {
                        attempted -= 1
                        continue
                    }
                    let md = try await metadata.metadata(for: target, timeout: Self.timeout)
                    // LinkPresentation can still redirect on its own (a page or script redirect).
                    if let final = md.finalURL, Self.skips(final) { continue }
                    var thumb: AssetRef?
                    if let data = md.imageData, let jpeg = try? ThumbnailEncoder.jpeg(from: data) { thumb = try store(jpeg) }
                    let site = Self.clean(md.siteName) ?? Self.siteName(from: target)
                    if Self.clean(md.title) == nil && Self.clean(md.summary) == nil && thumb == nil { continue }
                    allOEmbed = false
                    items.append(LinkPreviewItem(url: captured.url, title: Self.clean(md.title), siteName: site,
                                                 summary: Self.clean(md.summary), thumbnail: thumb))
                case .skip: break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as EnrichmentError {
                failures.append(error)
            } catch {
                failures.append(.transient(code: "link_failed"))
            }
        }

        if attempted > 0, failures.count == attempted {
            if let first = failures.first, failures.allSatisfy({ if case .deferred = $0 { true } else { false } }) { throw first }
            throw failures[0]
        }
        succeeded = true
        if items.isEmpty {
            try? FileManager.default.removeItem(at: stagingDir)
            return EnricherOutput(status: .empty, data: nil, provenance: "link_presentation")
        }
        return EnricherOutput(status: .ok, data: try .payload(LinkPreviewData(items: items)),
                              provenance: allOEmbed ? "oembed" : "link_presentation", newAssets: assets)
    }

    private static func skips(_ url: URL) -> Bool {
        if case .skip = LinkFetchPolicy.decide(url) { return true }
        return false
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func siteName(from url: URL) -> String? {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }
}
