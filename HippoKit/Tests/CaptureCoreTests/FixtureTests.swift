import Testing
import Foundation
@testable import CaptureCore

@Suite struct FixtureTests {
    /// `<repo>/fixtures`, located from this file: HippoKit/Tests/CaptureCoreTests/FixtureTests.swift.
    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures", isDirectory: true)

    private struct Row { let name: String, id: String, method: String, types: [String] }

    /// Rows of the table in fixtures/README.md: `| name | capture id | method | content types |`.
    private static func readmeRows() throws -> [Row] {
        let text = try String(contentsOf: fixturesRoot.appendingPathComponent("README.md"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
            guard cells.count == 6, cells[2].hasPrefix("00000000-") else { return nil }
            return Row(name: cells[1], id: cells[2], method: cells[3],
                       types: cells[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    @Test func allFixturesValidateComplete() throws {
        let rows = try Self.readmeRows()
        #expect(rows.count == 7)

        let captures = Self.fixturesRoot.appendingPathComponent("packages/captures")
        let markers = try #require(FileManager.default.enumerator(at: captures, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "complete.json" }
        #expect(markers.count == 7)

        var seen: Set<String> = []
        for marker in markers {
            let directory = marker.deletingLastPathComponent()
            guard case .complete(let metadata, _) = PackageValidator.validate(directory: directory) else {
                Issue.record("\(directory.lastPathComponent) is not complete")
                continue
            }
            let row = try #require(rows.first { $0.id == metadata.captureID }, "no README row for \(metadata.captureID)")
            #expect(metadata.captureMethod.rawValue == row.method, "\(row.name) method")
            #expect(metadata.contentTypes.map(\.rawValue) == row.types, "\(row.name) content types")
            seen.insert(row.name)
        }
        #expect(seen.count == 7)
    }

    @Test func mixedFixtureHasTwoComments() throws {
        let directory = Self.fixturesRoot
            .appendingPathComponent("packages/captures/2026/11/07/00000000-0000-4000-8000-000000000004")
        let listing = PackageComments.load(directory: directory)
        #expect(listing.pendingCount == 0)
        #expect(listing.comments.count == 2)
        #expect(listing.comments.filter { $0.text != nil }.count == 1)
        let spoken = try #require(listing.comments.first { $0.audio != nil })
        #expect(spoken.audio?.media?.durationSeconds != nil)
    }

    // MARK: Format 1.1

    private static func packageDirectory(_ n: Int) -> URL {
        fixturesRoot.appendingPathComponent(
            "packages/captures/2026/11/07/00000000-0000-4000-8000-\(String(format: "%012d", n))")
    }

    @Test func legacyFixturesHaveNoMinor() throws {
        var files: [URL] = []
        for n in 1...6 {
            let directory = Self.packageDirectory(n)
            files.append(directory.appendingPathComponent("metadata.json"))
            files.append(directory.appendingPathComponent("complete.json"))
            guard case .complete = PackageValidator.validate(directory: directory) else {
                Issue.record("package \(n) is not complete")
                continue
            }
        }
        let comments = Self.packageDirectory(4).appendingPathComponent("comments")
        for name in try FileManager.default.contentsOfDirectory(atPath: comments.path) where name.hasSuffix(".json") {
            files.append(comments.appendingPathComponent(name))
        }
        for layer in ["device", "server"] {
            files.append(Self.fixturesRoot.appendingPathComponent(
                "packages/enrichments/\(layer)/2026/11/07/00000000-0000-4000-8000-000000000002/enrichment.json"))
        }
        #expect(files.count == 6 * 2 + 2 + 2)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("schema_minor"), "\(file.lastPathComponent) is a frozen 1.0 file")
        }
        for layer in ["device", "server"] {
            let url = Self.fixturesRoot.appendingPathComponent(
                "packages/enrichments/\(layer)/2026/11/07/00000000-0000-4000-8000-000000000002/enrichment.json")
            let doc = try EnrichmentJSON.decode(Data(contentsOf: url))
            #expect(doc.schemaMinor == nil)
        }
    }

    @Test func contextFixtureCarriesEverySignal() throws {
        let directory = Self.packageDirectory(7)
        guard case .complete(let metadata, _) = PackageValidator.validate(directory: directory) else {
            Issue.record("package 7 is not complete")
            return
        }
        #expect(metadata.schemaMinor == 1)
        #expect(metadata.captureMethod == .shareExtension)
        #expect((metadata.userNote ?? "").count >= 20)
        let keys = Set(metadata.metadataObservations.map(\.key))
        for key in [ContextKey.audioRoute, ContextKey.device, ContextKey.network, ContextKey.burst, ContextKey.enabled] {
            #expect(keys.contains(key), "missing \(key)")
        }
        let burst = try #require(metadata.metadataObservations.first { $0.key == ContextKey.burst })
        guard case .object(let fields) = burst.value, case .string(let previous)? = fields["previous_capture_id"] else {
            Issue.record("burst has no previous_capture_id")
            return
        }
        #expect(previous == "00000000-0000-4000-8000-000000000006")
        let location = try #require(metadata.captureLocation)
        #expect(location.altitudeMeters != nil)
        #expect(location.verticalAccuracyMeters != nil)
        #expect(location.speedMetersPerSecond != nil)
        #expect(location.speedAccuracyMetersPerSecond != nil)
        #expect(location.courseDegrees != nil)
        #expect(location.courseAccuracyDegrees != nil)
        #expect(metadata.attachments.map(\.uti).sorted() == ["com.apple.m4a-audio", "public.png"])

        let url = Self.fixturesRoot.appendingPathComponent(
            "packages/enrichments/device/2026/11/07/00000000-0000-4000-8000-000000000007/enrichment.json")
        let doc = try EnrichmentJSON.decode(Data(contentsOf: url))
        #expect(doc.schemaMinor == 1)
        #expect(doc.captureID == metadata.captureID)
        func payload<T: Decodable>(_ kind: FacetKind, as type: T.Type) throws -> T {
            let facet = try #require(doc.facets[kind.rawValue], "no \(kind.rawValue) facet")
            #expect(facet.status == .ok)
            let value = try #require(facet.data)
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        }
        let motion = try payload(.motionActivity, as: MotionActivityData.self)
        #expect(motion.atCapture?.activities == ["automotive"])
        let weather = try payload(.weather, as: WeatherData.self)
        #expect(weather.condition == "rain")
        let barcodes = try payload(.barcodes, as: BarcodesData.self)
        #expect(barcodes.items.first?.payload == "https://example.com/hippo")
        #expect(try !payload(.language, as: LanguageData.self).items.isEmpty)
        #expect(try !payload(.soundClassification, as: SoundClassificationData.self).items.isEmpty)
        #expect(try !payload(.screenshot, as: ScreenshotData.self).items.isEmpty)
    }
}
