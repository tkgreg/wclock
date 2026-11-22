import AppKit
import Combine
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: Dashboard
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            header
            if model.meeting == nil { live }
            else { meeting }
            footer
        }
        .padding(28)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .overlay {
            if let dialog = model.dialog {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    DialogView(model: model, dialog: dialog).id(dialog)
                }
            }
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .onReceive(ticker) { _ in model.tick() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            Pixels(rows: ["0011100", "0101010", "1010101", "1111111", "1010101", "0101010", "0011100"], size: 4)
                .frame(width: 42, height: 42)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.meeting == nil
                     ? formatDate(model.now, as: model.showSeconds ? model.preferences.timeFormat : model.preferences.minuteFormat, in: .gmt)
                     : "Meeting")
                    .font(.system(size: 40, weight: .heavy, design: .monospaced))
                    .tracking(-3)
                    .accessibilityAddTraits(.isHeader)
                if let (city, _) = model.meeting {
                    Text(city.name.uppercased() + "  /  " + city.zone)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("UTC")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let (_, date) = model.meeting {
                Text(countdown(date))
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(12)
                    .background(Theme.selection, in: Capsule())
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    Label("LIVE", systemImage: "circle.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(model.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(minHeight: 56)
    }

    private var live: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if model.cities.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No saved cities").font(.title2.bold())
                        Text("Press A to add a location.").foregroundStyle(Theme.muted)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15),
                                         count: model.preferences.layout == "grid" ? 2 : 1), spacing: 15) {
                    ForEach(Array(model.cities.enumerated()), id: \.offset) { index, city in
                        reorderableCard(city, at: index).id(index)
                    }
                }
                .padding(1)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selected) { _, index in scroll.scrollTo(index) }
        }
    }

    @ViewBuilder
    private func reorderableCard(_ city: City, at index: Int) -> some View {
        let card = CityCard(city: city, selected: index == model.selected, model: model)
        if model.cities.count > 1, model.dialog == nil, model.reorderOriginal == nil {
            card
                .contentShape(RoundedRectangle(cornerRadius: 19))
                .overlay {
                    if model.dropTarget == index {
                        RoundedRectangle(cornerRadius: 19)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .draggable(CityDrag(session: model.dragSession, index: index, city: city))
                .dropDestination(for: CityDrag.self) { items, _ in
                    guard let item = items.first else { return false }
                    return model.dropCity(item, onto: index)
                } isTargeted: { targeted in
                    if targeted { model.dropTarget = index }
                    else if model.dropTarget == index { model.dropTarget = nil }
                }
        } else {
            card
        }
    }

    private var meeting: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if let (_, instant) = model.meeting {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(model.meetingCities.enumerated()), id: \.offset) { index, city in
                            MeetingRow(city: city, instant: instant, format: model.preferences,
                                       source: index == 0, showSeconds: model.showSeconds, daylight: model.meetingDaylight[city] ?? [])
                                .id(index)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.meetingScroll) { _, index in scroll.scrollTo(index) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.status.isEmpty {
                Text(model.status).foregroundStyle(Theme.accent).font(.caption)
                    .textSelection(.enabled)
            }
            if model.reorderOriginal != nil {
                shortcuts([("↑↓", "Move"), ("↵", "Save"), ("Esc", "Undo")])
            } else if model.meeting != nil {
                shortcuts([("↑↓", "Scroll"), ("M", "Edit meeting"), ("T", "12/24 h"), ("S", "Seconds"), ("Esc", "Live"), ("Q", "Quit")])
            } else {
                shortcuts([("↑↓", "Select"), ("A", "Add"), ("E", "Edit"), ("D", "Delete"),
                           ("R", "Reorder"), ("M", "Meeting"), ("G", "Layout"), ("T", "12/24 h"), ("S", "Seconds"), ("Q", "Quit")])
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func shortcuts(_ keys: [(String, String)]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(keys, id: \.0) { key, label in Shortcut(key: key, label: label) }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 11) {
                    ForEach(keys.prefix(5), id: \.0) { key, label in Shortcut(key: key, label: label) }
                }
                HStack(spacing: 11) {
                    ForEach(keys.dropFirst(5), id: \.0) { key, label in Shortcut(key: key, label: label) }
                }
            }
        }
    }

    private func countdown(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(model.now))
        guard seconds != 0 else { return "Starting now" }
        let absolute = abs(seconds)
        let minutes = seconds > 0 ? (absolute + 59) / 60 : absolute / 60
        let elapsed = absolute < 60 ? "<1m" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        return seconds > 0 ? "Starts in \(elapsed)" : "Started \(elapsed) ago"
    }
}

struct Shortcut: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Theme.selection, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .fixedSize()
    }
}

struct Pixels: View {
    let rows: [String]
    let size: CGFloat

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        Circle().fill(Theme.accent.opacity(value == "1" ? 1 : 0))
                            .frame(width: size, height: size)
                    }
                }
            }
        }
    }
}

struct CityCard: View {
    let city: City
    let selected: Bool
    @ObservedObject var model: Dashboard

