import Foundation
import LinkPresentation
import UniformTypeIdentifiers
import os
import Enrichment

/// Link titles and pictures through LinkPresentation (design §5.1). LinkPresentation keeps no cookies of
/// ours; this adds none. Errors are `EnrichmentError` with fixed codes; nothing about the link is logged.
struct LinkPresentationFetcher: LinkMetadataFetching {
    /// The largest picture kept, matching `LinkPreviewEnricher.maxThumbnailDownload` (5 MiB). A larger
    /// one is dropped and the preview keeps its title.
    static let maxImageBytes = 5 * 1024 * 1024

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    func metadata(for url: URL, timeout: TimeInterval) async throws -> Enrichment.LinkMetadata {
        let fetched: Fetched
        do {
            fetched = try await fetch(url, timeout: timeout)
        } catch is CancellationError where !Task.isCancelled {
            // LinkPresentation cancelled on its own: an ordinary failure, not ours to stop the pass for.
            throw EnrichmentError.transient(code: "link_failed")
        }
        try Task.checkCancellation()
        var imageData: Data?
        if let provider = fetched.imageProvider {
            imageData = await Self.loadImage(provider.value)
        }
        try Task.checkCancellation()
        return Enrichment.LinkMetadata(title: fetched.title, imageData: imageData, finalURL: fetched.finalURL)
    }

    // MARK: Fetch

    /// What the completion handler hands back across threads. `NSItemProvider` is not `Sendable`; it is
    /// only read once, after the handler has returned it, so the box is safe.
    private struct Fetched: Sendable {
        var title: String?
        var finalURL: URL?
        var imageProvider: UncheckedBox<NSItemProvider>?
    }

    private func fetch(_ url: URL, timeout: TimeInterval) async throws -> Fetched {
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        provider.shouldFetchSubresources = true
        let handle = ProviderHandle(provider)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Fetched, Error>) in
                // Runs on a background queue, exactly once (also on `cancel()`).
                handle.start(url) { metadata, error in
                    if let metadata {
                        continuation.resume(returning: Fetched(
                            title: metadata.title,
                            finalURL: metadata.url ?? metadata.originalURL,
                            imageProvider: metadata.imageProvider.map(UncheckedBox.init)))
                    } else {
                        continuation.resume(throwing: Self.map(error))
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Loads the picture as data. Any failure, or a picture over `maxImageBytes`, means no picture.
    private static func loadImage(_ provider: NSItemProvider) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, data.count <= maxImageBytes else { return nil }
        return data
    }

    // MARK: Errors

    /// Same rule as `URLSessionHTTPFetcher`: only "no network" defers; DNS, connection failures, lost
    /// connections, timeouts and everything else are transient (they count an attempt).
    private static func map(_ error: Error?) -> Error {
        guard let error else { return EnrichmentError.transient(code: "link_failed") }
        if error is CancellationError { return error }
        if let urlError = underlyingURLError(error) {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return EnrichmentError.deferred(code: "offline", retryAfter: 60)
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return EnrichmentError.transient(code: "timeout")
            default:
                break
            }
        }
        if let lp = error as? LPError {
            switch lp.code {
            case .metadataFetchCancelled: return CancellationError()
            case .metadataFetchTimedOut: return EnrichmentError.transient(code: "timeout")
            case .metadataFetchNotAllowed: return EnrichmentError.permanent(code: "not_allowed")
            default: break
            }
        }
        log.error("\("link_metadata_failed", privacy: .public)")
        return EnrichmentError.transient(code: "link_failed")
    }

    /// The error itself or the first `URLError` among its underlying errors.
    private static func underlyingURLError(_ error: Error) -> URLError? {
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let e = current else { return nil }
            if e.domain == NSURLErrorDomain { return URLError(URLError.Code(rawValue: e.code)) }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}

/// Owns one `LPMetadataProvider` so a cancellation handler on another thread can cancel it. Each provider
/// fetches once; the lock makes `start` and `cancel` safe to call from any thread, in either order.
private final class ProviderHandle: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (started: false, cancelled: false))
    private let provider: LPMetadataProvider

    init(_ provider: LPMetadataProvider) { self.provider = provider }

    func start(_ url: URL, completion: @escaping @Sendable (LPLinkMetadata?, Error?) -> Void) {
        let cancelled = lock.withLock { state -> Bool in
            state.started = true
            return state.cancelled
        }
        if cancelled {
            completion(nil, CancellationError())
            return
        }
        provider.startFetchingMetadata(for: url) { metadata, error in completion(metadata, error) }
    }

    func cancel() {
        let started = lock.withLock { state -> Bool in
            state.cancelled = true
            return state.started
        }
        if started { provider.cancel() }
    }
}

/// Carries a non-`Sendable` reference that is handed off, never shared, across one thread hop.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
