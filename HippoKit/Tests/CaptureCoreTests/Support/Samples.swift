import Foundation
@testable import CaptureCore

extension CaptureMetadata {
    /// Values from spec section 6's example. Test-only.
    static func sample(userNote: String? = "Gift idea", withAttachment: Bool = false) -> CaptureMetadata {
        let capturedAt = Date(timeIntervalSince1970: 1_794_070_800) // 2026-11-07T17:00:00Z
        var attachments: [Attachment] = []
        var location: CaptureLocation?
        if withAttachment {
            location = CaptureLocation(latitude: 37.7749, longitude: -122.4194, horizontalAccuracyMeters: 12.5,
                                       observedAt: capturedAt, provenance: "core_location")
            attachments = [Attachment(
                attachmentID: "11111111-2222-3333-4444-555555555555",
                relativePath: "content/11111111-2222-3333-4444-555555555555.jpg",
                originalFilename: "IMG_0001.JPG", uti: "public.jpeg", mimeType: "image/jpeg",
                byteCount: 1234, sha256: String(repeating: "ab", count: 32),
                representationSource: "original",
                media: MediaFacts(widthPixels: 4032, heightPixels: 3024, durationSeconds: nil,
                    embeddedCreatedAt: EmbeddedTimestamp(value: "2026-11-07T09:00:00", hasUTCOffset: false),
                    embeddedLocation: EmbeddedLocation(latitude: 37.7, longitude: -122.4, altitudeMeters: 10),
                    cameraMake: "Apple", cameraModel: "iPhone"))]
        }
        return CaptureMetadata(
            schemaVersion: 1, captureID: "0f8fad5b-d9cb-469f-a165-70867728950e",
            capturedAt: capturedAt, localDatetime: "2026-11-07T09:00:00-08:00",
            timezoneIdentifier: "America/Los_Angeles", utcOffsetSeconds: -28800,
            captureMethod: .typedNote, contentTypes: [.text],
            userNote: userNote, sharedTitle: nil, sharedText: nil,
            urls: [CapturedURL(url: "https://example.com/a", source: "detected_in_text")],
            sourceApplication: nil, captureLocation: location,
            producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "27.0"),
            attachments: attachments,
            metadataObservations: [MetadataObservation(key: "k", value: .object(["a": .array([.number(1), .bool(true), .string("s")])]), provenance: "test")],
            extensions: [:])
    }
}
