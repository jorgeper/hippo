import Testing
import Foundation
@testable import CaptureCore

@Suite struct DraftSanitizerTests {
    private let root: URL
    private let writer: PackageWriter
    private let startedAt = Date(timeIntervalSince1970: 1_794_070_800)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-sanitizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        writer = PackageWriter(layout: StoreLayout(root: root),
                               producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
    }

    private func draft(location: CaptureLocation? = nil, observations: [MetadataObservation] = []) -> CaptureDraft {
        CaptureDraft(captureID: UUID(), startedAt: startedAt, timeZone: TimeZone(identifier: "UTC")!,
                     method: .typedNote, userNote: "hello", location: location, observations: observations)
    }

    private func location(lat: Double = 37.7749, lon: Double = -122.4194, acc: Double = 12) -> CaptureLocation {
        CaptureLocation(latitude: lat, longitude: lon, horizontalAccuracyMeters: acc, observedAt: startedAt, provenance: "test")
    }

    @Test func invalidLocationIsDroppedWithObservation() async throws {
        let bad = [location(acc: -1), location(lat: 91), location(lon: .nan)]
        for loc in bad {
            let pkg = try await writer.commit(draft(location: loc))
            #expect(pkg.metadata.captureLocation == nil)
            #expect(pkg.metadata.metadataObservations.contains {
                $0.key == "capture_location_dropped" && $0.value == .string("invalid_values") && $0.provenance == "hippo_writer"
            })
            guard case .complete = PackageValidator.validate(directory: pkg.directoryURL) else {
                Issue.record("package not complete"); continue
            }
        }
    }

    @Test func sanitizerDropsBadExtrasKeepsLocation() async throws {
        var bad = location()
        bad.speedMetersPerSecond = -1; bad.speedAccuracyMetersPerSecond = -1
        bad.courseDegrees = 400; bad.courseAccuracyDegrees = -1
        bad.altitudeMeters = .infinity; bad.verticalAccuracyMeters = -1
        let pkg = try await writer.commit(draft(location: bad))
        #expect(pkg.metadata.captureLocation == location())
        #expect(!pkg.metadata.metadataObservations.contains { $0.key == "capture_location_dropped" })

        var good = location()
        good.altitudeMeters = -12.5; good.speedMetersPerSecond = 0; good.courseDegrees = 360
        let pkg2 = try await writer.commit(draft(location: good))
        #expect(pkg2.metadata.captureLocation == good)
        #expect(pkg2.metadata.captureLocation?.altitudeMeters == -12.5)
        #expect(pkg2.metadata.captureLocation?.speedMetersPerSecond == 0)
        #expect(pkg2.metadata.captureLocation?.courseDegrees == 360)
    }

    @Test func extrasAreDroppedAsPairs() async throws {
        func commit(_ edit: (inout CaptureLocation) -> Void) async throws -> CaptureLocation? {
            var l = location(); edit(&l)
            return try await writer.commit(draft(location: l)).metadata.captureLocation
        }
        // Invalid accuracy drops the valid value with it.
        #expect(try await commit { $0.altitudeMeters = 5; $0.verticalAccuracyMeters = -1 } == location())
        #expect(try await commit { $0.speedMetersPerSecond = 3; $0.speedAccuracyMetersPerSecond = .nan } == location())
        #expect(try await commit { $0.courseDegrees = 90; $0.courseAccuracyDegrees = -1 } == location())
        // Invalid value drops the valid accuracy with it.
        #expect(try await commit { $0.altitudeMeters = .infinity; $0.verticalAccuracyMeters = 3 } == location())
        #expect(try await commit { $0.speedMetersPerSecond = -1; $0.speedAccuracyMetersPerSecond = 1 } == location())
        #expect(try await commit { $0.courseDegrees = 400; $0.courseAccuracyDegrees = 5 } == location())
        // A valid value with no accuracy is kept; a valid pair is kept.
        let kept = try await commit { $0.altitudeMeters = 5; $0.speedMetersPerSecond = 3; $0.courseDegrees = 90 }
        #expect(kept?.altitudeMeters == 5 && kept?.speedMetersPerSecond == 3 && kept?.courseDegrees == 90)
        let both = try await commit { $0.speedMetersPerSecond = 3; $0.speedAccuracyMetersPerSecond = 0.5 }
        #expect(both?.speedMetersPerSecond == 3 && both?.speedAccuracyMetersPerSecond == 0.5)
    }

    @Test func validLocationIsKept() async throws {
        let loc = location()
        let pkg = try await writer.commit(draft(location: loc))
        #expect(pkg.metadata.captureLocation == loc)
        #expect(pkg.metadata.metadataObservations.isEmpty)
    }

    @Test func nonFiniteObservationIsDropped() async throws {
        let pkg = try await writer.commit(draft(observations: [
            MetadataObservation(key: "a", value: .array([.number(.infinity)]), provenance: "t"),
            MetadataObservation(key: "b", value: .string("ok"), provenance: "t"),
        ]))
        #expect(pkg.metadata.metadataObservations.map(\.key) == ["b"])
    }
}
