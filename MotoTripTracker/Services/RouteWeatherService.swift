import CoreLocation
import Foundation
import os

/// Weather sample at a point along a planned route.
struct RouteWeatherSegment: Identifiable, Sendable {
    let id: UUID
    let label: String
    let coordinateLatitude: Double
    let coordinateLongitude: Double
    let eta: Date
    let temperatureC: Double?
    let precipitationProbability: Int?
    let conditionSymbol: String
    let conditionLabel: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinateLatitude, longitude: coordinateLongitude)
    }
}

/// Fetches time-aligned weather along a driving route (Open-Meteo — no API key).
@Observable
@MainActor
final class RouteWeatherService {
    private(set) var segments: [RouteWeatherSegment] = []
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    private(set) var hasRainAlongRoute = false
    private(set) var lastError: String?

    private var lastFetchKey: String?
    private var lastProgressRefresh: Date = .distantPast
    private var cachedCoordinates: [CLLocationCoordinate2D] = []
    private var cachedTravelTime: TimeInterval = 0

    var hasData: Bool { !segments.isEmpty }

    var summaryText: String {
        if isLoading, segments.isEmpty {
            return "Checking weather…"
        }
        if let lastError, segments.isEmpty {
            return lastError
        }
        guard !segments.isEmpty else { return "Weather unavailable" }
        if hasRainAlongRoute, let rain = segments.first(where: { ($0.precipitationProbability ?? 0) >= 40 }) {
            return "Rain likely near \(rain.label) · \(Int(rain.temperatureC ?? 0))°C at destination"
        }
        if let dest = segments.last, let temp = dest.temperatureC {
            return "\(dest.conditionLabel) · \(Int(temp))°C at destination"
        }
        return segments.last?.conditionLabel ?? "Weather loaded"
    }

    func clear() {
        segments = []
        isLoading = false
        hasRainAlongRoute = false
        lastUpdated = nil
        lastError = nil
        lastFetchKey = nil
        cachedCoordinates = []
        cachedTravelTime = 0
    }

    /// Load weather for sampled points along the route at estimated arrival times.
    func refreshForRoute(coordinates: [CLLocationCoordinate2D], travelTime: TimeInterval) {
        guard coordinates.count >= 2 else {
            clear()
            return
        }

        let key = routeKey(coordinates: coordinates, travelTime: travelTime)
        if key == lastFetchKey, !segments.isEmpty { return }

        cachedCoordinates = coordinates
        cachedTravelTime = max(travelTime, 60)
        lastFetchKey = key
        isLoading = true
        lastError = nil

        let samples = Self.samplePoints(along: coordinates, count: 5)
        let departure = Date()

        Task {
            var built: [RouteWeatherSegment] = []
            for (index, sample) in samples.enumerated() {
                let fraction = samples.count > 1 ? Double(index) / Double(samples.count - 1) : 0
                let eta = departure.addingTimeInterval(self.cachedTravelTime * fraction)
                let label = Self.label(for: index, total: samples.count)
                if let segment = await Self.fetchSegment(
                    label: label,
                    coordinate: sample,
                    eta: eta
                ) {
                    built.append(segment)
                }
            }

            segments = built
            hasRainAlongRoute = built.contains { ($0.precipitationProbability ?? 0) >= 40 }
            isLoading = false
            lastUpdated = Date()
            if built.isEmpty {
                lastError = "Could not load weather — check connection"
                AppLogger.navigation.warning("Route weather returned no segments")
            } else {
                lastError = nil
                AppLogger.navigation.notice("Route weather loaded \(built.count) segments")
            }
        }
    }

    /// Throttled refresh of "weather ahead" while riding (reuses cached route geometry).
    func refreshAhead(progressFraction: Double) {
        guard !cachedCoordinates.isEmpty, cachedTravelTime > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressRefresh) >= 90 else { return }
        lastProgressRefresh = now

