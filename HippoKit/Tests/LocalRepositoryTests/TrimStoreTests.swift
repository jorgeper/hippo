import Foundation
import Testing
import CaptureCore
@testable import LocalRepository

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct TrimStoreTests {
    @Test func recordReadTotalsAndCascade() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        _ = try DestinationStore(db: h.db).connect(Destination(id: "d", providerKind: "dropbox", accountIdentifier: "a",
                                                               remoteRoot: "/Hippo", displayName: "Dropbox", status: .active))
        let store = TrimStore(db: h.db)
        let a = try await h.add(note: "a").metadata.captureID
        let b = try await h.add(note: "b").metadata.captureID
        let c = try await h.add(note: "c").metadata.captureID

        func item(_ capture: String, _ att: String, bytes: Int64, state: TrimState = .trimmed) -> TrimmedAttachment {
            TrimmedAttachment(captureID: capture, attachmentID: att, relativePath: "attachments/\(att).bin", byteCount: bytes,
                              sha256: "h-\(att)", destinationID: "d", state: state, trimmedAt: t0)
        }
        try store.record(item(a, "a1", bytes: 100))
        try store.record(item(a, "a2", bytes: 50))
        try store.record(item(b, "b1", bytes: 1_000))
        try store.record(item(b, "b1", bytes: 2_000))  // upsert

        #expect(try store.trimmed(captureID: a).map(\.attachmentID) == ["a1", "a2"])
        #expect(try store.trimmed(captureID: b) == [item(b, "b1", bytes: 2_000)])
        #expect(try store.trimmedPaths(captureID: a) == ["attachments/a1.bin", "attachments/a2.bin"])
        #expect(try store.captureIDsWithTrimmed(in: [a, b, c]) == [a, b])
        #expect(try store.captureIDsWithTrimmed(in: []).isEmpty)
        let totals = try store.totals(destinationID: "d")
        #expect(totals.captures == 2)
        #expect(totals.bytes == 2_150)
        #expect(try store.totals(destinationID: "none") == (0, 0))
        #expect(try store.allTrimmedAttachmentIDs() == ["a1", "a2", "b1"])

        try store.setState(captureID: a, attachmentID: "a1", state: .mismatch)
        #expect(try store.trimmed(captureID: a).first?.state == .mismatch)
        try store.remove(captureID: a, attachmentID: "a2")
        #expect(try store.trimmed(captureID: a).map(\.attachmentID) == ["a1"])

        try h.index.remove(captureID: b)
        #expect(try store.trimmed(captureID: b).isEmpty)
        #expect(try store.allTrimmedAttachmentIDs() == ["a1"])
    }
}
