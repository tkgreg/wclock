import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct City: Codable, Hashable {
    var name: String
    var zone: String
    var latitude: Double
    var longitude: Double
    var region: String? = nil

    var timeZone: TimeZone { TimeZone(identifier: zone) ?? .gmt }
    var key: String { "\(latitude),\(longitude)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.zone == rhs.zone && lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(zone)
        hasher.combine(key)
    }

    func formatted(_ date: Date, _ format: String) -> String {
        formatDate(date, as: format, in: timeZone)
    }
}

func formatDate(_ date: Date, as format: String, in timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
}

struct CityDrag: Codable, Transferable {
    let session: UUID
    let index: Int
    let city: City

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "org.worldclock.desktop.city-order"))
    }
}

struct Preferences: Codable {
    var layout = "grid"
    var clock_format = "twenty_four_hour"
    var weather_icons = "pixel"
    var locations: [City] = []

    var timeFormat: String { clock_format == "am_pm" ? "h:mm:ss a" : "HH:mm:ss" }
    var minuteFormat: String { clock_format == "am_pm" ? "h:mm a" : "HH:mm" }
}

struct Solar: Decodable {
    var start: TimeInterval
    var end: TimeInterval
    var intervals: [[TimeInterval]]
    var phase: String

    var daylightMinutes: Int { Int(intervals.reduce(0) { $0 + $1[1] - $1[0] } / 60) }
    var sunrise: Date? {
        intervals.first { $0[0] > start }.map { Date(timeIntervalSince1970: $0[0]) }
    }
    var sunset: Date? {
        intervals.first { $0[1] < end }.map { Date(timeIntervalSince1970: $0[1]) }
    }
}

struct InstantChoice: Decodable {
    var timestamp: TimeInterval
    var offset: String
}

enum Engine {
    private struct Failure: Decodable { var error: String }
    struct BridgeError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func request<T: Decodable>(_ action: String, _ body: [String: Any] = [:]) throws -> T {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "worldclock-engine") else {
            throw BridgeError("The WorldClock engine is missing.")
        }
        var request = body
        request["action"] = action
        let data = try JSONSerialization.data(withJSONObject: request)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--desktop-bridge"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let error = try? JSONDecoder().decode(Failure.self, from: result) {
            throw BridgeError(error.error)
        }
        guard process.terminationStatus == 0 else { throw BridgeError("The WorldClock engine stopped.") }
        return try JSONDecoder().decode(T.self, from: result)
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

struct WeatherReading: Decodable {
    let temperature_2m: Double
    let weather_code: Int
    let is_day: Int

    var condition: String {
        switch weather_code {
        case 0: is_day == 0 ? "Clear" : "Sunny"
        case 1: is_day == 0 ? "Mostly clear" : "Mostly sunny"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...67, 80...82: "Rain"
        case 71...77, 85...86: "Snow"
        case 95...99: "Storm"
        default: "Unknown"
        }
    }

    var symbol: String {
        switch weather_code {
        case 0: is_day == 0 ? "moon.stars" : "sun.max"
        case 1, 2: is_day == 0 ? "cloud.moon" : "cloud.sun"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51...67, 80...82: "cloud.rain"
        case 71...77, 85...86: "cloud.snow"
        case 95...99: "cloud.bolt"
        default: "questionmark.circle"
        }
    }

    private struct Result: Decodable { var current: WeatherReading? }

    static func fetch(_ cities: [City]) async throws -> [String: WeatherReading] {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: cities.map { String($0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: cities.map { String($0.longitude) }.joined(separator: ",")),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day")
        ]
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url.url!, timeoutInterval: 8))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        let results = cities.count == 1 ? [try decoder.decode(Result.self, from: data)] : try decoder.decode([Result].self, from: data)
        guard results.count == cities.count else { throw URLError(.cannotParseResponse) }
        var readings: [String: WeatherReading] = [:]
        for (city, result) in zip(cities, results) {
            readings[city.key] = result.current
        }
        return readings
    }
}
