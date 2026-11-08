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
