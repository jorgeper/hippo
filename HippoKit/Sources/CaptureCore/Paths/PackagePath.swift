import Foundation
import UniformTypeIdentifiers

/// Package-relative path construction and validation. Partitions by the capture's local date.
public enum PackagePath {
    public static func captureDirectory(captureID: String, localDate: DateComponents) -> String {
        let y = localDate.year ?? 0, m = localDate.month ?? 0, d = localDate.day ?? 0
        return "captures/\(pad(y, 4))/\(pad(m, 2))/\(pad(d, 2))/\(captureID)"
    }

    public static func localDateComponents(of instant: Date, in tz: TimeZone) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.dateComponents([.year, .month, .day], from: instant)
    }

    /// RFC 3339 local time, whole seconds, numeric offset (`+00:00` for UTC, never `Z`).
    public static func localDatetimeString(_ instant: Date, tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        let offset = tz.secondsFromGMT(for: instant)
        let sign = offset < 0 ? "-" : "+"
        let abs = Swift.abs(offset)
        return "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0, 2))-\(pad(c.day ?? 0, 2))"
            + "T\(pad(c.hour ?? 0, 2)):\(pad(c.minute ?? 0, 2)):\(pad(c.second ?? 0, 2))"
            + "\(sign)\(pad(abs / 3600, 2)):\(pad(abs % 3600 / 60, 2))"
    }

    public static func attachmentPath(attachmentID: String, originalFilename: String?, uti: String) -> String {
        "content/\(attachmentID).\(sanitizedExtension(originalFilename: originalFilename, uti: uti))"
    }

    public static func sanitizedExtension(originalFilename: String?, uti: String) -> String {
        if let name = originalFilename {
            let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
            // A dot at index 0 is a hidden file, not an extension.
            if let dot = base.lastIndex(of: "."), dot != base.startIndex {
                let ext = base[base.index(after: dot)...].lowercased()
                if isSafeExtension(ext) { return ext }
            }
        }
        if let type = UTType(uti) {
            if let preferred = type.preferredFilenameExtension, isSafeExtension(preferred) {
                return preferred
            }
            // public.utf8-plain-text and friends declare no extension of their own.
            if type.conforms(to: .plainText) { return "txt" }
        }
        return "bin"
    }

    public static func validateRelative(_ path: String) throws(FormatError) {
        if path.isEmpty { throw .unsafePath("empty") }
        if path.utf8.count > 255 { throw .unsafePath("too long") }
        if path.hasPrefix("/") { throw .unsafePath("absolute") }
        if path.contains("\\") { throw .unsafePath("backslash") }
        if path.unicodeScalars.contains(where: { $0.value == 0 }) { throw .unsafePath("NUL character") }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: { $0.isEmpty }) { throw .unsafePath("empty segment") }
        if segments.contains(where: { $0 == "." || $0 == ".." }) { throw .unsafePath("dot segment") }
        if path != "metadata.json" && !path.hasPrefix("content/") { throw .unsafePath("outside content") }
    }

    private static func isSafeExtension(_ s: String) -> Bool {
        (1...10).contains(s.utf8.count)
            && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) }
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
