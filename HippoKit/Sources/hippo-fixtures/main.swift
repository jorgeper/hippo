import Foundation
import CryptoKit
import Synchronization
import UniformTypeIdentifiers
import CaptureCore
import HippoTestSupport

// Regenerates the committed fixture packages. Deterministic: IDs, clock, time zone and producer are fixed.
// Usage: hippo-fixtures <output-directory>
//        hippo-fixtures enrichments <root>   (adds enrichment files beside existing packages; never touches captures/)
//        hippo-fixtures context <root>       (adds format 1.1 package 7 and its device enrichment; never touches 1-6)

struct Fixture {
    let name: String
    let draft: CaptureDraft
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let isEnrichments = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "enrichments"
let isContext = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "context"
guard isEnrichments || isContext || CommandLine.arguments.count == 2 else {
    fail("usage: hippo-fixtures <output-directory> | hippo-fixtures enrichments <root> | hippo-fixtures context <root>")
}
let out = URL(fileURLWithPath: CommandLine.arguments[isEnrichments || isContext ? 2 : 1], isDirectory: true).standardizedFileURL
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

if isEnrichments {
    do {
        try writeEnrichmentFixtures(root: out)
        exit(0)
    } catch {
        fail("hippo-fixtures enrichments failed: \(error)")
    }
}

if isContext {
    do {
        try await writeContextFixture(root: out)
        exit(0)
    } catch {
        fail("hippo-fixtures context failed: \(error)")
    }
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
        if fixture.name == "mixed" {
            // One typed and one spoken comment, added after the capture (ids fixed: ...c001, ...c002).
            let ids = Mutex(0)
            let commentWriter = CommentWriter(layout: layout, producer: producer, makeID: {
                let m = ids.withLock { value -> Int in value += 1; return value }
                return UUID(uuidString: String(format: "00000000-0000-4000-8000-00000000c%03d", m))!
            })
            let typed = try commentWriter.add(.text("Bought this one."), to: package,
                                              now: started(4).addingTimeInterval(3_600), timeZone: zone)
            let spoken = try commentWriter.add(
                .audio(fileURL: audioURL, uti: "com.apple.m4a-audio", mimeType: "audio/mp4", durationSeconds: 1),
                to: package, now: started(4).addingTimeInterval(7_200), timeZone: zone)
            print("  comments: \(typed.relativePath), \(spoken.filePaths.joined(separator: ", "))")
        }
    }
    rmdir(layout.stagingDir.path) // removes only an empty directory
} catch {
    fail("hippo-fixtures failed: \(error)")
}

