import Foundation
import CaptureCore

/// Open-Meteo request building and response parsing (design §5.2). No API key.
public enum OpenMeteo {
    /// The forecast API serves about 92 days back; it is used for captures within this window, the archive otherwise.
    public static let forecastWindow: TimeInterval = 60 * 86_400

    static let hourly = "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,cloud_cover,wind_speed_10m,weather_code,is_day"

    /// Two decimals (about 1 km). Never negative zero.
    static func rounded(_ degrees: Double) -> Double { (degrees * 100).rounded() / 100 + 0.0 }

    private static func coordinate(_ degrees: Double) -> String { String(format: "%.2f", rounded(degrees)) }

    private static let gmt: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "GMT")!
        return c
    }()

    /// `2026-11-08T14:00`, the capture's hour in GMT.
    static func hourString(_ hour: Date) -> String {
        let p = gmt.dateComponents([.year, .month, .day, .hour], from: hour)
        return String(format: "%04d-%02d-%02dT%02d:00", p.year!, p.month!, p.day!, p.hour!)
    }

    /// `capturedAt` floored to the hour (GMT).
    static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// Forecast API when now − capturedAt ≤ forecastWindow, archive API otherwise. Coordinates rounded to 2 decimals.
    public static func request(latitude: Double, longitude: Double, capturedAt: Date, now: Date) -> URL {
        guard now.timeIntervalSince(capturedAt) <= forecastWindow else {
            return archiveRequest(latitude: latitude, longitude: longitude, capturedAt: capturedAt)
        }
        let hour = hourString(floorToHour(capturedAt))
        return URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(coordinate(latitude))&longitude=\(coordinate(longitude))"
                   + "&hourly=\(hourly)&wind_speed_unit=ms&timezone=GMT&start_hour=\(hour)&end_hour=\(hour)")!
    }

    public static func archiveRequest(latitude: Double, longitude: Double, capturedAt: Date) -> URL {
        let day = String(hourString(floorToHour(capturedAt)).prefix(10))
        return URL(string: "https://archive-api.open-meteo.com/v1/archive?latitude=\(coordinate(latitude))&longitude=\(coordinate(longitude))"
                   + "&hourly=\(hourly)&wind_speed_unit=ms&timezone=GMT&start_date=\(day)&end_date=\(day)")!
    }

    private struct Body: Decodable {
        struct Hourly: Decodable {
            var time: [String]
            var temperature2m: [Double?]?
            var apparentTemperature: [Double?]?
            var relativeHumidity2m: [Double?]?
            var precipitation: [Double?]?
            var cloudCover: [Double?]?
            var windSpeed10m: [Double?]?
            var weatherCode: [Double?]?
            var isDay: [Double?]?
            enum CodingKeys: String, CodingKey {
                case time, temperature2m = "temperature_2m", apparentTemperature = "apparent_temperature",
                     relativeHumidity2m = "relative_humidity_2m", precipitation, cloudCover = "cloud_cover",
                     windSpeed10m = "wind_speed_10m", weatherCode = "weather_code", isDay = "is_day"
            }
        }
        var hourly: Hourly
    }

    /// nil when the hour is missing from `hourly.time` or every variable is null for it. Throws on a body that is not Open-Meteo's.
    public static func parse(_ body: Data, hour: Date, latitude: Double, longitude: Double) throws -> WeatherData? {
        let h = try JSONDecoder().decode(Body.self, from: body).hourly
        let hour = floorToHour(hour)
        let wanted = hourString(hour)
        guard let i = h.time.firstIndex(of: wanted) else { return nil }
        // Server numbers are untrusted: non-finite values are dropped, and an integer field must be exactly integral and in range.
        func value(_ a: [Double?]?) -> Double? {
            guard let v = a.flatMap({ i < $0.count ? $0[i] : nil }), v.isFinite else { return nil }
            return v
        }
        let code = value(h.weatherCode).flatMap { Int(exactly: $0) }.flatMap { (0...99).contains($0) ? $0 : nil }
        let data = WeatherData(observedHour: hour, temperatureCelsius: value(h.temperature2m),
                               apparentTemperatureCelsius: value(h.apparentTemperature),
                               relativeHumidityPercent: value(h.relativeHumidity2m),
                               precipitationMillimeters: value(h.precipitation), cloudCoverPercent: value(h.cloudCover),
                               windSpeedMetersPerSecond: value(h.windSpeed10m), weatherCode: code,
                               condition: code.flatMap(condition(forCode:)), isDay: value(h.isDay).flatMap { $0 == 0 ? false : $0 == 1 ? true : nil },
                               source: "open-meteo.com", requestedLatitude: latitude, requestedLongitude: longitude)
        let empty = data.temperatureCelsius == nil && data.apparentTemperatureCelsius == nil
            && data.relativeHumidityPercent == nil && data.precipitationMillimeters == nil
            && data.cloudCoverPercent == nil && data.windSpeedMetersPerSecond == nil
            && data.weatherCode == nil && data.isDay == nil
        return empty ? nil : data
    }

    /// A coarse reading of a WMO code; nil for codes outside the table.
    public static func condition(forCode code: Int) -> String? {
        switch code {
        case 0, 1: "clear"
        case 2: "partly_cloudy"
        case 3: "cloudy"
        case 45, 48: "fog"
        case 51...55: "drizzle"
        case 56, 57, 66, 67: "freezing_rain"
        case 61...65: "rain"
        case 71...77, 85, 86: "snow"
        case 80...82: "showers"
        case 95...99: "thunderstorm"
        default: nil
        }
    }
}
