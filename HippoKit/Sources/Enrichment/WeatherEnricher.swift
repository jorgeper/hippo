import Foundation
import CaptureCore

/// The weather where and when a capture was made (design §5.2). Off until switched on; sends the capture's
/// coordinates rounded to two decimals and its hour to Open-Meteo.
public struct WeatherEnricher: Enricher {
    static let timeout: TimeInterval = 15
    static let maxBytes = 64 * 1024

    public var kind: FacetKind { .weather }
    public var version: Int { 1 }
    public var usesNetwork: Bool { true }
    public var inputs: Set<FacetKind> { [] }

    private let http: any HTTPFetching
    private let pacer: RequestPacer
    private let now: @Sendable () -> Date

    public init(http: any HTTPFetching, pacer: RequestPacer = RequestPacer(), now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http; self.pacer = pacer; self.now = now
    }

    public func applies(to m: CaptureMetadata) -> Bool { m.captureLocation != nil }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        guard let location = input.metadata.captureLocation else { throw EnrichmentError.notApplicable(code: "no_location") }
        let capturedAt = input.metadata.capturedAt
        let lat = OpenMeteo.rounded(location.latitude), lon = OpenMeteo.rounded(location.longitude)
        let forecast = OpenMeteo.request(latitude: lat, longitude: lon, capturedAt: capturedAt, now: now())
        let archive = OpenMeteo.archiveRequest(latitude: lat, longitude: lon, capturedAt: capturedAt)

        let body: Data
        do {
            body = try await fetch(forecast)
        } catch EnrichmentError.permanent(code: "http_4xx") where forecast != archive {
            // The forecast API refuses hours it no longer serves (HTTP 400); the archive gets one try.
            do { body = try await fetch(archive) } catch EnrichmentError.permanent(code: "http_4xx") {
                throw EnrichmentError.permanent(code: "weather_http_400")
            }
        } catch EnrichmentError.permanent(code: "http_4xx") {
            throw EnrichmentError.permanent(code: "weather_http_400")
        }

        let parsed: WeatherData?
        do {
            parsed = try OpenMeteo.parse(body, hour: capturedAt, latitude: lat, longitude: lon)
        } catch {
            throw EnrichmentError.permanent(code: "weather_bad_response")
        }
        guard let parsed else { return EnricherOutput(status: .empty, data: nil, provenance: "open_meteo") }
        return EnricherOutput(status: .ok, data: try .payload(parsed), provenance: "open_meteo")
    }

    private func fetch(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        await pacer.wait()
        try Task.checkCancellation()
        do {
            return try await http.get(url, timeout: Self.timeout, maxBytes: Self.maxBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch EnrichmentError.transient(code: "http_429") {
            // Rate limited: wait an hour and spend no attempt.
            throw EnrichmentError.deferred(code: "rate_limited", retryAfter: 3600)
        } catch let error as EnrichmentError {
            throw error
        } catch {
            throw EnrichmentError.transient(code: "weather_network")
        }
    }
}