/// Writes a device and a server enrichment document for the url-only fixture (capture 2).
func writeEnrichmentFixtures(root: URL) throws {
    let fm = FileManager.default
    let directory = "captures/2026/11/07/\(captureID(2).uuidString.lowercased())"
    let digest = try StreamingHasher.digest(of: root.appendingPathComponent(directory).appendingPathComponent("complete.json")).sha256
    let generatedAt = Date(timeIntervalSince1970: 1_794_074_400) // 2026-11-07T18:00:00Z
    let producer = EnrichmentProducer(name: "hippo-fixtures", version: "1", build: "1")
    let id = captureID(2).uuidString.lowercased()

    func facet<T: Encodable>(_ status: FacetStatus, _ provenance: String, _ payload: T) throws -> Facet {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        return Facet(version: 1, status: status, generatedAt: generatedAt, provenance: provenance, data: value)
    }
    func write(_ doc: EnrichmentDocument, assets: [(name: String, bytes: Data)]) throws {
        let dir = root.appendingPathComponent(try EnrichmentPaths.remoteDirectory(doc.layer, packageDirectory: directory), isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        for asset in assets { try asset.bytes.write(to: dir.appendingPathComponent("assets/\(asset.name)")) }
        try EnrichmentJSON.encode(doc).write(to: dir.appendingPathComponent(EnrichmentPaths.documentName))
        if assets.isEmpty { try? fm.removeItem(at: dir.appendingPathComponent("assets")) }
        print("\(doc.layer.rawValue) -> \(dir.path)")
    }

    let jpeg = try MediaMaker.imageData(width: 64, height: 36, type: .jpeg)
    let sha = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
    let thumbnail = AssetRef(relativePath: "assets/\(sha).jpg", byteCount: Int64(jpeg.count), sha256: sha, mimeType: "image/jpeg")
    let device = EnrichmentDocument(
        schemaVersion: 1, captureID: id, layer: .device, packageDigest: digest, producer: producer, generatedAt: generatedAt,
        facets: [
            FacetKind.linkPreview.rawValue: try facet(.ok, "link_fetch", LinkPreviewData(items: [
                LinkPreviewItem(url: "https://example.com/item", title: "Example Domain", siteName: "example.com", thumbnail: thumbnail)])),
            FacetKind.sourceAppGuess.rawValue: try facet(.ok, "heuristic", SourceAppGuessData(app: "Safari", reason: "uti:public.url")),
        ])
    try write(device, assets: [("\(sha).jpg", jpeg)])

    let server = EnrichmentDocument(
        schemaVersion: 1, captureID: id, layer: .server, packageDigest: digest, producer: producer, generatedAt: generatedAt,
        facets: [
            FacetKind.summary.rawValue: try facet(.ok, "server_model", SummaryData(text: "A placeholder page used in documentation examples.")),
            FacetKind.tags.rawValue: try facet(.ok, "server_model", TagsData(values: ["example", "reference"])),
            FacetKind.linkPreview.rawValue: try facet(.ok, "server_fetch", LinkPreviewData(items: [
                LinkPreviewItem(url: "https://example.com/item", title: "Example Domain (server)")])),
        ])
    try write(server, assets: [])
}

/// Format 1.1 fixture: package 7 carrying every context signal, and its device enrichment document with the six
/// new facet kinds. Adds files only; packages 1-6 are frozen 1.0 files and are not touched. All inputs are fixed.
/// The facet payloads are hand-built (the audio is silence and the QR image is drawn here), not detector output.
func writeContextFixture(root: URL) async throws {
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("hippo-fixtures-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }
    let layout = StoreLayout(root: root)
    // Replaces only package 7, so the mode can be run again; packages 1-6 are never opened.
    try? fm.removeItem(at: root.appendingPathComponent("captures/2026/11/07/\(captureID(7).uuidString.lowercased())"))

    // One QR code on a phone-sized white canvas (so the screenshot guess is coherent), and 1 s of silence.
    let qr = try MediaMaker.qrCodePNG(payload: "https://example.com/hippo", canvasWidth: 1170, canvasHeight: 2532)
    let audioURL = scratch.appendingPathComponent("memo.m4a")
    try MediaMaker.writeAudio(to: audioURL)
    let audio = zeroingMovieTimestamps(try Data(contentsOf: audioURL))
    try audio.write(to: audioURL)

    let snapshot = ContextSnapshot(
        takenAt: started(7),
        audioRoute: ContextSnapshot.AudioRoute(
            outputs: [ContextSnapshot.Port(type: "car_audio", name: "CarPlay")],
            inputs: [ContextSnapshot.Port(type: "built_in_mic", name: "iPhone Microphone")]),
        device: ContextSnapshot.Device(batteryLevel: 0.62, batteryState: "charging", lowPowerMode: false,
                                       thermalState: "nominal", interfaceStyle: "dark", orientation: "portrait",
                                       locale: "en_US", uses24HourClock: false),
        network: ContextSnapshot.Network(interface: "wifi", expensive: false, constrained: false))
    var observations = ContextObservations.observations(from: snapshot)
    observations.append(ContextObservations.enabled(deviceContext: true, location: true))
    let previous = LastSaved(captureID: captureID(6).uuidString.lowercased(), capturedAt: started(6))
    if let burst = ContextObservations.burst(previous: previous, capturedAt: started(7)) { observations.append(burst) }

    var captureDraft = draft(7, .shareExtension,
        userNote: "Menu from the cafe on the corner, scan the code for the specials",
        attachments: [
            AttachmentSource(body: .data(qr), originalFilename: "IMG_0007.PNG", uti: "public.png", mimeType: "image/png",
                             representationSource: "item_provider_file"),
            AttachmentSource(body: .file(audioURL), originalFilename: "memo.m4a", uti: "com.apple.m4a-audio",
                             mimeType: "audio/mp4", representationSource: "recording"),
        ])
    captureDraft.location = CaptureLocation(
        latitude: 37.7749, longitude: -122.4194, horizontalAccuracyMeters: 12,
        observedAt: started(7).addingTimeInterval(-4), provenance: "core_location_request",
        altitudeMeters: 16, verticalAccuracyMeters: 8, speedMetersPerSecond: 11.2, speedAccuracyMetersPerSecond: 0.6,
        courseDegrees: 274, courseAccuracyDegrees: 12)
    captureDraft.observations = observations

    let counter = Mutex(0)
    let writer = PackageWriter(layout: layout, producer: producer, makeID: {
        let m = counter.withLock { value -> Int in value += 1; return value }
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%04d%08d", 7, m))!
    })
    let package = try await writer.commit(captureDraft)
    print("context -> \(package.relativeDirectory)")
    rmdir(layout.stagingDir.path) // removes only an empty directory
    let imageID = package.metadata.attachments[0].attachmentID
    let audioID = package.metadata.attachments[1].attachmentID

    let directory = package.relativeDirectory
    let digest = try StreamingHasher.digest(of: root.appendingPathComponent(directory).appendingPathComponent("complete.json")).sha256
    let generatedAt = started(7).addingTimeInterval(1_800)
    func facet<T: Encodable>(_ provenance: String, _ payload: T) throws -> Facet {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        return Facet(version: 1, status: .ok, generatedAt: generatedAt, provenance: provenance, data: value)
    }
    func sample(_ minutes: Double, _ activities: [String], _ confidence: String) -> MotionActivityData.Sample {
        .init(startedAt: started(7).addingTimeInterval(minutes * 60), activities: activities, confidence: confidence)
    }
    let motion = MotionActivityData(
        windowStart: started(7).addingTimeInterval(-600), windowEnd: started(7).addingTimeInterval(600),
        atCapture: sample(-4, ["automotive"], "high"),
        segments: [sample(-10, ["walking"], "medium"), sample(-4, ["automotive"], "high"),
                   sample(3, ["automotive", "stationary"], "high"), sample(7, ["walking"], "medium")])
    let weather = WeatherData(
        observedHour: base, temperatureCelsius: 14.2, apparentTemperatureCelsius: 12.9,
        relativeHumidityPercent: 81, precipitationMillimeters: 0.4, cloudCoverPercent: 100, windSpeedMetersPerSecond: 3.1,
        weatherCode: 61, condition: "rain", isDay: true, source: "open-meteo.com",
        requestedLatitude: 37.77, requestedLongitude: -122.42)
    let enrichmentProducer = EnrichmentProducer(name: "hippo-fixtures", version: "1", build: "1")
    let device = EnrichmentDocument(
        schemaVersion: FormatVersion.major, captureID: captureID(7).uuidString.lowercased(), layer: .device,
        packageDigest: digest, producer: enrichmentProducer, generatedAt: generatedAt,
        facets: [
            FacetKind.motionActivity.rawValue: try facet("core_motion", motion),
            FacetKind.weather.rawValue: try facet("open_meteo", weather),
            FacetKind.barcodes.rawValue: try facet("vision", BarcodesData(items: [
                .init(attachmentID: imageID, symbology: "qr", payload: "https://example.com/hippo", url: "https://example.com/hippo")])),
            FacetKind.language.rawValue: try facet("natural_language", LanguageData(items: [
                .init(source: "user_note", language: "en", confidence: 0.98)])),
            FacetKind.soundClassification.rawValue: try facet("sound_analysis", SoundClassificationData(items: [
                .init(attachmentID: audioID, labels: [.init(label: "speech", confidence: 0.62), .init(label: "music", confidence: 0.41)])])),
            FacetKind.screenshot.rawValue: try facet("heuristic", ScreenshotData(items: [
                .init(attachmentID: imageID, reason: "screen_size_match")])),
        ],
        schemaMinor: FormatVersion.minor)
    let dir = root.appendingPathComponent(try EnrichmentPaths.remoteDirectory(.device, packageDirectory: directory), isDirectory: true)
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try EnrichmentJSON.encode(device).write(to: dir.appendingPathComponent(EnrichmentPaths.documentName))
    print("device -> \(dir.path)")
}

/// AAC files from `AVAudioFile` record the time they were written in their `mvhd`, `tkhd` and `mdhd` boxes. Sets
/// those creation and modification times to 0 so the same inputs give the same bytes. Each box must be found
/// exactly once with a plausible size; otherwise the generator stops instead of writing unstable or damaged bytes.
func zeroingMovieTimestamps(_ input: Data) -> Data {
    var data = input
    for tag in ["mvhd", "tkhd", "mdhd"] {
        var hits: [Range<Int>] = []
        var from = data.startIndex
        while let hit = data.range(of: Data(tag.utf8), in: from..<data.endIndex) {
            hits.append(hit)
            from = hit.upperBound
        }
        guard hits.count == 1, let hit = hits.first else {
            fail("audio timestamps: expected exactly one \(tag) box, found \(hits.count)")
        }
        guard hit.lowerBound - 4 >= data.startIndex else { fail("audio timestamps: \(tag) has no size field") }
        let size = data[(hit.lowerBound - 4)..<hit.lowerBound].reduce(0) { $0 << 8 | Int($1) }
        guard size >= 12 + 8, hit.lowerBound - 4 + size <= data.endIndex else {
            fail("audio timestamps: \(tag) box size \(size) is not plausible")
        }
        let width = data[hit.upperBound] == 1 ? 8 : 4
        let start = hit.upperBound + 4 // after version and flags
        guard start + 2 * width <= hit.lowerBound - 4 + size else { fail("audio timestamps: \(tag) box is too short") }
        for i in start..<(start + 2 * width) { data[i] = 0 }
    }
    return data
}