    private var solar: Solar? { model.solar[city] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? Theme.accent : Theme.muted)
                Text(city.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Spacer()
                if let phase = solar?.phase {
                    Text(phase.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(phase == "Daylight" ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.background, in: Capsule())
                }
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    DotClock(time: city.formatted(model.now, model.showSeconds ? model.preferences.timeFormat : model.preferences.minuteFormat))
                    Text(city.formatted(model.now, "EEE, dd MMM") + "  ·  " + city.zone)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 2)
                weather
            }
            SunPath(solar: solar, now: model.now).frame(height: 43)
            HStack(spacing: 8) {
                metric("SUNRISE", solar?.sunrise.map { city.formatted($0, model.preferences.minuteFormat) } ?? "—",
                       symbol: "sunrise")
                metric("DAYLIGHT", solar.map { "\($0.daylightMinutes / 60)h \($0.daylightMinutes % 60)m" } ?? "—",
                       alignment: .center)
                metric("SUNSET", solar?.sunset.map { city.formatted($0, model.preferences.minuteFormat) } ?? "—",
                       symbol: "sunset", alignment: .trailing)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.selection : Theme.panel, in: RoundedRectangle(cornerRadius: 19))
        .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var weather: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let weather = model.weather[city.key] {
                HStack(spacing: 8) {
                    Image(systemName: weather.symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(Int(weather.temperature_2m.rounded()))°C")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                        Text(weather.condition + (model.stale.contains(city.key) ? " · Stale" : ""))
                    }
                }
            } else {
                Text(model.weatherLoaded ? "No weather" : "Loading weather")
            }
        }
        .fixedSize()
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Theme.muted)
    }

    private func metric(_ name: String, _ value: String, symbol: String? = nil, alignment: Alignment = .leading) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: alignment.horizontal, spacing: 3) {
                Text(name).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct SunPath: View {
    let solar: Solar?
    let now: Date

    var body: some View {
        if let solar, solar.intervals.count == 1, let sunrise = solar.sunrise, let sunset = solar.sunset, sunset > sunrise {
            let progress = now.timeIntervalSince(sunrise) / sunset.timeIntervalSince(sunrise)
            Canvas { context, size in
                let inset: CGFloat = 7
                let horizon = size.height - 6
                let height = max(0, horizon - 6)
                let width = max(0, size.width - inset * 2)
                func point(_ fraction: Double) -> CGPoint {
                    CGPoint(x: inset + width * fraction, y: horizon - height * 4 * fraction * (1 - fraction))
                }
                func arc(_ fraction: Double) -> Path {
                    Path { path in
                        path.move(to: point(0))
                        for step in 1...48 {
                            path.addLine(to: point(fraction * Double(step) / 48))
                        }
                    }
                }
                let baseline = Path { path in
                    path.move(to: CGPoint(x: 0, y: horizon))
                    path.addLine(to: CGPoint(x: size.width, y: horizon))
                }
                context.stroke(baseline, with: .color(Theme.border), lineWidth: 1)
                context.stroke(arc(1), with: .color(Theme.muted.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                if progress > 0 {
                    context.stroke(arc(min(1, progress)), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                for end in [0.0, 1.0] {
                    let position = point(end)
                    context.fill(Path(ellipseIn: CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)), with: .color(Theme.muted))
                }
                if (0...1).contains(progress) {
                    let position = point(progress)
                    context.fill(Path(ellipseIn: CGRect(x: position.x - 6, y: position.y - 6, width: 12, height: 12)), with: .color(Theme.accent.opacity(0.2)))
                    context.fill(Path(ellipseIn: CGRect(x: position.x - 3.5, y: position.y - 3.5, width: 7, height: 7)), with: .color(Theme.ink))
                }
            }
            .accessibilityLabel("Daylight progress")
            .accessibilityValue(progress < 0 ? "Before sunrise" : progress > 1 ? "After sunset" : "\(Int(progress * 100)) percent")
        } else {
            DaylightBar(solar: solar, now: now).frame(height: 7)
        }
    }
}

struct DaylightBar: View {
    let solar: Solar?
    let now: Date

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                if let solar, solar.end > solar.start {
                    let span = solar.end - solar.start
                    ForEach(Array(solar.intervals.enumerated()), id: \.offset) { _, interval in
                        Capsule().fill(Theme.accent.opacity(0.75))
                            .frame(width: (interval[1] - interval[0]) / span * geo.size.width)
                            .offset(x: (interval[0] - solar.start) / span * geo.size.width)
                    }
                    let progress = min(1, max(0, (now.timeIntervalSince1970 - solar.start) / span))
                    Circle().fill(Theme.ink).frame(width: 7, height: 7)
                        .offset(x: progress * max(0, geo.size.width - 7))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct MeetingRow: View {
    let city: City
    let instant: Date
    let format: Preferences
    let source: Bool
    let showSeconds: Bool
    let daylight: [[TimeInterval]]

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(city.name).font(.headline).lineLimit(1)
                    .foregroundStyle(source ? Theme.accent : Theme.ink)
                Text(city.formatted(instant, showSeconds ? format.timeFormat : format.minuteFormat))
                    .font(.system(size: 24, weight: .bold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.65)
                Text(city.formatted(instant, "EEE dd MMM  ZZZZZ"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            .frame(width: 158, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(-4...4, id: \.self) { step in
                    let date = instant.addingTimeInterval(Double(step) * 3600)
                    let previous = date.addingTimeInterval(-3600)
                    let daylit = daylight.contains { $0[0] <= date.timeIntervalSince1970 && date.timeIntervalSince1970 < $0[1] }
                    let crossover = city.formatted(date, "yyyy-MM-dd") != city.formatted(previous, "yyyy-MM-dd")
                    VStack(spacing: 4) {
                        Text(crossover ? city.formatted(date, "dd MMM").uppercased() : " ")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
                        Text(city.formatted(date, format.clock_format == "am_pm" ? "ha" : "HH"))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(step == 0 ? Theme.background : Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 31)
                            .background(step == 0 ? Theme.accent : daylit ? Theme.selection : Theme.background,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(source ? Theme.accent : Theme.border) }
    }
}

struct DialogView: View {
    @ObservedObject var model: Dashboard
    let dialog: Dialog
    @FocusState private var field: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 27, weight: .heavy, design: .monospaced)).tracking(-1)
                .accessibilityAddTraits(.isHeader)
            contents
            if !model.error.isEmpty {
                Text(model.error).font(.callout).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 15) {
                if dialog == .meetingLocation || dialog == .add || dialog == .repeatedTime {
                    Shortcut(key: "↑↓", label: "Choose")
                }
                if dialog == .meetingTime || dialog == .edit || dialog == .manual {
                    Shortcut(key: "Tab", label: "Field")
                }
                if dialog == .add { Shortcut(key: "⌃N", label: "Manual entry") }
                Shortcut(key: "↵", label: dialog == .delete ? "Remove" : "Confirm")
                Shortcut(key: "Esc", label: "Back")
            }
        }
        .padding(24)
        .frame(width: 485, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.accent) }
        .shadow(color: .black.opacity(0.65), radius: 22, y: 8)
        .defaultFocus($field, dialog == .meetingTime ? 2 : 1)
        .onAppear { field = dialog == .meetingTime ? 2 : 1 }
    }

    private var title: String {
        switch dialog {
        case .add: "Add location"
        case .edit: "Edit location"
        case .manual: "Add location manually"
        case .meetingLocation: "Meeting location"
        case .meetingTime: "Meeting time"
        case .repeatedTime: "Choose an occurrence"
        case .delete: "Remove location?"
        }
    }

    @ViewBuilder private var contents: some View {
        switch dialog {
        case .add, .meetingLocation:
            TextField("Search by city name", text: $model.query)
                .focused($field, equals: 1)
                .textFieldStyle(.plain)
                .padding(11)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.query) { _, _ in model.refreshSuggestions() }
                .accessibilityLabel("Search by city name")
            if model.suggestions.isEmpty {
                Text(model.query.isEmpty ? "Type to find a city." : "No matching locations.")
                    .foregroundStyle(Theme.muted).font(.callout)
            } else {
                let start = max(0, model.option - 4)
                VStack(spacing: 3) {
                    ForEach(Array(model.suggestions.enumerated().dropFirst(start).prefix(5)), id: \.offset) { index, city in
                        choice(index, city.name, city.region.map { "\($0) · \(city.zone)" } ?? city.zone)
                    }
                }
            }
        case .edit, .manual:
            VStack(spacing: 9) {
                ForEach(Array(["Name", "IANA time zone", "Latitude", "Longitude"].enumerated()), id: \.offset) { index, label in
                    editor(index, label)
                }
            }
        case .meetingTime:
            if let source = model.source {
                Text(source.name + "  ·  " + source.zone).font(.callout).foregroundStyle(Theme.muted)
            }
            VStack(spacing: 9) {
                editor(0, "Date")
                editor(1, "Time", prompt: "14:30 or 2:30 PM")
            }
        case .repeatedTime:
            Text("This local time occurs twice.").font(.callout).foregroundStyle(Theme.muted)
            ForEach(Array(model.occurrences.enumerated()), id: \.offset) { index, occurrence in
                choice(index, index == 0 ? "Earlier" : "Later", "UTC" + occurrence.offset)
            }
        case .delete:
            Text(model.selectedCity?.name ?? "").font(.headline)
        }
    }

    private func editor(_ index: Int, _ label: String, prompt: String = "") -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted).frame(width: 100, alignment: .leading)
            TextField(prompt, text: $model.fields[index])
                .textFieldStyle(.plain).padding(9)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                .focused($field, equals: index + 1)
                .accessibilityLabel(label)
        }
        .font(.system(.body, design: .monospaced))
    }

    private func choice(_ index: Int, _ name: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: index == model.option ? "arrowtriangle.right.fill" : "circle")
                .font(.system(size: 8)).foregroundStyle(index == model.option ? Theme.accent : Theme.muted)
            Text(name).font(.callout.bold()).lineLimit(1)
            Spacer()
            Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(index == model.option ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(index == model.option ? .isSelected : [])
    }
}
