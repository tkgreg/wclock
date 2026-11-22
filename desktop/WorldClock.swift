import AppKit
import Combine
import SwiftUI

enum Theme {
    static let background = Color(red: 11/255, green: 12/255, blue: 22/255)
    static let ink = Color(red: 221/255, green: 247/255, blue: 1)
    static let accent = Color(red: 130/255, green: 251/255, blue: 156/255)
    static let selection = Color(red: 31/255, green: 37/255, blue: 58/255)
    static let border = Color(red: 45/255, green: 52/255, blue: 80/255)
    static let muted = Color(red: 134/255, green: 167/255, blue: 223/255)
    static let panel = Color(red: 17/255, green: 20/255, blue: 34/255)
}

enum Dialog: Equatable {
    case add, manual, edit, meetingLocation, meetingTime, repeatedTime, delete
}

@MainActor
final class Dashboard: ObservableObject {
    @Published var preferences = Preferences()
    @Published private(set) var showSeconds = UserDefaults.standard.object(forKey: "showSeconds") as? Bool ?? true
    @Published var selected = 0
    @Published var dropTarget: Int?
    let dragSession = UUID()
    @Published var now = Date()
    @Published var solar: [City: Solar] = [:]
    @Published var weather: [String: WeatherReading] = [:]
    @Published var stale: Set<String> = []
    @Published var weatherLoaded = false
    @Published var dialog: Dialog?
    @Published var status = ""
    @Published var error = ""
    @Published var query = ""
    @Published var suggestions: [City] = []
    @Published var option = 0
    @Published var fields = ["", "", "", ""]
    @Published var meeting: (City, Date)?
    @Published var source: City?
    @Published var occurrences: [InstantChoice] = []
    @Published var meetingScroll = 0
    @Published var meetingDaylight: [City: [[TimeInterval]]] = [:]
    @Published var reorderOriginal: (Preferences, Int)?
    private var nextSolar = Date.distantPast
    private var nextWeather = Date.distantPast
    private var loadingWeather = false
    private var monitor: Any?
    private var configPath: String?
    private var configStamp: ConfigStamp?

    private struct ConfigStamp: Equatable {
        var inode: UInt64
        var modified: Date
    }

