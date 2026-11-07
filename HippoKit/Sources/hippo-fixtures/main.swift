import Foundation
import Synchronization
import UniformTypeIdentifiers
import CaptureCore
import HippoTestSupport

// Regenerates the committed fixture packages. Deterministic: IDs, clock, time zone and producer are fixed.
// Usage: hippo-fixtures <output-directory>

struct Fixture {
    let name: String
    let draft: CaptureDraft
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: hippo-fixtures <output-directory>") }
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let layout = StoreLayout(root: out)
let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("hippo-fixtures-\(UUID().uuidString)", isDirectory: true)

let producer = Producer(appVersion: "0.1.0", build: "1", osVersion: "fixture")
let zone = TimeZone(identifier: "America/Los_Angeles")!
let base = Date(timeIntervalSince1970: 1_794_070_800) // 2026-11-07T17:00:00Z

func captureID(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", n))")! }
func started(_ n: Int) -> Date { base.addingTimeInterval(Double(n) * 60) }

func draft(_ n: Int, _ method: CaptureMethod, userNote: String? = nil, sharedTitle: String? = nil,
           urls: [CapturedURL] = [], attachments: [AttachmentSource] = []) -> CaptureDraft {
    CaptureDraft(captureID: captureID(n), startedAt: started(n), timeZone: zone, method: method,
                 userNote: userNote, sharedTitle: sharedTitle, urls: urls, attachments: attachments)
}

do {
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    // 1. text-note
    let note = Data("Call the plumber about the upstairs sink.".utf8)
    // 3. image: PNG with an embedded local capture time that carries no UTC offset.
    var plainExif = MediaMaker.ImageOptions()
    plainExif.exifDateTimeOriginal = "2026:11:07 09:03:00"
    // 4. mixed
    var geoExif = MediaMaker.ImageOptions()
    geoExif.exifDateTimeOriginal = "2026:11:07 08:30:00"
    geoExif.exifOffsetTimeOriginal = "-08:00"
    geoExif.gpsLatitude = 37.7749
    geoExif.gpsLongitude = -122.4194
    geoExif.gpsAltitude = 16
    geoExif.make = "Fixture"
    geoExif.model = "Camera 1"
    // 5. video, 6. voice recording
    let videoURL = scratch.appendingPathComponent("clip.mov")
    try await MediaMaker.writeVideo(to: videoURL)
    let audioURL = scratch.appendingPathComponent("memo.m4a")
    try MediaMaker.writeAudio(to: audioURL)

    let fixtures: [Fixture] = [
        Fixture(name: "text-note", draft: draft(1, .typedNote, attachments: [
            AttachmentSource(body: .data(note), originalFilename: nil, uti: "public.utf8-plain-text",
                             mimeType: "text/plain", representationSource: "typed_note")])),
        Fixture(name: "url-only", draft: draft(2, .shareExtension, sharedTitle: "Example item",
            urls: [CapturedURL(url: "https://example.com/item", source: "shared_payload")])),
        Fixture(name: "image", draft: draft(3, .shareExtension, attachments: [
            AttachmentSource(body: .data(try MediaMaker.imageData(width: 160, height: 120, type: .png, options: plainExif)),
                             originalFilename: "IMG_0003.PNG", uti: "public.png", mimeType: "image/png",
                             representationSource: "item_provider_file")])),
        Fixture(name: "mixed", draft: draft(4, .shareExtension, userNote: "Trail for next weekend",
            urls: [CapturedURL(url: "https://example.com/trail", source: "shared_payload")],
            attachments: [
                AttachmentSource(body: .data(try MediaMaker.imageData(width: 120, height: 80, type: .png)),
                                 originalFilename: "screenshot.png", uti: "public.png", mimeType: "image/png",
                                 representationSource: "item_provider_file"),
                AttachmentSource(body: .data(try MediaMaker.imageData(width: 160, height: 120, type: .jpeg, options: geoExif)),
                                 originalFilename: "trailhead.jpg", uti: "public.jpeg", mimeType: "image/jpeg",
                                 representationSource: "item_provider_file"),
                AttachmentSource(body: .data(try MediaMaker.pdfData()),
                                 originalFilename: "map.pdf", uti: "com.adobe.pdf", mimeType: "application/pdf",
                                 representationSource: "item_provider_file"),
            ])),
        Fixture(name: "video", draft: draft(5, .shareExtension, attachments: [
            AttachmentSource(body: .file(videoURL), originalFilename: "clip.mov", uti: "com.apple.quicktime-movie",
                             mimeType: "video/quicktime", representationSource: "item_provider_file")])),
        Fixture(name: "voice-recording", draft: draft(6, .voiceRecording, attachments: [
            AttachmentSource(body: .file(audioURL), originalFilename: "memo.m4a", uti: "com.apple.m4a-audio",
                             mimeType: "audio/mp4", representationSource: "recording")])),
    ]

    try? fm.removeItem(at: layout.capturesDir)
    for (index, fixture) in fixtures.enumerated() {
        let n = index + 1
        let counter = Mutex(0)
        let writer = PackageWriter(layout: layout, producer: producer, makeID: {
            let m = counter.withLock { value -> Int in value += 1; return value }
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%04d%08d", n, m))!
        })
        let package = try await writer.commit(fixture.draft)
        print("\(fixture.name) -> \(package.relativeDirectory)")
    }
    rmdir(layout.stagingDir.path) // removes only an empty directory
} catch {
    fail("hippo-fixtures failed: \(error)")
}
