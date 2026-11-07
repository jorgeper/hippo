import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Extracts technical facts from media files. Never throws, never logs, and returns nil
/// when there is nothing to report.
public enum MediaInspector {
    private static let avTimeout: Duration = .seconds(2)

    public static func facts(for url: URL, uti: String) async -> MediaFacts? {
        await facts(for: url, uti: uti, timeout: avTimeout, load: avFacts)
    }

    /// Test seam: the AV loader and the deadline are injectable.
    static func facts(for url: URL, uti: String, timeout: Duration,
                      load: @escaping @Sendable (URL, Bool, FactsBox) async -> Void) async -> MediaFacts? {
        guard let type = UTType(uti) else { return nil }
        let facts: MediaFacts?
        if type.conforms(to: .image) {
            facts = imageFacts(url)
        } else if type.conforms(to: .audio) {
            facts = await timeBounded(timeout) { box in await load(url, false, box) }
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            facts = await timeBounded(timeout) { box in await load(url, true, box) }
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
              time.allSatisfy({ $0.count == 2 }),
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]),
              year >= 1, (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
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
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        var altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        if let a = altitude, (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1 { altitude = -abs(a) }
        return EmbeddedLocation(latitude: lat, longitude: lon, altitudeMeters: altitude)
    }

    // MARK: Audio / video

    /// Thread-safe accumulator so a deadline can return whatever has been gathered.
    final class FactsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var facts = MediaFacts()
        func update(_ body: (inout MediaFacts) -> Void) { lock.lock(); body(&facts); lock.unlock() }
        var snapshot: MediaFacts { lock.lock(); defer { lock.unlock() }; return facts }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire(_ body: () -> Void) {
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            if first { body() }
        }
    }

    /// Returns at the deadline even if `work` ignores cancellation: the caller resumes from whichever
    /// unstructured task finishes first, and the load is left to finish (or hang) on its own.
    private static func timeBounded(_ timeout: Duration, _ work: @escaping @Sendable (FactsBox) async -> Void) async -> MediaFacts {
        let box = FactsBox()
        let once = Once()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let loader = Task { await work(box); once.fire { cont.resume() } }
            Task {
                try? await Task.sleep(for: timeout)
                loader.cancel()
                once.fire { cont.resume() }
            }
        }
        return box.snapshot
    }

    @Sendable private static func avFacts(_ url: URL, wantsVideo: Bool, into box: FactsBox) async {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite, duration.seconds >= 0 {
            box.update { $0.durationSeconds = duration.seconds }
        }
        if wantsVideo,
           let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            box.update {
                $0.widthPixels = Int(abs(rect.width).rounded())
                $0.heightPixels = Int(abs(rect.height).rounded())
            }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
