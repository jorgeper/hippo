import Foundation
import CaptureCore

public struct PlaceArea: Sendable, Equatable {
    public var subLocality: String?
    public var locality: String?
    public var region: String?
    public var country: String?
    public init(subLocality: String? = nil, locality: String? = nil, region: String? = nil, country: String? = nil) {
        self.subLocality = subLocality; self.locality = locality; self.region = region; self.country = country
    }
}

/// Place lookups (the app wraps MapKit). Throws `EnrichmentError`.
public protocol PlaceLookup: Sendable {
    func area(latitude: Double, longitude: Double) async throws -> PlaceArea?
    func nearestPointOfInterest(latitude: Double, longitude: Double, radiusMeters: Double) async throws -> NearbyPlace?
}

/// How a place lookup error is recorded. The app's MapKit lookup passes MapKit's errors through this;
/// MapKit isn't imported here, so its errors are matched by domain and code.
public enum PlaceLookupError {
    private static let mapKitDomain = "MKErrorDomain"
    private static let loadingThrottled = 3   // MKError.Code.loadingThrottled
    private static let placemarkNotFound = 4  // MKError.Code.placemarkNotFound

    /// No place at these coordinates: an empty result, not an error.
    public static func isNotFound(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == mapKitDomain && e.code == placemarkNotFound
    }

    /// Apple's rate limit isn't a failure: it defers without spending an attempt, with code `throttled`
    /// (Detail: "Apple Maps is busy, will retry"). No connection defers as `offline`. Anything else is a
    /// transient `geocode_failed`. Cancellation stays a `CancellationError`.
    public static func map(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        let e = error as NSError
        if e.domain == mapKitDomain, e.code == loadingThrottled {
            return EnrichmentError.deferred(code: "throttled", retryAfter: 300)
        }
        if let url = underlyingURLError(e) {
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return EnrichmentError.deferred(code: "offline", retryAfter: 60)
            default:
                break
            }
        }
        return EnrichmentError.transient(code: "geocode_failed")
    }

    private static func underlyingURLError(_ error: NSError) -> URLError? {
        var current: NSError? = error
        for _ in 0..<4 {
            guard let e = current else { return nil }
            if e.domain == NSURLErrorDomain { return URLError(URLError.Code(rawValue: e.code)) }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}

/// Place names for the capture location and for photos' embedded locations (design §5.2).
public struct PlaceEnricher: Enricher {
    static let poiRadius = 100.0

    public var kind: FacetKind { .place }
    public var version: Int { 1 }
    public var usesNetwork: Bool { true }
    public var inputs: Set<FacetKind> { [] }

    private let lookup: any PlaceLookup
    private let cache = AreaCache()

    public init(lookup: any PlaceLookup) { self.lookup = lookup }

    /// Keyed by coordinates rounded to 4 decimals (about 11 m).
    private actor AreaCache {
        private var areas: [String: PlaceArea?] = [:]
        func get(_ key: String) -> PlaceArea?? { areas[key] }
        func set(_ key: String, _ area: PlaceArea?) { areas[key] = area }
    }

    private struct Target { var id: String; var lat: Double; var lon: Double; var poi: Bool }

    private func targets(_ m: CaptureMetadata) -> [Target] {
        var out: [Target] = []
        if let l = m.captureLocation {
            out.append(Target(id: "capture", lat: l.latitude, lon: l.longitude, poi: l.horizontalAccuracyMeters >= 0 && l.horizontalAccuracyMeters <= Self.poiRadius))
        }
        for a in m.attachments {
            if let l = a.media?.embeddedLocation { out.append(Target(id: a.attachmentID, lat: l.latitude, lon: l.longitude, poi: false)) }
        }
        return out
    }

    public func applies(to m: CaptureMetadata) -> Bool { !targets(m).isEmpty }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        let targets = targets(input.metadata)
        var items: [PlaceItem] = []
        var failures: [EnrichmentError] = []
        for t in targets {
            try Task.checkCancellation()
            let area: PlaceArea?
            do {
                let key = "\((t.lat * 10_000).rounded())|\((t.lon * 10_000).rounded())"
                if let cached = await cache.get(key) { area = cached } else {
                    area = try await lookup.area(latitude: t.lat, longitude: t.lon)
                    await cache.set(key, area)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as EnrichmentError {
                failures.append(error); continue
            } catch {
                failures.append(.transient(code: "place_failed")); continue
            }
            var nearby: NearbyPlace?
            if t.poi {
                do {
                    let p = try await lookup.nearestPointOfInterest(latitude: t.lat, longitude: t.lon, radiusMeters: Self.poiRadius)
                    if let p, p.distanceMeters <= Self.poiRadius { nearby = p }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as EnrichmentError {
                    // Not now: defer the whole pass so "near X" is not lost for good. Other errors keep the area.
                    if case .deferred = error { throw error }
                } catch {}
            }
            if area == nil && nearby == nil { continue }
            items.append(PlaceItem(target: t.id, subLocality: area?.subLocality, locality: area?.locality,
                                   region: area?.region, country: area?.country, nearby: nearby))
        }
        if !targets.isEmpty, failures.count == targets.count {
            if let first = failures.first, failures.allSatisfy({ if case .deferred = $0 { true } else { false } }) { throw first }
            throw failures[0]
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "mapkit") }
        return EnricherOutput(status: .ok, data: try .payload(PlaceData(items: items)), provenance: "mapkit")
    }
}
