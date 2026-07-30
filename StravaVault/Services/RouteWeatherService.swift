import CoreLocation
import Foundation

struct RouteWeatherSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var timeZoneIdentifier: String
    var isStale: Bool
    var current: RouteCurrentWeather
    var dailyForecasts: [RouteDailyWeatherForecast]

    var providerName: String {
        "Open-Meteo"
    }
}

struct RouteCurrentWeather: Codable, Sendable {
    var observedAt: Date
    var temperature: Double
    var apparentTemperature: Double
    var humidityPercent: Double?
    var windSpeed: Double
    var weatherCode: Int
    var isDaylight: Bool
}

struct RouteDailyWeatherForecast: Codable, Sendable, Identifiable {
    var date: Date
    var highTemperature: Double
    var lowTemperature: Double
    var weatherCode: Int

    var id: Date { date }
}

struct RouteHistoricalWeatherSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var timeZoneIdentifier: String
    var isStale: Bool
    var observations: [RouteHistoricalWeatherObservation]

    var providerName: String {
        "Open-Meteo Historical Weather"
    }

    func observation(closestTo date: Date) -> RouteHistoricalWeatherObservation? {
        observations.min { lhs, rhs in
            abs(lhs.observedAt.timeIntervalSince(date)) < abs(rhs.observedAt.timeIntervalSince(date))
        }
    }
}

struct RouteHistoricalWeatherObservation: Codable, Sendable, Identifiable {
    var observedAt: Date
    var temperatureCelsius: Double
    var apparentTemperatureCelsius: Double?
    var humidityPercent: Double?
    var weatherCode: Int
    var isDaylight: Bool

    var id: Date { observedAt }
}

enum RouteWeatherCondition: Sendable {
    case clear
    case mostlyClear
    case partlyCloudy
    case overcast
    case fog
    case drizzle
    case rain
    case snow
    case thunderstorm
    case unknown

    init(weatherCode: Int) {
        switch weatherCode {
        case 0:
            self = .clear
        case 1:
            self = .mostlyClear
        case 2:
            self = .partlyCloudy
        case 3:
            self = .overcast
        case 45, 48:
            self = .fog
        case 51, 53, 55, 56, 57:
            self = .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82:
            self = .rain
        case 71, 73, 75, 77, 85, 86:
            self = .snow
        case 95, 96, 99:
            self = .thunderstorm
        default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .clear:
            return "Clear"
        case .mostlyClear:
            return "Mostly Clear"
        case .partlyCloudy:
            return "Partly Cloudy"
        case .overcast:
            return "Overcast"
        case .fog:
            return "Fog"
        case .drizzle:
            return "Drizzle"
        case .rain:
            return "Rain"
        case .snow:
            return "Snow"
        case .thunderstorm:
            return "Thunderstorm"
        case .unknown:
            return "Conditions Unavailable"
        }
    }

    func symbolName(isDaylight: Bool) -> String {
        switch self {
        case .clear:
            return isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .mostlyClear:
            return isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy:
            return isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast:
            return "cloud.fill"
        case .fog:
            return "cloud.fog.fill"
        case .drizzle:
            return "cloud.drizzle.fill"
        case .rain:
            return "cloud.rain.fill"
        case .snow:
            return "cloud.snow.fill"
        case .thunderstorm:
            return "cloud.bolt.rain.fill"
        case .unknown:
            return "cloud.fill"
        }
    }
}

