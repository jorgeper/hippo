import Foundation
import CoreLocation
import MapKit
import os
import CaptureCore
import Enrichment

/// Place names from Apple Maps (design §5.2): `MKReverseGeocodingRequest` for the area and
/// `MKLocalPointsOfInterestRequest` for the nearest point of interest. `PlaceEnricher` serializes the
/// calls and caches areas. Errors are `EnrichmentError` with fixed codes; coordinates and names are never
/// logged.
struct MapKitPlaceLookup: PlaceLookup {
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    func area(latitude: Double, longitude: Double) async throws -> PlaceArea? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items: [MKMapItem]
        let cancelBox = UncheckedBox(request)   // `cancel()` may be called from any thread
        do {
            items = try await withTaskCancellationHandler {
                try await request.mapItems
            } onCancel: {
                cancelBox.value.cancel()
            }
        } catch {
            if Self.isNotFound(error) { return nil }
            throw Self.map(error)
        }
        guard let reps = items.first?.addressRepresentations else { return nil }
        let area = Self.area(from: reps)
        if area.locality == nil && area.region == nil && area.country == nil { return nil }
        return area
    }

    func nearestPointOfInterest(latitude: Double, longitude: Double, radiusMeters: Double) async throws -> NearbyPlace? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: radiusMeters)
        let search = MKLocalSearch(request: request)
        let response: MKLocalSearch.Response
        let cancelBox = UncheckedBox(search)   // `cancel()` may be called from any thread
        do {
            response = try await withTaskCancellationHandler {
                try await search.start()
            } onCancel: {
                cancelBox.value.cancel()
            }
        } catch {
            if Self.isNotFound(error) { return nil }
            throw Self.map(error)
        }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        var best: NearbyPlace?
        for item in response.mapItems {
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let distance = item.location.distance(from: here)
            guard distance <= radiusMeters else { continue }
            if best == nil || distance < best!.distanceMeters {
                best = NearbyPlace(name: name, distanceMeters: distance.rounded())
            }
        }
        return best
    }

    // MARK: Mapping

    /// iOS 26+ `MKAddressRepresentations` exposes the city (`cityName`), the country (`regionName`) and
    /// "City, Region" (`cityWithContext`), but no neighbourhood: `subLocality` lives only on the
    /// deprecated `MKPlacemark`, so it stays nil.
    private static func area(from reps: MKAddressRepresentations) -> PlaceArea {
        let city = clean(reps.cityName)
        let country = clean(reps.regionName)
        var region: String?
        if let context = clean(reps.cityWithContext(.short)) {
            // "Cupertino, CA" → "CA". Only when it is exactly "<city>, <region>".
            let parts = context.components(separatedBy: ", ")
            if parts.count == 2, let city, parts[0] == city {
                region = clean(parts[1])
            }
        }
        if region == country { region = nil }
        return PlaceArea(subLocality: nil, locality: city, region: region, country: country)
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func isNotFound(_ error: Error) -> Bool { PlaceLookupError.isNotFound(error) }

    /// Fixed codes only (`PlaceLookupError.map`): throttling defers as `throttled`, no connection as `offline`.
    private static func map(_ error: Error) -> Error {
        let mapped = PlaceLookupError.map(error)
        switch mapped as? EnrichmentError {
        case .deferred(code: "throttled", _)?: log.error("\("geocode_throttled", privacy: .public)")
        case .transient?: log.error("\("geocode_failed", privacy: .public)")
        default: break
        }
        return mapped
    }
}
