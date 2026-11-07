import Testing
import Foundation
import UniformTypeIdentifiers
@testable import CaptureCore

@Suite struct MediaInspectorTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    private func write(_ data: Data, ext: String) throws -> URL {
        let url = tempURL(ext)
        try data.write(to: url)
        return url
    }

    @Test func imageDimensionsAndNoExif() async throws {
        let url = try write(MediaMaker.imageData(width: 120, height: 80, type: .png), ext: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = await MediaInspector.facts(for: url, uti: "public.png")
        #expect(facts?.widthPixels == 120)
        #expect(facts?.heightPixels == 80)
        #expect(facts?.embeddedCreatedAt == nil)
        #expect(facts?.embeddedLocation == nil)
    }

    @Test func exifTimeWithoutOffsetStaysUnzoned() async throws {
        var o = MediaMaker.ImageOptions()
        o.exifDateTimeOriginal = "2026:11:07 09:11:00"
        let url = try write(MediaMaker.imageData(width: 10, height: 10, options: o), ext: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = await MediaInspector.facts(for: url, uti: "public.jpeg")
        #expect(facts?.embeddedCreatedAt == EmbeddedTimestamp(value: "2026-11-07T09:11:00", hasUTCOffset: false))
    }

    @Test func exifTimeWithOffset() async throws {
        var o = MediaMaker.ImageOptions()
        o.exifDateTimeOriginal = "2026:11:07 09:11:00"
        o.exifOffsetTimeOriginal = "-08:00"
        let url = try write(MediaMaker.imageData(width: 10, height: 10, options: o), ext: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = await MediaInspector.facts(for: url, uti: "public.jpeg")
        #expect(facts?.embeddedCreatedAt == EmbeddedTimestamp(value: "2026-11-07T09:11:00-08:00", hasUTCOffset: true))
    }

    @Test func malformedOffsetIsTreatedAsAbsent() async throws {
        var o = MediaMaker.ImageOptions()
        o.exifDateTimeOriginal = "2026:11:07 09:11:00"
        o.exifOffsetTimeOriginal = "PST"
        let url = try write(MediaMaker.imageData(width: 10, height: 10, options: o), ext: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = await MediaInspector.facts(for: url, uti: "public.jpeg")
        #expect(facts?.embeddedCreatedAt == EmbeddedTimestamp(value: "2026-11-07T09:11:00", hasUTCOffset: false))
    }

    @Test func gpsSouthWestIsNegative() async throws {
        var o = MediaMaker.ImageOptions()
        o.gpsLatitude = -33.5
        o.gpsLongitude = -70.6
        o.gpsAltitude = -12
        o.make = "Acme"
        o.model = "Cam 1"
        let url = try write(MediaMaker.imageData(width: 10, height: 10, options: o), ext: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = await MediaInspector.facts(for: url, uti: "public.jpeg")
        let loc = try #require(facts?.embeddedLocation)
        #expect(abs(loc.latitude - -33.5) < 0.0001)
        #expect(abs(loc.longitude - -70.6) < 0.0001)
        #expect(abs((loc.altitudeMeters ?? 0) - -12) < 0.0001)
        #expect(facts?.cameraMake == "Acme")
        #expect(facts?.cameraModel == "Cam 1")
    }

    @Test func audioDuration() async throws {
        let url = tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try MediaMaker.writeAudio(to: url)
        let facts = await MediaInspector.facts(for: url, uti: "com.apple.m4a-audio")
        let d = try #require(facts?.durationSeconds)
        #expect(abs(d - 1.0) < 0.1)
    }

    @Test func videoDurationAndSize() async throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await MediaMaker.writeVideo(to: url)
        let facts = await MediaInspector.facts(for: url, uti: "com.apple.quicktime-movie")
        let d = try #require(facts?.durationSeconds)
        #expect(abs(d - 1.0) < 0.1)
        #expect(facts?.widthPixels == 64)
        #expect(facts?.heightPixels == 48)
    }

    @Test func garbageFileReturnsNil() async throws {
        for (ext, uti) in [("jpg", "public.jpeg"), ("m4a", "com.apple.m4a-audio"), ("mov", "com.apple.quicktime-movie")] {
            let url = try write(Data("not media at all".utf8), ext: ext)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(await MediaInspector.facts(for: url, uti: uti) == nil)
        }
    }

    @Test func otherTypesReturnNilWithoutReading() async {
        let missing = tempURL("txt")
        #expect(await MediaInspector.facts(for: missing, uti: "public.plain-text") == nil)
    }
}
