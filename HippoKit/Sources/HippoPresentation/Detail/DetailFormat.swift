import Foundation

/// Value formatting for the details screen. Locale-independent where the output is numeric.
enum DetailFormat {
    /// "37.7749, -122.4194"
    static func coordinates(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// "m:ss", or nil for a negative or non-finite value.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds)
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }

    /// Whole minutes, then whole hours, rounded down: "3 min", "2 h".
    static func age(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }

    /// Parses an RFC 3339 string with a numeric offset or `Z`. Returns the instant and the offset in seconds.
    static func parseRFC3339(_ s: String) -> (date: Date, offset: Int)? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: s) ?? fractional.date(from: s) else { return nil }
        guard let last = s.last else { return nil }
        if last == "Z" || last == "z" { return (date, 0) }
        guard s.count >= 6 else { return nil }
        let tail = s.suffix(6)
        guard let sign = tail.first, sign == "+" || sign == "-", tail.dropFirst(3).first == ":",
              let h = Int(tail.dropFirst().prefix(2)), let m = Int(tail.suffix(2)) else { return nil }
        return (date, (sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
    }

    /// Parses a wall-clock time without zone ("2026-11-07T12:00:00", "2026:11:07 12:00:00") as if in UTC,
    /// so formatting it in UTC gives the same wall-clock back.
    static func parseWallClock(_ s: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func dateTime(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: zone))
    }
}
