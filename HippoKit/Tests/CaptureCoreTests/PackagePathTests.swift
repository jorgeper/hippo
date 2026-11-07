import Testing
import Foundation
@testable import CaptureCore

@Suite struct PackagePathTests {
    @Test func partitionUsesLocalDateNotUTC() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let instant = ISO8601DateFormatter().date(from: "2026-11-08T07:30:00Z")!   // 23:30 Nov 7 in LA
        let c = PackagePath.localDateComponents(of: instant, in: la)
        #expect(PackagePath.captureDirectory(captureID: "abc", localDate: c) == "captures/2026/11/07/abc")
        #expect(PackagePath.localDatetimeString(instant, tz: la) == "2026-11-07T23:30:00-08:00")
    }

    @Test func dstFallBackOffsetIsCorrect() {   // 2026-11-01 01:30 PST after fall-back
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let instant = ISO8601DateFormatter().date(from: "2026-11-01T09:30:00Z")!
        #expect(PackagePath.localDatetimeString(instant, tz: la) == "2026-11-01T01:30:00-08:00")
    }

    @Test func utcZoneRendersNumericOffset() {
        let instant = ISO8601DateFormatter().date(from: "2026-11-07T09:00:00Z")!
        #expect(PackagePath.localDatetimeString(instant, tz: TimeZone(identifier: "UTC")!) == "2026-11-07T09:00:00+00:00")
    }

    @Test(arguments: [("photo.JPEG", "public.jpeg", "jpeg"), ("no-extension", "public.png", "png"),
                      ("😀.heic", "public.heic", "heic"), ("../evil.png", "public.png", "png"),
                      (".hidden", "public.data", "bin"),
                      (String(repeating: "a", count: 300) + ".toolongext1", "public.data", "bin")])
    func sanitizesExtensions(name: String, uti: String, ext: String) {
        #expect(PackagePath.sanitizedExtension(originalFilename: name, uti: uti) == ext)
    }

    @Test func attachmentPathUsesIDAndExtension() {
        #expect(PackagePath.attachmentPath(attachmentID: "0f", originalFilename: "a.PNG", uti: "public.png") == "content/0f.png")
    }

    @Test(arguments: ["", "/abs", "content/../x", "content/./x", "a\\b", "other/x.png", "content/\u{0}x",
                      "content/" + String(repeating: "a", count: 260)])
    func rejectsUnsafeRelativePaths(p: String) {
        #expect(throws: FormatError.self) { try PackagePath.validateRelative(p) }
    }

    @Test func acceptsValidPaths() throws {
        try PackagePath.validateRelative("metadata.json")
        try PackagePath.validateRelative("content/0f.png")
    }
}
