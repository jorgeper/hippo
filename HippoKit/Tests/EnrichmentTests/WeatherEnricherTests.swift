import Foundation
import Testing
import CaptureCore
@testable import Enrichment

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    let handler: @Sendable (URL) throws -> Data
    init(_ handler: @escaping @Sendable (URL) throws -> Data) { self.handler = handler }
    var urls: [URL] { lock.withLock { _urls } }
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        lock.withLock { _urls.append(url) }
        return try handler(url)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero
    private var _sleeps: [Duration] = []
    var now: ContinuousClock.Instant { lock.withLock { base + offset } }
    func advance(_ d: Duration) { lock.withLock { offset += d } }
    func sleep(_ d: Duration) { lock.withLock { _sleeps.append(d) } }
    var sleeps: [Duration] { lock.withLock { _sleeps } }
    func pacer() -> RequestPacer {
        RequestPacer(sleep: { self.sleep($0) }, now: { self.now })
    }
}

private let captured = Date(timeIntervalSince1970: 1_794_148_632)   // 2026-11-08T14:37:12Z
private let t0 = captured

private func location(_ lat: Double = 47.61234, _ lon: Double = -122.33456) -> CaptureLocation {
    CaptureLocation(latitude: lat, longitude: lon, horizontalAccuracyMeters: 10, observedAt: captured, provenance: "core_location")
}

private func metadata(at date: Date = captured, location loc: CaptureLocation? = location()) -> CaptureMetadata {
    var m = fixtureMetadata()
    m.capturedAt = date
    m.captureLocation = loc
    return m
}

private func body(hours: [String] = ["2026-11-08T14:00"], temp: String = "14.2", code: String = "61", isDay: String = "0") -> Data {
    func col(_ v: String) -> String { "[" + hours.map { _ in v }.joined(separator: ",") + "]" }
    let times = hours.map { "\"\($0)\"" }.joined(separator: ",")
    return Data("""
    {"hourly":{"time":[\(times)],"temperature_2m":\(col(temp)),"apparent_temperature":\(col("12.9")),
    "relative_humidity_2m":\(col("81")),"precipitation":\(col("0.4")),"cloud_cover":\(col("100")),
    "wind_speed_10m":\(col("3.1")),"weather_code":\(col(code)),"is_day":\(col(isDay))}}
    """.utf8)
}

private func day(_ prefix: String) -> [String] { (0..<24).map { prefix + "T" + String(format: "%02d", $0) + ":00" } }

