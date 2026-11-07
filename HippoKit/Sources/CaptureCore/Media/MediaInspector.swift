import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Extracts technical facts from media files. Never throws, never logs, and returns nil
/// when there is nothing to report.
public enum MediaInspector {
    private static let avTimeout: Duration = .seconds(2)

    public static func facts(for url: URL, uti: String) async -> MediaFacts? {
        guard let type = UTType(uti) else { return nil }
        let facts: MediaFacts?
        if type.conforms(to: .image) {
            facts = imageFacts(url)
        } else if type.conforms(to: .audio) {
            facts = await timeBounded { await avFacts(url, wantsVideo: false) }
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            facts = await timeBounded { await avFacts(url, wantsVideo: true) }
        } else {
            return nil
        }
        guard let facts, facts != MediaFacts() else { return nil }
        return facts
    }

    // MARK: Images

    private static func imageFacts(_ url: URL) -> MediaFacts? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        var facts = MediaFacts()
        // Raw pixel dimensions; orientation is deliberately not applied.
        facts.widthPixels = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        facts.heightPixels = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            facts.embeddedCreatedAt = timestamp(exifDate: raw, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            facts.embeddedLocation = location(gps)
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        facts.cameraMake = nonEmpty(tiff?[kCGImagePropertyTIFFMake] as? String)
        facts.cameraModel = nonEmpty(tiff?[kCGImagePropertyTIFFModel] as? String)
        return facts
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// "2026:11:07 09:11:00" -> "2026-11-07T09:11:00", plus a well-formed "+/-HH:MM" offset when present.
    /// The capture time zone is never applied.
    private static func timestamp(exifDate raw: String, offset: String?) -> EmbeddedTimestamp? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let date = parts[0].split(separator: ":", omittingEmptySubsequences: false)
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard date.count == 3, time.count == 3,
              (date + time).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              date[0].count == 4, date[1].count == 2, date[2].count == 2,
              time.allSatisfy({ $0.count == 2 }) else { return nil }
        let value = "\(date[0])-\(date[1])-\(date[2])T\(time[0]):\(time[1]):\(time[2])"
        if let offset = offset?.trimmingCharacters(in: .whitespaces), isValidOffset(offset) {
            return EmbeddedTimestamp(value: value + offset, hasUTCOffset: true)
        }
        return EmbeddedTimestamp(value: value, hasUTCOffset: false)
    }

    private static func isValidOffset(_ s: String) -> Bool {
        let c = Array(s)
        guard c.count == 6, c[0] == "+" || c[0] == "-", c[3] == ":",
              [1, 2, 4, 5].allSatisfy({ c[$0].isASCIIDigit }),
              let h = Int(String(c[1...2])), let m = Int(String(c[4...5])) else { return false }
        return h <= 14 && m < 60
    }

    private static func location(_ gps: [CFString: Any]) -> EmbeddedLocation? {
        guard var lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              var lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -abs(lat) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -abs(lon) }
        var altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        if let a = altitude, (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1 { altitude = -abs(a) }
        return EmbeddedLocation(latitude: lat, longitude: lon, altitudeMeters: altitude)
    }

    // MARK: Audio / video

    /// Runs `work` against a 2 s deadline; returns nil if the deadline wins.
    private static func timeBounded(_ work: @escaping @Sendable () async -> MediaFacts?) async -> MediaFacts? {
        await withTaskGroup(of: MediaFacts?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: avTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func avFacts(_ url: URL, wantsVideo: Bool) async -> MediaFacts? {
        let asset = AVURLAsset(url: url)
        var facts = MediaFacts()
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite, duration.seconds >= 0 {
            facts.durationSeconds = duration.seconds
        }
        if wantsVideo,
           let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            facts.widthPixels = Int(abs(rect.width).rounded())
            facts.heightPixels = Int(abs(rect.height).rounded())
        }
        return facts
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
