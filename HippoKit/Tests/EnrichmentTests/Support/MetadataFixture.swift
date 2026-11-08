import Foundation
import CaptureCore
import Enrichment

/// A metadata value for enricher tests that don't need a store.
func fixtureMetadata(method: CaptureMethod = .shareExtension, zone: String = "America/Los_Angeles",
                     userNote: String? = nil, sharedText: String? = nil, urls: [String] = [],
                     attachments: [Attachment] = [], observations: [MetadataObservation] = []) -> CaptureMetadata {
    CaptureMetadata(schemaVersion: 1, captureID: "c1", capturedAt: Date(timeIntervalSince1970: 1_794_081_600),
                    localDatetime: "2026-11-07T12:00:00-08:00", timezoneIdentifier: zone, utcOffsetSeconds: -28800,
                    captureMethod: method, contentTypes: [], userNote: userNote, sharedTitle: nil, sharedText: sharedText,
                    urls: urls.map { CapturedURL(url: $0, source: "shared") }, sourceApplication: nil,
                    captureLocation: nil, producer: Producer(appVersion: "1", build: "1", osVersion: "t"),
                    attachments: attachments, metadataObservations: observations, extensions: [:])
}

func fixtureInput(_ m: CaptureMetadata, noteBody: String? = nil, current: EnrichmentDocument? = nil,
                  packageURL: URL = URL(fileURLWithPath: "/nonexistent")) -> EnricherInput {
    EnricherInput(captureID: m.captureID, metadata: m, packageURL: packageURL, noteBody: noteBody, current: current)
}
