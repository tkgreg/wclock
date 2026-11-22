import OSLog
import SwiftUI
import WidgetKit

private struct ClockEntry: TimelineEntry {
    let date: Date
    let cities: [City]
    let format: String
    let weather: [String: WeatherReading]

    private static let sample = Self(
        date: Date(timeIntervalSince1970: 1_795_333_320),
        cities: [
            City(name: "Phnom Penh", zone: "Asia/Phnom_Penh", latitude: 11.5564, longitude: 104.9282),
            City(name: "London", zone: "Europe/London", latitude: 51.5072, longitude: -0.1276),
            City(name: "Los Angeles", zone: "America/Los_Angeles", latitude: 34.0522, longitude: -118.2437),
            City(name: "Tokyo", zone: "Asia/Tokyo", latitude: 35.6762, longitude: 139.6503),
            City(name: "New York", zone: "America/New_York", latitude: 40.7128, longitude: -74.006),
            City(name: "Sydney", zone: "Australia/Sydney", latitude: -33.8688, longitude: 151.2093)
        ],
        format: "HH:mm",
        weather: [
            "11.5564,104.9282": WeatherReading(temperature_2m: 29, weather_code: 0, is_day: 1),
            "51.5072,-0.1276": WeatherReading(temperature_2m: 8, weather_code: 3, is_day: 1),
            "34.0522,-118.2437": WeatherReading(temperature_2m: 16, weather_code: 0, is_day: 0),
            "35.6762,139.6503": WeatherReading(temperature_2m: 13, weather_code: 2, is_day: 1),
            "40.7128,-74.006": WeatherReading(temperature_2m: 6, weather_code: 3, is_day: 0),
            "-33.8688,151.2093": WeatherReading(temperature_2m: 22, weather_code: 0, is_day: 1)
        ]
    )

    static func sample(for family: WidgetFamily) -> Self {
        Self(date: sample.date, cities: Array(sample.cities.prefix(family.cityLimit)),
             format: sample.format, weather: sample.weather)
    }
}

private extension WidgetFamily {
    var cityLimit: Int {
        switch self {
        case .systemSmall: 1
        case .systemLarge: 6
        default: 3
        }
    }
}

private struct ClockProvider: TimelineProvider {
    private let logger = Logger(subsystem: "org.worldclock.desktop.widget", category: "Timeline")

    func placeholder(in context: Context) -> ClockEntry { .sample(for: context.family) }

    func getSnapshot(in context: Context, completion: @escaping (ClockEntry) -> Void) {
        if context.isPreview {
            completion(.sample(for: context.family))
        } else {
            let settings = WidgetSettings.read() ?? Preferences()
            completion(ClockEntry(date: .now, cities: locations(settings, context),
                                  format: settings.minuteFormat, weather: [:]))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClockEntry>) -> Void) {
        let settings = WidgetSettings.read() ?? Preferences()
        let cities = locations(settings, context)
        Task {
            let weather = cities.isEmpty ? [:] : (try? await WeatherReading.fetch(cities)) ?? [:]
            logger.notice("Loaded \(cities.count, privacy: .public) cities and \(weather.count, privacy: .public) weather readings for the widget")
            let now = Date()
            let minute = floor(now.timeIntervalSince1970 / 60) * 60
            // Keep an extra hour of clock entries available if WidgetKit delays the reload.
            let entries = (0..<120).map { offset in
                let date = offset == 0 ? now : Date(timeIntervalSince1970: minute + Double(offset * 60))
                return ClockEntry(date: date, cities: cities, format: settings.minuteFormat, weather: weather)
            }
            completion(Timeline(entries: entries, policy: .after(Date(timeIntervalSince1970: minute + 3600))))
        }
    }

    private func locations(_ settings: Preferences, _ context: Context) -> [City] {
        Array(settings.locations.prefix(context.family.cityLimit))
    }
}

private struct ClockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClockEntry

    var body: some View {
        Group {
            if let city = entry.cities.first {
                if family == .systemSmall {
                    small(city).padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(entry.cities.indices, id: \.self) { index in
                            if index > 0 {
                                Rectangle().fill(Theme.border).frame(height: 1)
                            }
                            row(entry.cities[index])
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WorldClock").font(.headline)
                    Text("Open WorldClock to set up your cities.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(Theme.ink)
        .containerBackground(for: .widget) { Theme.panel }
    }

    private func small(_ city: City) -> some View {
        VStack(alignment: .leading) {
            Text(city.name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            DotClock(time: time(city), maxPitch: 4.5, color: Theme.accent)
            Spacer(minLength: 4)
            HStack {
                Text(city.formatted(entry.date, "EEE, MMM d"))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                weather(city)
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)
        }
    }

    private func row(_ city: City) -> some View {
        let reading = entry.weather[city.key]
        return HStack(spacing: 8) {
            weatherIcon(reading)
                .frame(width: 18)
            HStack(spacing: 6) {
                Text(city.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
                if let offset = dayOffset(city), offset != 0 {
                    let sign = offset < 0 ? "−" : "+"
                    let unit = abs(offset) == 1 ? "day" : "days"
                    Text("\(sign)\(abs(offset)) \(unit)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                        .accessibilityLabel(offset < 0 ? "\(abs(offset)) \(unit) earlier" : "\(offset) \(unit) later")
                }
            }
            Spacer(minLength: 0)
            DotClock(time: time(city), maxPitch: 2.65, alignRight: true)
                .frame(width: entry.format == "HH:mm" ? 77 : 104)
            temperature(reading)
                .frame(width: 31, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    private func time(_ city: City) -> String {
        city.formatted(entry.date, entry.format)
    }

    private func dayOffset(_ city: City) -> Int? {
        guard let reference = entry.cities.first else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        func localDay(in zone: TimeZone) -> Date? {
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.year, .month, .day], from: entry.date)
            calendar.timeZone = .gmt
            return calendar.date(from: parts)
        }
        guard let first = localDay(in: reference.timeZone), let day = localDay(in: city.timeZone) else { return nil }
        return calendar.dateComponents([.day], from: first, to: day).day
    }

    private func weather(_ city: City) -> some View {
        let reading = entry.weather[city.key]
        return HStack(spacing: 4) {
            weatherIcon(reading)
            temperature(reading)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func weatherIcon(_ reading: WeatherReading?) -> some View {
        if let reading {
            Image(systemName: reading.symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 16).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func temperature(_ reading: WeatherReading?) -> some View {
        if let reading {
            Text("\(reading.temperature_2m, format: .number.precision(.fractionLength(0)))°")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel("\(reading.condition), \(reading.temperature_2m, format: .number.precision(.fractionLength(0))) degrees Celsius")
        } else {
            Text("—")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .accessibilityLabel("Weather unavailable")
        }
    }
}

@main
struct WorldClockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSettings.kind, provider: ClockProvider()) { entry in
            ClockWidgetView(entry: entry)
        }
        .configurationDisplayName("WorldClock")
        .description("Local time and weather for your saved cities.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