        let clamped = min(max(progressFraction, 0), 1)
        let remainingTime = cachedTravelTime * (1 - clamped)
        refreshForRoute(coordinates: cachedCoordinates, travelTime: remainingTime)
    }

    // MARK: - Sampling

    private static func samplePoints(
        along coordinates: [CLLocationCoordinate2D],
        count: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        let target = max(2, min(count, coordinates.count))

        var cumulative: [CLLocationDistance] = [0]
        for index in 0..<(coordinates.count - 1) {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let step = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            cumulative.append(cumulative[index] + step)
        }
        guard let total = cumulative.last, total > 0 else { return [coordinates[0]] }

        var result: [CLLocationCoordinate2D] = []
        for i in 0..<target {
            let goal = total * Double(i) / Double(max(target - 1, 1))
            var segmentIndex = 0
            while segmentIndex < cumulative.count - 1, cumulative[segmentIndex + 1] < goal {
                segmentIndex += 1
            }
            let segStart = cumulative[segmentIndex]
            let segEnd = cumulative[segmentIndex + 1]
            let t = segEnd > segStart ? (goal - segStart) / (segEnd - segStart) : 0
            let a = coordinates[segmentIndex]
            let b = coordinates[min(segmentIndex + 1, coordinates.count - 1)]
            result.append(
                CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            )
        }
        return result
    }

    private static func label(for index: Int, total: Int) -> String {
        switch index {
        case 0: "Start"
        case total - 1: "Destination"
        default: "En route"
        }
    }

    private func routeKey(coordinates: [CLLocationCoordinate2D], travelTime: TimeInterval) -> String {
        let rounded = coordinates.prefix(8).map {
            "\(String(format: "%.3f", $0.latitude)),\(String(format: "%.3f", $0.longitude))"
        }
        return "\(rounded.joined(separator: "|"))-\(Int(travelTime))"
    }

    // MARK: - Open-Meteo

    private struct OpenMeteoResponse: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]?
            let precipitation_probability: [Int]?
            let weather_code: [Int]?
        }
        let timezone: String?
        let hourly: Hourly?
    }

    private static func parseHourlyTime(_ string: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = timeZone
        return formatter.date(from: string)
    }

    private static func fetchSegment(
        label: String,
        coordinate: CLLocationCoordinate2D,
        eta: Date
    ) async -> RouteWeatherSegment? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLogger.navigation.warning("Route weather HTTP \(http.statusCode)")
                return nil
            }
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            guard let hourly = decoded.hourly, !hourly.time.isEmpty else { return nil }

            let timeZone = TimeZone(identifier: decoded.timezone ?? "") ?? .current

            var bestIndex: Int?
            var bestDelta = TimeInterval.greatestFiniteMagnitude
            for (index, timeString) in hourly.time.enumerated() {
                guard let date = parseHourlyTime(timeString, timeZone: timeZone) else { continue }
                let delta = abs(date.timeIntervalSince(eta))
                if delta < bestDelta {
                    bestDelta = delta
                    bestIndex = index
                }
            }
            guard let idx = bestIndex else {
                AppLogger.navigation.warning("Route weather could not match hourly time for eta")
                return nil
            }

            let code = hourly.weather_code?[idx] ?? 0
            let mapped = mapWeatherCode(code)
            return RouteWeatherSegment(
                id: UUID(),
                label: label,
                coordinateLatitude: coordinate.latitude,
                coordinateLongitude: coordinate.longitude,
                eta: eta,
                temperatureC: hourly.temperature_2m?[idx],
                precipitationProbability: hourly.precipitation_probability?[idx],
                conditionSymbol: mapped.symbol,
                conditionLabel: mapped.label
            )
        } catch {
            AppLogger.navigation.warning("Route weather fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func mapWeatherCode(_ code: Int) -> (symbol: String, label: String) {
        switch code {
        case 0: ("sun.max.fill", "Clear")
        case 1, 2, 3: ("cloud.sun.fill", "Partly cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51, 53, 55, 56, 57: ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 65, 66, 67: ("cloud.rain.fill", "Rain")
        case 71, 73, 75, 77: ("cloud.snow.fill", "Snow")
        case 80, 81, 82: ("cloud.heavyrain.fill", "Showers")
        case 95, 96, 99: ("cloud.bolt.rain.fill", "Thunderstorm")
        default: ("cloud.fill", "Cloudy")
        }
    }
}