private func decode(_ out: EnricherOutput) throws -> WeatherData {
    try JSONDecoder().decode(WeatherData.self, from: try JSONEncoder().encode(try #require(out.data)))
}

private let forecastHost = "api.open-meteo.com"
private let archiveHost = "archive-api.open-meteo.com"

@Suite struct WeatherEnricherTests {
    private func enricher(_ http: FakeHTTP, clock: Clock = Clock(), now: Date? = nil) -> WeatherEnricher {
        let n = now ?? captured.addingTimeInterval(2 * 86_400)
        return WeatherEnricher(http: http, pacer: clock.pacer(), now: { n })
    }

    @Test func descriptor() {
        let e = enricher(FakeHTTP { _ in Data() })
        #expect(e.kind == .weather)
        #expect(e.version == 1)
        #expect(e.usesNetwork)
        #expect(e.inputs.isEmpty)
        #expect(e.applies(to: metadata()))
    }

    @Test func noLocationNotApplicable() async {
        let e = enricher(FakeHTTP { _ in Data() })
        #expect(!e.applies(to: metadata(location: nil)))
        await #expect(throws: EnrichmentError.notApplicable(code: "no_location")) {
            _ = try await e.run(fixtureInput(metadata(location: nil)))
        }
    }

    @Test func forecastURLForRecentCapture() {
        let url = OpenMeteo.request(latitude: 47.61234, longitude: -122.33456, capturedAt: captured,
                                    now: captured.addingTimeInterval(2 * 86_400))
        #expect(url.absoluteString == "https://api.open-meteo.com/v1/forecast?latitude=47.61&longitude=-122.33"
                + "&hourly=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,cloud_cover,wind_speed_10m,weather_code,is_day"
                + "&wind_speed_unit=ms&timezone=GMT&start_hour=2026-11-08T14:00&end_hour=2026-11-08T14:00")
    }

    @Test func archiveURLForOldCapture() {
        let url = OpenMeteo.request(latitude: 47.61234, longitude: -122.33456, capturedAt: captured,
                                    now: captured.addingTimeInterval(61 * 86_400))
        #expect(url.host == archiveHost)
        #expect(url.absoluteString == "https://archive-api.open-meteo.com/v1/archive?latitude=47.61&longitude=-122.33"
                + "&hourly=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,cloud_cover,wind_speed_10m,weather_code,is_day"
                + "&wind_speed_unit=ms&timezone=GMT&start_date=2026-11-08&end_date=2026-11-08")
    }

    @Test func windowBoundary() {
        let exactly = OpenMeteo.request(latitude: 1, longitude: 1, capturedAt: captured, now: captured.addingTimeInterval(60 * 86_400))
        #expect(exactly.host == forecastHost)
        let over = OpenMeteo.request(latitude: 1, longitude: 1, capturedAt: captured, now: captured.addingTimeInterval(60 * 86_400 + 1))
        #expect(over.host == archiveHost)
    }

    @Test func clockSkewUsesForecast() async throws {
        let http = FakeHTTP { _ in body() }
        let out = try await enricher(http, now: captured.addingTimeInterval(-3600)).run(fixtureInput(metadata()))
        #expect(out.status == .ok)
        #expect(http.urls.map(\.host) == [forecastHost])
    }

    @Test func wholeAndNegativeCoordinatesAreWellFormed() throws {
        let url = OpenMeteo.request(latitude: 47.0, longitude: -0.004, capturedAt: captured, now: captured)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "latitude" }?.value == "47.00")
        #expect(items.first { $0.name == "longitude" }?.value == "0.00")   // not "-0.00"
        let south = OpenMeteo.request(latitude: -33.8688, longitude: 151.2093, capturedAt: captured, now: captured)
        #expect(south.absoluteString.contains("latitude=-33.87&longitude=151.21"))
    }

    @Test func lastMinutesOfADayPickHour23() async throws {
        let late = Date(timeIntervalSince1970: 1_794_182_340)   // 2026-11-08T23:59:00Z
        let http = FakeHTTP { _ in
            var times = day("2026-11-08")
            times[23] = "2026-11-08T23:00"
            return Data("""
            {"hourly":{"time":[\(times.map { "\"\($0)\"" }.joined(separator: ","))],
            "temperature_2m":[\((0..<24).map(String.init).joined(separator: ","))],"weather_code":[\(Array(repeating: "3", count: 24).joined(separator: ","))]}}
            """.utf8)
        }
        let out = try await enricher(http, now: late.addingTimeInterval(90 * 86_400)).run(fixtureInput(metadata(at: late)))
        #expect(http.urls.first?.absoluteString.contains("start_date=2026-11-08&end_date=2026-11-08") == true)
        let data = try decode(out)
        #expect(data.temperatureCelsius == 23)
        #expect(data.observedHour == Date(timeIntervalSince1970: 1_794_182_340 - 59 * 60))
    }

    @Test func parsesEveryField() async throws {
        let http = FakeHTTP { _ in body() }
        let out = try await enricher(http).run(fixtureInput(metadata()))
        #expect(out.status == .ok)
        #expect(out.provenance == "open_meteo")
        let d = try decode(out)
        #expect(d.observedHour == HippoJSON.parseTimestamp("2026-11-08T14:00:00Z"))
        #expect(d.temperatureCelsius == 14.2)
        #expect(d.apparentTemperatureCelsius == 12.9)
        #expect(d.relativeHumidityPercent == 81)
        #expect(d.precipitationMillimeters == 0.4)
        #expect(d.cloudCoverPercent == 100)
        #expect(d.windSpeedMetersPerSecond == 3.1)
        #expect(d.weatherCode == 61)
        #expect(d.condition == "rain")
        #expect(d.isDay == false)
        #expect(d.source == "open-meteo.com")
        #expect(d.requestedLatitude == 47.61)
        #expect(d.requestedLongitude == -122.33)
    }

    @Test func isDayTrueFromOne() throws {
        let d = try #require(try OpenMeteo.parse(body(isDay: "1"), hour: captured, latitude: 1, longitude: 2))
        #expect(d.isDay == true)
    }

    @Test func archivePicksTheHour() async throws {
        let http = FakeHTTP { _ in
            Data("""
            {"hourly":{"time":[\(day("2026-11-08").map { "\"\($0)\"" }.joined(separator: ","))],
            "temperature_2m":[\((0..<24).map { String(Double($0) + 0.5) }.joined(separator: ","))]}}
            """.utf8)
        }
        let out = try await enricher(http, now: captured.addingTimeInterval(90 * 86_400)).run(fixtureInput(metadata()))
        #expect(try decode(out).temperatureCelsius == 14.5)
        #expect(http.urls.map(\.host) == [archiveHost])
    }

    @Test func nullVariablesOmitted() async throws {
        let http = FakeHTTP { _ in body(temp: "null") }
        let out = try await enricher(http).run(fixtureInput(metadata()))
        #expect(out.status == .ok)
        let json = try String(decoding: JSONEncoder().encode(try #require(out.data)), as: UTF8.self)
        #expect(!json.contains("\"temperature_celsius\""))
        #expect(json.contains("apparent_temperature_celsius"))
        #expect(try decode(out).temperatureCelsius == nil)
    }

    @Test func allNullIsEmpty() async throws {
        let http = FakeHTTP { _ in Data(#"{"hourly":{"time":["2026-11-08T14:00"],"temperature_2m":[null],"weather_code":[null],"is_day":[null]}}"#.utf8) }
        let out = try await enricher(http).run(fixtureInput(metadata()))
        #expect(out.status == .empty)
        #expect(out.data == nil)
    }

    @Test func hourMissingIsEmpty() async throws {
        let http = FakeHTTP { _ in body(hours: ["2026-11-08T15:00"]) }
        #expect(try await enricher(http).run(fixtureInput(metadata())).status == .empty)
        let none = FakeHTTP { _ in Data(#"{"hourly":{"time":[]}}"#.utf8) }
        #expect(try await enricher(none).run(fixtureInput(metadata())).status == .empty)
    }

    @Test func conditionTable() {
        let table: [(ClosedRange<Int>, String)] = [
            (0...1, "clear"), (2...2, "partly_cloudy"), (3...3, "cloudy"), (45...45, "fog"), (48...48, "fog"),
            (51...55, "drizzle"), (56...57, "freezing_rain"), (61...65, "rain"), (66...67, "freezing_rain"),
            (71...77, "snow"), (80...82, "showers"), (85...86, "snow"), (95...99, "thunderstorm")]
        for (codes, name) in table { for c in codes { #expect(OpenMeteo.condition(forCode: c) == name, "code \(c)") } }
        for c in [4, 44, 58, 68, 78, 83, 90, 100, -1] { #expect(OpenMeteo.condition(forCode: c) == nil, "code \(c)") }
    }

    @Test func unknownCodeOmitsCondition() throws {
        let d = try #require(try OpenMeteo.parse(body(code: "4"), hour: captured, latitude: 1, longitude: 2))
        #expect(d.weatherCode == 4)
        #expect(d.condition == nil)
    }

    @Test func failuresClassified() async throws {
        struct Boom: Error {}
        let m = metadata()
        let thrown = FakeHTTP { _ in throw Boom() }
        await #expect(throws: EnrichmentError.transient(code: "weather_network")) { _ = try await enricher(thrown).run(fixtureInput(m)) }
        for code in ["http_5xx"] {
            let http = FakeHTTP { _ in throw EnrichmentError.transient(code: code) }
            await #expect(throws: EnrichmentError.transient(code: code)) { _ = try await enricher(http).run(fixtureInput(m)) }
            #expect(http.urls.count == 1)
        }
        // 429 reaches the enricher as the fetcher's transient http_4xx.
        let limited = FakeHTTP { _ in throw EnrichmentError.transient(code: "http_4xx") }
        await #expect(throws: EnrichmentError.transient(code: "http_4xx")) { _ = try await enricher(limited).run(fixtureInput(m)) }
        #expect(limited.urls.count == 1)

        let bad = FakeHTTP { _ in Data("not json".utf8) }
        await #expect(throws: EnrichmentError.permanent(code: "weather_bad_response")) { _ = try await enricher(bad).run(fixtureInput(m)) }
        let noHourly = FakeHTTP { _ in Data("{}".utf8) }
        await #expect(throws: EnrichmentError.permanent(code: "weather_bad_response")) { _ = try await enricher(noHourly).run(fixtureInput(m)) }
    }

    @Test func forecast400FallsBackToArchiveOnce() async throws {
        let http = FakeHTTP { url in
            if url.host == forecastHost { throw EnrichmentError.permanent(code: "http_4xx") }
            return body()
        }
        let out = try await enricher(http).run(fixtureInput(metadata()))
        #expect(out.status == .ok)
        #expect(http.urls.map(\.host) == [forecastHost, archiveHost])
        #expect(http.urls[1] == OpenMeteo.archiveRequest(latitude: 47.61, longitude: -122.33, capturedAt: captured))
    }

    @Test func archiveAlsoFailingIsPermanent() async {
        let http = FakeHTTP { _ in throw EnrichmentError.permanent(code: "http_4xx") }
        await #expect(throws: EnrichmentError.permanent(code: "weather_http_400")) { _ = try await enricher(http).run(fixtureInput(metadata())) }
        #expect(http.urls.map(\.host) == [forecastHost, archiveHost])
        let old = FakeHTTP { _ in throw EnrichmentError.permanent(code: "http_4xx") }
        await #expect(throws: EnrichmentError.permanent(code: "weather_http_400")) {
            _ = try await enricher(old, now: captured.addingTimeInterval(90 * 86_400)).run(fixtureInput(metadata()))
        }
        #expect(old.urls.map(\.host) == [archiveHost])   // an archive request is not retried against itself
    }

    @Test func fallbackFailingTransientlyIsTransient() async {
        let http = FakeHTTP { url in
            if url.host == forecastHost { throw EnrichmentError.permanent(code: "http_4xx") }
            throw EnrichmentError.transient(code: "http_5xx")
        }
        await #expect(throws: EnrichmentError.transient(code: "http_5xx")) { _ = try await enricher(http).run(fixtureInput(metadata())) }
    }

    @Test func cancellationIsRethrown() async {
        let http = FakeHTTP { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { _ = try await enricher(http).run(fixtureInput(metadata())) }
    }

    @Test func pacerSpacesRequests() async {
        let clock = Clock()
        let pacer = clock.pacer()
        await pacer.wait()
        #expect(clock.sleeps.isEmpty)
        clock.advance(.milliseconds(200))
        await pacer.wait()
        #expect(clock.sleeps.count == 1)
        let slept = clock.sleeps[0]
        #expect(slept > .milliseconds(790) && slept < .milliseconds(810))
        clock.advance(.seconds(2))
        await pacer.wait()
        #expect(clock.sleeps.count == 1)
    }

    @Test func enricherWaitsBeforeEachRequest() async throws {
        let clock = Clock()
        let http = FakeHTTP { _ in body() }
        let e = enricher(http, clock: clock)
        _ = try await e.run(fixtureInput(metadata()))
        #expect(clock.sleeps.isEmpty)
        _ = try await e.run(fixtureInput(metadata()))
        #expect(clock.sleeps.count == 1)   // the second request was held back by the pacer
        #expect(http.urls.count == 2)
    }

    @Test func coordinatesNeverMoreThanTwoDecimals() async throws {
        let http = FakeHTTP { url in
            if url.host == forecastHost { throw EnrichmentError.permanent(code: "http_4xx") }
            return body()
        }
        _ = try await enricher(http).run(fixtureInput(metadata()))
        #expect(http.urls.count == 2)
        for url in http.urls {
            #expect(!url.absoluteString.contains("47.612"))
            #expect(!url.absoluteString.contains("122.334"))
        }
    }
}
