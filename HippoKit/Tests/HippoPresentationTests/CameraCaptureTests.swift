import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CaptureCore
import ShareIntake
import HippoTestSupport
@testable import HippoPresentation

struct CameraCaptureTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func photoKeepsOrientationAndExifDate() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let intake = IntakeDirectory(storeRoot: root)
        let data = try MediaMaker.imageData(width: 64, height: 48)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let id = UUID()
        let metadata = PhotoMetadata(["{Exif}": ["DateTimeOriginal": "2026:11:09 10:00:00"],
                                      "{TIFF}": ["Orientation": 1, "Make": "Apple"]])

        let prepared = try CameraCapture.stage(.photo(image, orientation: 6, metadata: metadata), intake: intake,
                                               captureID: id, startedAt: Date(), timeZone: .gmt, location: nil)

        let attachment = try #require(prepared.draft.attachments.first)
        let isHEIC = attachment.uti == "public.heic"
        let name = isHEIC ? "0.heic" : "0.jpg"
        let file = intake.directory(for: id).appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(attachment.mimeType == (isHEIC ? "image/heic" : "image/jpeg"))
        if !isHEIC { #expect(attachment.uti == "public.jpeg") }
        #expect(attachment.representationSource == "camera")
        #expect(prepared.draft.method == .camera)
        #expect(prepared.previewImageURL == file)
        let size = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
        #expect(prepared.totalBytes == size)
        guard case .file(let url) = attachment.body else { Issue.record("not a file"); return }
        #expect(url == file)

        let written = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [String: Any])
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 6)
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        #expect(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int == 6)
        #expect(tiff?[kCGImagePropertyTIFFMake as String] as? String == "Apple")
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:11:09 10:00:00")
    }

    @Test func stageCarriesContext() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try MediaMaker.imageData(width: 16, height: 16)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let entry = MetadataObservation(key: "context.network", value: .object(["interface": .string("wifi")]),
                                        provenance: "nw_path")
        let prepared = try CameraCapture.stage(.photo(image, orientation: 1, metadata: PhotoMetadata([:])),
                                               intake: IntakeDirectory(storeRoot: root), captureID: UUID(),
                                               startedAt: Date(), timeZone: .gmt, location: nil, context: [entry])
        #expect(prepared.draft.observations == [entry])
    }

    @Test func videoIsMovedIntoIntake() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let intake = IntakeDirectory(storeRoot: root)
        let temp = root.appendingPathComponent("picker.mov")
        try await MediaMaker.writeVideo(to: temp)
        let id = UUID()

        let prepared = try CameraCapture.stage(.video(temp), intake: intake, captureID: id, startedAt: Date(),
                                               timeZone: .gmt, location: nil)

        let file = intake.directory(for: id).appendingPathComponent("0.mov")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        let attachment = try #require(prepared.draft.attachments.first)
        #expect(attachment.uti == "com.apple.quicktime-movie")
        #expect(attachment.mimeType == "video/quicktime")
        #expect(attachment.representationSource == "camera")
        #expect(prepared.previewImageURL == nil)
        #expect(prepared.draft.method == .camera)
        let size = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
        #expect(prepared.totalBytes == size)
    }
}
