import Foundation
import Testing
@testable import CaptureCore

@Suite struct EnrichmentSearchTextTests {
    private static let enrichments = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/packages/enrichments", isDirectory: true)

    private static func capture7(_ layer: EnrichmentLayer) throws -> EnrichmentDocument {
        try EnrichmentJSON.decode(Data(contentsOf: enrichments.appendingPathComponent(
            "\(layer.rawValue)/2026/11/07/00000000-0000-4000-8000-000000000007/enrichment.json")))
    }

    @Test func serverKindsJoinTheSearchText() throws {
        let text = EnrichmentSearchText.make(device: try Self.capture7(.device), server: try Self.capture7(.server))
        let lines = text.split(separator: "\n").map(String.init)
        for line in ["Cafe menu with specials code", "food",
                     "A printed cafe menu photographed on a table, with a QR code in the lower corner.",
                     "Ana", "In a car", "in_car", "Several captures in a row", "in_a_burst", "In daylight", "daylight"] {
            #expect(lines.contains(line), "\(line)")
        }
        #expect(!lines.contains("specials"))
    }

    @Test func serverKindsFollowTagsInOrder() throws {
        let text = EnrichmentSearchText.make(device: try Self.capture7(.device), server: try Self.capture7(.server))
        let lines = text.split(separator: "\n").map(String.init)
        let tail = ["cafe", "menu", "food", "Cafe menu with specials code",
                    "A printed cafe menu photographed on a table, with a QR code in the lower corner.",
                    "Ana", "In a car", "in_car", "Several captures in a row", "in_a_burst", "In daylight", "daylight"]
        #expect(Array(lines.suffix(tail.count)) == tail)
    }
}
