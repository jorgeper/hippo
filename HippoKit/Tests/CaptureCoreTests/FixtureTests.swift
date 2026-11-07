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
        #expect(rows.count == 6)

        let captures = Self.fixturesRoot.appendingPathComponent("packages/captures")
        let markers = try #require(FileManager.default.enumerator(at: captures, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "complete.json" }
        #expect(markers.count == 6)

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
        #expect(seen.count == 6)
    }
}