actor RouteWeatherService {
    static let shared = RouteWeatherService()

    private enum Defaults {
        static let cacheStoreKey = "routeWeatherSnapshotCache"
        static let historicalCacheStoreKey = "routeHistoricalWeatherSnapshotCache"
        static let freshnessInterval: TimeInterval = 20 * 60
        static let staleFallbackInterval: TimeInterval = 12 * 60 * 60
        static let maximumCachedEntries = 48
        static let baseURLString = "https://api.open-meteo.com/v1/forecast"
        static let historicalBaseURLString = "https://archive-api.open-meteo.com/v1/archive"
    }

    private enum AppConfiguration {
        static func value(for key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmed ?? ""
        }

        static var apiBaseURLString: String {
            value(for: "RouteVaultWeatherAPIBaseURL").nilIfEmpty ?? Defaults.baseURLString
        }

        static var apiKey: String? {
            value(for: "RouteVaultWeatherAPIKey").nilIfEmpty
        }
    }

    private enum WeatherError: LocalizedError {
        case invalidBaseURL
        case requestFailed(statusCode: Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Weather service configuration is invalid."
            case .requestFailed(let statusCode):
                return "Weather data is currently unavailable (\(statusCode))."
            case .invalidResponse:
                return "The weather service returned an unreadable forecast."
            }
        }
    }

    private struct ForecastResponse: Decodable {
        let timezone: String
        let current: CurrentPayload
        let daily: DailyPayload
    }

    private struct HistoricalWeatherResponse: Decodable {
        let timezone: String
        let hourly: HistoricalHourlyPayload
    }

    private struct CurrentPayload: Decodable {
        let time: String
        let temperature2M: Double
        let apparentTemperature: Double
        let relativeHumidity2M: Double?
        let weatherCode: Int
        let windSpeed10M: Double
        let isDay: Int?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2M = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity2M = "relative_humidity_2m"
            case weatherCode = "weather_code"
            case windSpeed10M = "wind_speed_10m"
            case isDay = "is_day"
        }
    }

    private struct DailyPayload: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperatureMax: [Double]
        let temperatureMin: [Double]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
        }
    }

    private struct HistoricalHourlyPayload: Decodable {
        let time: [String]
        let temperature2M: [Double]
        let apparentTemperature: [Double]?
        let relativeHumidity2M: [Double]?
        let weatherCode: [Int]?
        let isDay: [Int]?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2M = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity2M = "relative_humidity_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    private enum CacheStore {
        static func load() -> [String: RouteWeatherSnapshot] {
            guard let data = UserDefaults.standard.data(forKey: Defaults.cacheStoreKey),
                  let decoded = try? JSONDecoder().decode([String: RouteWeatherSnapshot].self, from: data) else {
                return [:]
            }

            return decoded
        }

        static func save(_ cache: [String: RouteWeatherSnapshot]) {
            guard let encoded = try? JSONEncoder().encode(cache) else {
                return
            }

            UserDefaults.standard.set(encoded, forKey: Defaults.cacheStoreKey)
        }
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    private var cache = CacheStore.load()
    private var historicalCache: [String: RouteHistoricalWeatherSnapshot] = [:]

    func weather(
        at coordinate: CLLocationCoordinate2D,
        measurementSystem: AppMeasurementSystem,
        forceRefresh: Bool = false
    ) async throws -> RouteWeatherSnapshot {
        let cacheKey = cacheKey(for: coordinate, measurementSystem: measurementSystem)

        if !forceRefresh,
           let cachedSnapshot = cache[cacheKey],
           !isExpired(cachedSnapshot) {
            var snapshot = cachedSnapshot
            snapshot.isStale = false
            return snapshot
        }

        do {
            let snapshot = try await requestWeather(
                at: coordinate,
                measurementSystem: measurementSystem
            )
            store(snapshot, for: cacheKey)
            return snapshot
        } catch {
            if let cachedSnapshot = cache[cacheKey],
               canUseAsStaleFallback(cachedSnapshot) {
                var snapshot = cachedSnapshot
                snapshot.isStale = true
                return snapshot
            }

            throw error
        }
    }

    func historicalWeather(
        at coordinate: CLLocationCoordinate2D,
        on date: Date,
        forceRefresh: Bool = false
    ) async throws -> RouteHistoricalWeatherSnapshot {
        let cacheKey = historicalCacheKey(for: coordinate, date: date)

        if !forceRefresh, let cachedSnapshot = historicalCache[cacheKey] {
            return cachedSnapshot
        }

        let snapshot = try await requestHistoricalWeather(at: coordinate, on: date)
        historicalCache[cacheKey] = snapshot
        return snapshot
    }

    private func requestWeather(
        at coordinate: CLLocationCoordinate2D,
        measurementSystem: AppMeasurementSystem
    ) async throws -> RouteWeatherSnapshot {
        guard var components = URLComponents(string: AppConfiguration.apiBaseURLString) else {
            throw WeatherError.invalidBaseURL
        }

        components.queryItems = [
            URLQueryItem(name: "latitude", value: formattedCoordinateValue(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: formattedCoordinateValue(coordinate.longitude)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "5"),
            URLQueryItem(
                name: "current",
                value: [
                    "temperature_2m",
                    "apparent_temperature",
                    "relative_humidity_2m",
                    "weather_code",
                    "wind_speed_10m",
                    "is_day"
                ].joined(separator: ",")
            ),
            URLQueryItem(
                name: "daily",
                value: [
                    "weather_code",
                    "temperature_2m_max",
                    "temperature_2m_min"
                ].joined(separator: ",")
            ),
            URLQueryItem(name: "temperature_unit", value: measurementSystem == .metric ? "celsius" : "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: measurementSystem == .metric ? "kmh" : "mph")
        ]

        if let apiKey = AppConfiguration.apiKey {
            components.queryItems?.append(URLQueryItem(name: "apikey", value: apiKey))
        }

        guard let url = components.url else {
            throw WeatherError.invalidBaseURL
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw WeatherError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let decodedResponse = try JSONDecoder().decode(ForecastResponse.self, from: data)
        return try snapshot(from: decodedResponse)
    }

    private func requestHistoricalWeather(
        at coordinate: CLLocationCoordinate2D,
        on date: Date
    ) async throws -> RouteHistoricalWeatherSnapshot {
        guard var components = URLComponents(string: Defaults.historicalBaseURLString) else {
            throw WeatherError.invalidBaseURL
        }

        let startOfDay = Calendar.autoupdatingCurrent.startOfDay(for: date)
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .autoupdatingCurrent
        dateFormatter.dateFormat = "yyyy-MM-dd"

        components.queryItems = [
            URLQueryItem(name: "latitude", value: formattedCoordinateValue(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: formattedCoordinateValue(coordinate.longitude)),
            URLQueryItem(name: "start_date", value: dateFormatter.string(from: startOfDay)),
            URLQueryItem(name: "end_date", value: dateFormatter.string(from: startOfDay)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(
                name: "hourly",
                value: [
                    "temperature_2m",
                    "apparent_temperature",
                    "relative_humidity_2m",
                    "weather_code",
                    "is_day"
                ].joined(separator: ",")
            ),
            URLQueryItem(name: "temperature_unit", value: "celsius")
        ]

        guard let url = components.url else {
            throw WeatherError.invalidBaseURL
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw WeatherError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let decodedResponse = try JSONDecoder().decode(HistoricalWeatherResponse.self, from: data)
        return try historicalSnapshot(from: decodedResponse)
    }

    private func snapshot(from response: ForecastResponse) throws -> RouteWeatherSnapshot {
        let observedAt = try parseCurrentDate(
            response.current.time,
            timezoneIdentifier: response.timezone
        )

        let current = RouteCurrentWeather(
            observedAt: observedAt,
            temperature: response.current.temperature2M,
            apparentTemperature: response.current.apparentTemperature,
            humidityPercent: response.current.relativeHumidity2M,
            windSpeed: response.current.windSpeed10M,
            weatherCode: response.current.weatherCode,
            isDaylight: (response.current.isDay ?? 1) == 1
        )

        let itemCount = min(
            response.daily.time.count,
            response.daily.weatherCode.count,
            response.daily.temperatureMax.count,
            response.daily.temperatureMin.count
        )

        guard itemCount > 0 else {
            throw WeatherError.invalidResponse
        }

        let dailyForecasts = try (0 ..< itemCount).map { index in
            RouteDailyWeatherForecast(
                date: try parseDayDate(
                    response.daily.time[index],
                    timezoneIdentifier: response.timezone
                ),
                highTemperature: response.daily.temperatureMax[index],
                lowTemperature: response.daily.temperatureMin[index],
                weatherCode: response.daily.weatherCode[index]
            )
        }

        return RouteWeatherSnapshot(
            fetchedAt: .now,
            timeZoneIdentifier: response.timezone,
            isStale: false,
            current: current,
            dailyForecasts: dailyForecasts
        )
    }

    private func historicalSnapshot(from response: HistoricalWeatherResponse) throws -> RouteHistoricalWeatherSnapshot {
        let itemCount = min(
            response.hourly.time.count,
            response.hourly.temperature2M.count,
            response.hourly.apparentTemperature?.count ?? response.hourly.temperature2M.count,
            response.hourly.relativeHumidity2M?.count ?? response.hourly.temperature2M.count,
            response.hourly.weatherCode?.count ?? response.hourly.temperature2M.count,
            response.hourly.isDay?.count ?? response.hourly.temperature2M.count
        )

        guard itemCount > 0 else {
            throw WeatherError.invalidResponse
        }

        let observations = try (0 ..< itemCount).map { index in
            RouteHistoricalWeatherObservation(
                observedAt: try parseCurrentDate(
                    response.hourly.time[index],
                    timezoneIdentifier: response.timezone
                ),
                temperatureCelsius: response.hourly.temperature2M[index],
                apparentTemperatureCelsius: response.hourly.apparentTemperature?[index],
                humidityPercent: response.hourly.relativeHumidity2M?[index],
                weatherCode: response.hourly.weatherCode?[index] ?? 0,
                isDaylight: (response.hourly.isDay?[index] ?? 1) == 1
            )
        }

        return RouteHistoricalWeatherSnapshot(
            fetchedAt: .now,
            timeZoneIdentifier: response.timezone,
            isStale: false,
            observations: observations
        )
    }

    private func cacheKey(
        for coordinate: CLLocationCoordinate2D,
        measurementSystem: AppMeasurementSystem
    ) -> String {
        let latitude = (coordinate.latitude * 1_000).rounded() / 1_000
        let longitude = (coordinate.longitude * 1_000).rounded() / 1_000
        return "\(latitude),\(longitude)|\(measurementSystem.rawValue)"
    }

    private func store(_ snapshot: RouteWeatherSnapshot, for cacheKey: String) {
        cache[cacheKey] = snapshot

        if cache.count > Defaults.maximumCachedEntries {
            let keysToRemove = cache
                .sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .dropFirst(Defaults.maximumCachedEntries)
                .map(\.key)

            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
        }

        CacheStore.save(cache)
    }

    private func historicalCacheKey(for coordinate: CLLocationCoordinate2D, date: Date) -> String {
        let latitude = (coordinate.latitude * 1_000).rounded() / 1_000
        let longitude = (coordinate.longitude * 1_000).rounded() / 1_000
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date).timeIntervalSince1970
        return "\(latitude),\(longitude)|\(day)"
    }

    private func isExpired(_ snapshot: RouteWeatherSnapshot) -> Bool {
        Date().timeIntervalSince(snapshot.fetchedAt) > Defaults.freshnessInterval
    }

    private func canUseAsStaleFallback(_ snapshot: RouteWeatherSnapshot) -> Bool {
        Date().timeIntervalSince(snapshot.fetchedAt) <= Defaults.staleFallbackInterval
    }

    private func formattedCoordinateValue(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func parseCurrentDate(
        _ string: String,
        timezoneIdentifier: String
    ) throws -> Date {
        try parseDate(
            string,
            format: "yyyy-MM-dd'T'HH:mm",
            timezoneIdentifier: timezoneIdentifier
        )
    }

    private func parseDayDate(
        _ string: String,
        timezoneIdentifier: String
    ) throws -> Date {
        try parseDate(
            string,
            format: "yyyy-MM-dd",
            timezoneIdentifier: timezoneIdentifier
        )
    }

    private func parseDate(
        _ string: String,
        format: String,
        timezoneIdentifier: String
    ) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .autoupdatingCurrent
        formatter.dateFormat = format

        guard let date = formatter.date(from: string) else {
            throw WeatherError.invalidResponse
        }

        return date
    }
}