    private func currentConfigStamp() -> ConfigStamp? {
        guard let configPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: configPath),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return ConfigStamp(inode: inode.uint64Value, modified: modified)
    }

    var cities: [City] { preferences.locations }
    var selectedCity: City? { cities.indices.contains(selected) ? cities[selected] : nil }
    var meetingCities: [City] {
        guard let (city, _) = meeting else { return [] }
        return [city] + cities.filter { $0.name != city.name || $0.zone != city.zone }
    }

    func activate() {
        guard monitor == nil else { return }
        load()
        tick()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func deactivate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func load() {
        do {
            if configPath == nil { configPath = try Engine.request("config_path") }
            let stamp = currentConfigStamp()
            let previousCity = selectedCity
            let previousLocations = cities
            preferences = try Engine.request("load")
            configStamp = stamp
            selected = previousCity.flatMap { cities.firstIndex(of: $0) }
                ?? min(selected, max(0, cities.count - 1))
            if cities != previousLocations {
                nextWeather = .distantPast
                refreshSolar()
                if let (_, instant) = meeting { refreshMeetingDaylight(instant) }
            }
        } catch { status = error.localizedDescription }
    }

    func tick() {
        now = Date()
        if dialog == nil, reorderOriginal == nil, currentConfigStamp() != configStamp { load() }
        if now >= nextSolar { refreshSolar() }
        guard !cities.isEmpty, !loadingWeather, now >= nextWeather else { return }
        loadingWeather = true
        let locations = cities
        Task {
            var keys = Set<String>()
            for start in stride(from: 0, to: locations.count, by: 25) {
                let batch = Array(locations[start..<min(start + 25, locations.count)])
                if let results = try? await WeatherReading.fetch(batch) {
                    weather.merge(results) { _, fresh in fresh }
                    keys.formUnion(results.keys)
                }
            }
            let currentKeys = Set(cities.map(\.key))
            weather = weather.filter { currentKeys.contains($0.key) }
            stale = currentKeys.subtracting(keys)
            weatherLoaded = true
            loadingWeather = false
            nextWeather = Date().addingTimeInterval(cities == locations ? (stale.isEmpty ? 900 : 60) : 0)
        }
    }

    func refreshSolar() {
        nextSolar = Date().addingTimeInterval(30)
        do {
            let days: [Solar] = try Engine.request("solar", [
                "locations": Engine.object(cities), "timestamp": Int(now.timeIntervalSince1970)
            ])
            solar = Dictionary(zip(cities, days), uniquingKeysWith: { first, _ in first })
        } catch { status = error.localizedDescription }
    }

    @discardableResult
    func save(_ configuration: Preferences) -> Bool {
        do {
            guard currentConfigStamp() == configStamp else {
                throw Engine.BridgeError("Settings changed in wclock. Press Esc and try again.")
            }
            let _: [String: String] = try Engine.request("save", ["config": Engine.object(configuration)])
            configStamp = currentConfigStamp()
            let locationsChanged = configuration.locations != cities
            preferences = configuration
            if locationsChanged {
                nextWeather = .distantPast
                refreshSolar()
            }
            status = ""
            return true
        } catch {
            if dialog == nil { status = error.localizedDescription }
            else { self.error = error.localizedDescription }
            return false
        }
    }

    func open(_ dialog: Dialog) {
        error = ""
        status = ""
        self.dialog = dialog
    }

    func startPicker(_ kind: Dialog) {
        open(kind)
        query = ""
        refreshSuggestions()
        if kind == .meetingLocation { option = min(selected, max(0, suggestions.count - 1)) }
    }

    func refreshSuggestions() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = dialog == .meetingLocation
            ? cities.filter { text.isEmpty || $0.name.localizedStandardContains(text) }
            : []
        let matches: [City] = text.isEmpty ? [] : (try? Engine.request("search", ["query": text])) ?? []
        suggestions = saved + matches.filter { match in !saved.contains { $0.name == match.name && $0.zone == match.zone } }
        option = 0
    }

    func editSelected() {
        guard let city = selectedCity else { return }
        fields = [city.name, city.zone, String(city.latitude), String(city.longitude)]
        open(.edit)
    }

    func beginMeeting(_ city: City) {
        source = city
        fields = [city.formatted(meeting?.1 ?? now, "yyyy-MM-dd"),
                  meeting.map { city.formatted($0.1, preferences.timeFormat) } ?? "", "", ""]
        open(.meetingTime)
    }

    func resolveMeeting() {
        guard let source else { return }
        do {
            occurrences = try Engine.request("meeting", [
                "location": Engine.object(source), "date": fields[0], "time": fields[1]
            ])
            if occurrences.count == 1 { chooseOccurrence(0) }
            else { option = 0; open(.repeatedTime) }
        } catch { self.error = error.localizedDescription }
    }

    func chooseOccurrence(_ index: Int) {
        guard let source, occurrences.indices.contains(index) else { return }
        meeting = (source, Date(timeIntervalSince1970: occurrences[index].timestamp))
        meetingScroll = 0
        if let (_, instant) = meeting {
            refreshMeetingDaylight(instant)
        }
        dialog = nil
    }

    private func refreshMeetingDaylight(_ instant: Date) {
        let locations = meetingCities
        meetingDaylight = [:]
        guard let encoded = try? Engine.object(locations) else { return }
        for offset in [-4, 0, 4] {
            let timestamp = Int(instant.timeIntervalSince1970) + offset * 3600
            guard let days: [Solar] = try? Engine.request("solar", ["locations": encoded, "timestamp": timestamp]) else { continue }
            for (city, solar) in zip(locations, days) {
                meetingDaylight[city, default: []].append(contentsOf: solar.intervals)
            }
        }
    }

    func submit() {
        switch dialog {
        case .add:
            if suggestions.indices.contains(option) {
                var new = preferences
                new.locations.append(suggestions[option])
                if save(new) { selected = cities.count - 1; dialog = nil }
            }
        case .edit, .manual:
            guard let latitude = Double(fields[2]), let longitude = Double(fields[3]) else {
                error = "Enter latitude and longitude in decimal degrees."
                return
            }
            let city = City(name: fields[0].trimmingCharacters(in: .whitespaces),
                            zone: fields[1].trimmingCharacters(in: .whitespaces), latitude: latitude, longitude: longitude)
            var new = preferences
            let isManual = dialog == .manual
            if isManual { new.locations.append(city) }
            else if cities.indices.contains(selected) { new.locations[selected] = city }
            if save(new) {
                if isManual { selected = cities.count - 1 }
                dialog = nil
            }
        case .meetingLocation:
            if suggestions.indices.contains(option) { beginMeeting(suggestions[option]) }
        case .meetingTime: resolveMeeting()
        case .repeatedTime: chooseOccurrence(option)
        case .delete:
            var new = preferences
            guard cities.indices.contains(selected) else { return }
            new.locations.remove(at: selected)
            if save(new) { selected = min(selected, max(0, cities.count - 1)); dialog = nil }
        case nil: break
        }
    }

    func escape() {
        switch dialog {
        case .manual: startPicker(.add)
        case .meetingTime: startPicker(.meetingLocation)
        case .repeatedTime: open(.meetingTime)
        case nil: meeting = nil
        default: dialog = nil
        }
    }

    func dropCity(_ drag: CityDrag, onto destination: Int) -> Bool {
        dropTarget = nil
        guard drag.session == dragSession, dialog == nil, meeting == nil, reorderOriginal == nil,
              cities.indices.contains(drag.index), cities.indices.contains(destination),
              cities[drag.index] == drag.city, drag.index != destination else { return false }

        var new = preferences
        let city = new.locations.remove(at: drag.index)
        new.locations.insert(city, at: destination)
        guard save(new) else { return false }
        selected = destination
        return true
    }

    func move(_ amount: Int) {
        if meeting != nil {
            meetingScroll = max(0, min(meetingScroll + amount, meetingCities.count - 1))
            return
        }
        let index = max(0, min(selected + amount, cities.count - 1))
        if reorderOriginal != nil, index != selected {
            preferences.locations.swapAt(index, selected)
        }
        selected = index
    }

    func handle(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if dialog == .add, modifiers == .control, key == "n" {
            fields = [query, "", "", ""]
            open(.manual)
            return true
        }
        if !modifiers.isEmpty { return false }
        let code = event.keyCode
        if let dialog {
            if code == 53 { escape(); return true }
            if [36, 76].contains(code) { submit(); return true }
            if [126, 125].contains(code), [.add, .meetingLocation, .repeatedTime].contains(dialog) {
                let count = dialog == .repeatedTime ? occurrences.count : suggestions.count
                option = max(0, min(option + (code == 126 ? -1 : 1), count - 1))
                return true
            }
            return false
        }
        if reorderOriginal != nil {
            if code == 53, let (original, city) = reorderOriginal {
                preferences = original
                selected = city
                reorderOriginal = nil
                status = ""
            } else if [36, 76].contains(code) {
                if save(preferences) { reorderOriginal = nil }
            } else if [123, 124, 125, 126].contains(code) {
                move(code == 123 || code == 126 ? -1 : 1)
            } else { return false }
            return true
        }
        if [123, 124, 125, 126].contains(code) {
            move(code == 123 || code == 126 ? -1 : 1)
            return true
        }
        if code == 53, meeting != nil { escape(); return true }
        if key == "m" { startPicker(.meetingLocation); return true }
        if key == "q" { NSApp.terminate(nil); return true }
        if key == "s" {
            showSeconds.toggle()
            UserDefaults.standard.set(showSeconds, forKey: "showSeconds")
            return true
        }
        var new = preferences
        if key == "t" {
            new.clock_format = new.clock_format == "am_pm" ? "twenty_four_hour" : "am_pm"
            save(new)
            return true
        }
        guard meeting == nil else { return false }
        switch key {
        case "a": startPicker(.add)
        case "e": editSelected()
        case "d": if selectedCity != nil { open(.delete) }
        case "r": if cities.count > 1 { reorderOriginal = (preferences, selected) }
        case "g":
            new.layout = new.layout == "grid" ? "list" : "grid"
            save(new)
        default: return false
        }
        return true
    }
}

@main
struct WorldClockApp: App {
    @StateObject private var dashboard = Dashboard()

    var body: some Scene {
        Window("WorldClock", id: "dashboard") {
            DashboardView(model: dashboard)
                .frame(minWidth: 660, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1020, height: 790)
        .windowResizability(.contentMinSize)
    }
}
