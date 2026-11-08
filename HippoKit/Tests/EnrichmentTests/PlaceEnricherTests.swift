import Foundation
import Testing
import CaptureCore
import MapKit
@testable import Enrichment

private final class FakeLookup: PlaceLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var _areaCalls = 0, _poiCalls = 0, _radius: [Double] = []
    var poi: NearbyPlace?
    var areaError: (any Error)?
    var poiError: (any Error)?
    init(poi: NearbyPlace? = nil) { self.poi = poi }
    var areaCalls: Int { lock.withLock { _areaCalls } }
    var poiCalls: Int { lock.withLock { _poiCalls } }
    var radii: [Double] { lock.withLock { _radius } }
    func area(latitude: Double, longitude: Double) async throws -> PlaceArea? {
        lock.withLock { _areaCalls += 1 }
        if let areaError { throw areaError }
        return PlaceArea(subLocality: "Mission", locality: "San Francisco", region: "CA", country: "US")
    }
    func nearestPointOfInterest(latitude: Double, longitude: Double, radiusMeters: Double) async throws -> NearbyPlace? {
        lock.withLock { _poiCalls += 1; _radius.append(radiusMeters) }
        if let poiError { throw poiError }
        return poi
    }
}

private func meta(accuracy: Double? = nil, photos: [(String, Double, Double)] = []) -> CaptureMetadata {
    var m = fixtureMetadata(attachments: photos.map { id, lat, lon in
        CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).jpg", uti: "public.jpeg", byteCount: 1,
                               sha256: "x", representationSource: "item_provider_file",
                               media: MediaFacts(embeddedLocation: EmbeddedLocation(latitude: lat, longitude: lon)))
    })
    if let accuracy {
        m.captureLocation = CaptureLocation(latitude: 37.7599, longitude: -122.4148, horizontalAccuracyMeters: accuracy,
                                            observedAt: Date(), provenance: "core_location")
    }
    return m
}

private func items(_ out: EnricherOutput) throws -> [PlaceItem] {
    try JSONDecoder().decode(PlaceData.self, from: JSONEncoder().encode(try #require(out.data))).items
}

@Suite struct PlaceEnricherTests {
    @Test func placeCaptureWithPOIWhenAccurate() async throws {
        let lookup = FakeLookup(poi: NearbyPlace(name: "Cafe", distanceMeters: 60))
        let out = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 30)))
        let item = try #require(try items(out).first)
        #expect(out.provenance == "mapkit")
        #expect(item.target == "capture"); #expect(item.locality == "San Francisco"); #expect(item.subLocality == "Mission")
        #expect(item.nearby == NearbyPlace(name: "Cafe", distanceMeters: 60))
        #expect(lookup.radii == [100])
    }

    @Test func placeInaccurateSkipsPOI() async throws {
        let lookup = FakeLookup(poi: NearbyPlace(name: "Cafe", distanceMeters: 60))
        let out = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 150)))
        #expect(try items(out).first?.nearby == nil)
        #expect(lookup.poiCalls == 0)
    }

    @Test func placeFarPOIDropped() async throws {
        let lookup = FakeLookup(poi: NearbyPlace(name: "Far", distanceMeters: 140))
        let out = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 30)))
        #expect(try items(out).first?.nearby == nil)
        #expect(try items(out).first?.locality == "San Francisco")
    }

    @Test func placePhotoAreaOnly() async throws {
        let lookup = FakeLookup(poi: NearbyPlace(name: "Cafe", distanceMeters: 10))
        let out = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(photos: [("a1", 40.0, -74.0)])))
        let item = try #require(try items(out).first)
        #expect(item.target == "a1"); #expect(item.nearby == nil); #expect(lookup.poiCalls == 0)
    }

    @Test func placeCacheReusesNearbyCoordinates() async throws {
        let lookup = FakeLookup()
        let out = try await PlaceEnricher(lookup: lookup).run(
            fixtureInput(meta(photos: [("a1", 40.00001, -74.00001), ("a2", 40.00002, -74.00002)])))
        #expect(try items(out).count == 2)
        #expect(lookup.areaCalls == 1)
    }

    @Test func noTargetsIsEmpty() async throws {
        let out = try await PlaceEnricher(lookup: FakeLookup()).run(fixtureInput(meta()))
        #expect(out.status == .empty)
    }

    @Test func offlineRethrowsDeferred() async throws {
        let lookup = FakeLookup(); lookup.areaError = EnrichmentError.deferred(code: "offline", retryAfter: 60)
        await #expect(throws: EnrichmentError.deferred(code: "offline", retryAfter: 60)) {
            _ = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 10)))
        }
    }

    @Test func poiDeferredDefersWholePass() async throws {
        let lookup = FakeLookup(); lookup.poiError = EnrichmentError.deferred(code: "offline", retryAfter: 60)
        await #expect(throws: EnrichmentError.deferred(code: "offline", retryAfter: 60)) {
            _ = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 10)))
        }
    }

    @Test func poiOtherErrorKeepsArea() async throws {
        let lookup = FakeLookup(); lookup.poiError = EnrichmentError.transient(code: "x")
        let out = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 10)))
        let item = try #require(try items(out).first)
        #expect(item.locality == "San Francisco"); #expect(item.nearby == nil)
    }

    @Test func negativeAccuracyMeansNoPOI() async throws {
        let lookup = FakeLookup(poi: NearbyPlace(name: "Cafe", distanceMeters: 5))
        let out = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: -1)))
        #expect(try items(out).first?.nearby == nil)
        #expect(lookup.poiCalls == 0)
    }
}

// M4: how the app's MapKit lookup records an error. Built from real MapKit errors, so the domain and code
// constants are checked against MapKit itself.
@Suite struct PlaceLookupErrorTests {
    @Test func throttlingDefersAsThrottled() {
        let mapped = PlaceLookupError.map(MKError(.loadingThrottled))
        #expect(mapped as? EnrichmentError == .deferred(code: "throttled", retryAfter: 300))
    }

    @Test func noConnectionDefersAsOffline() {
        let error = NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue),
                            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet) as NSError])
        #expect(PlaceLookupError.map(error) as? EnrichmentError == .deferred(code: "offline", retryAfter: 60))
    }

    @Test func otherErrorsAreTransient() {
        #expect(PlaceLookupError.map(MKError(.serverFailure)) as? EnrichmentError == .transient(code: "geocode_failed"))
        #expect(PlaceLookupError.map(URLError(.timedOut)) as? EnrichmentError == .transient(code: "geocode_failed"))
    }

    @Test func cancellationStaysCancellation() {
        #expect(PlaceLookupError.map(CancellationError()) is CancellationError)
    }

    @Test func notFoundIsRecognised() {
        #expect(PlaceLookupError.isNotFound(MKError(.placemarkNotFound)))
        #expect(!PlaceLookupError.isNotFound(MKError(.loadingThrottled)))
    }

    // The enricher passes the deferral through, so the task waits with code "throttled" and Detail says
    // "Apple Maps is busy, will retry".
    @Test func enricherDefersOnThrottling() async throws {
        let lookup = FakeLookup()
        lookup.areaError = PlaceLookupError.map(MKError(.loadingThrottled))
        await #expect(throws: EnrichmentError.deferred(code: "throttled", retryAfter: 300)) {
            _ = try await PlaceEnricher(lookup: lookup).run(fixtureInput(meta(accuracy: 500)))
        }
    }
}
