mod cities;
mod config;
mod desktop;
mod meeting;
mod solar;
mod weather;

use chrono::{DateTime, NaiveDate, Utc};
use config::{ClockFormat, Config, Layout, Location, WeatherIcons};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use meeting::{Meeting, MeetingForm, MeetingPicker};
use ratatui::{
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
    DefaultTerminal, Frame,
};
use solar::{Phase, SolarDay};
use std::{error::Error, io, path::PathBuf, time::Duration};

const CARD_HEIGHT: u16 = 9;
const BACKGROUND: Color = Color::Rgb(0x0B, 0x0C, 0x16);
const TEXT: Color = Color::Rgb(0xDD, 0xF7, 0xFF);
const ACCENT: Color = Color::Rgb(0x82, 0xFB, 0x9C);
const SELECTION: Color = Color::Rgb(0x1F, 0x25, 0x3A);
const BORDER: Color = Color::Rgb(0x2D, 0x34, 0x50);
const MUTED: Color = Color::Rgb(0x86, 0xA7, 0xDF);
const SUN: Color = Color::Rgb(0x4F, 0xE8, 0x8F);
const DAWN: Color = Color::Rgb(0x7C, 0xF8, 0xF7);
const DUSK: Color = Color::Rgb(0xCD, 0xDB, 0xF4);
const NIGHT: Color = Color::Rgb(0x82, 0x9D, 0xD4);
const FEEDBACK: Color = Color::Rgb(0xA4, 0xFF, 0xEC);

fn main() -> Result<(), Box<dyn Error>> {
    if std::env::args().nth(1).as_deref() == Some("--desktop-bridge") {
        return desktop::run();
    }
    if std::env::args().any(|arg| matches!(arg.as_str(), "-h" | "--help")) {
        println!("worldclock — local time and daylight for saved locations\n\nUsage: worldclock\n\nConfig: {}", Config::path()?.display());
        return Ok(());
    }

    let path = Config::path()?;
    let config = Config::load(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    let mut app = App {
        config,
        path,
        selected: 0,
        offset: 0,
        cache: Vec::new(),
        weather: weather::Weather::default(),
        form: None,
        meeting: None,
        meeting_form: None,
        meeting_picker: None,
        confirming_delete: false,
        reorder: None,
        notice: None,
    };
    let mut terminal = ratatui::try_init()?;
    let result = app.run(&mut terminal);
    let restore = ratatui::try_restore();
    result?;
    restore?;
    Ok(())
}

struct Reorder {
    original: Vec<Location>,
    selected: usize,
}

struct App {
    config: Config,
    path: PathBuf,
    selected: usize,
    offset: usize,
    cache: Vec<(NaiveDate, SolarDay)>,
    weather: weather::Weather,
    form: Option<Form>,
    meeting: Option<Meeting>,
    meeting_form: Option<MeetingForm>,
    meeting_picker: Option<MeetingPicker>,
    confirming_delete: bool,
    reorder: Option<Reorder>,
    notice: Option<String>,
}

impl App {
    fn run(&mut self, terminal: &mut DefaultTerminal) -> io::Result<()> {
        loop {
            let now = Utc::now();
            self.weather.refresh(&self.config.locations);
            if self.meeting.is_none() {
                self.refresh_solar_days(now);
            }
            terminal.draw(|frame| self.draw(frame, now))?;
            let remaining = 1000 - Utc::now().timestamp_subsec_millis();
            if event::poll(Duration::from_millis(remaining.into()))? {
                if let Event::Key(key) = event::read()? {
                    if key.kind != KeyEventKind::Release && self.handle_key(key) {
                        return Ok(());
                    }
                }
            }
        }
    }

    fn refresh_solar_days(&mut self, now: DateTime<Utc>) {
        for (index, location) in self.config.locations.iter().enumerate() {
            let date = now.with_timezone(&location.zone).date_naive();
            if self.cache.get(index).is_some_and(|entry| entry.0 == date) {
                continue;
            }
            let entry = (
                date,
                SolarDay::calculate(date, location.zone, location.latitude, location.longitude),
            );
            if index == self.cache.len() {
                self.cache.push(entry);
            } else {
                self.cache[index] = entry;
            }
        }
    }

    fn handle_key(&mut self, key: KeyEvent) -> bool {
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            return true;
        }
        if self.reorder.is_some() {
            self.reorder_key(key.code);
            return false;
        }
        if let Some(form) = &mut self.meeting_form {
            if key.code == KeyCode::Esc {
                self.meeting_form = None;
            } else if let Some(meeting) = form.input(key) {
                self.meeting = Some(meeting);
                self.meeting_picker = None;
                self.meeting_form = None;
            }
            return false;
        }
        if let Some(picker) = &mut self.meeting_picker {
            if key.code == KeyCode::Esc {
                self.meeting_picker = None;
            } else if let Some(location) = picker.input(key, &self.config.locations) {
                self.meeting_form = Some(MeetingForm::new(
                    location,
                    self.meeting.as_ref().map(|meeting| meeting.instant),
                    self.config.clock_format,
                ));
            }
            return false;
        }
        if self.confirming_delete {
            match key.code {
                KeyCode::Char('y') => {
                    let mut locations = self.config.locations.clone();
                    locations.remove(self.selected);
                    self.save(locations, self.selected);
                    self.confirming_delete = false;
                }
                KeyCode::Esc | KeyCode::Char('n') => self.confirming_delete = false,
                _ => {}
            }
            return false;
        }
        if let Some(form) = &mut self.form {
            match key.code {
                KeyCode::Esc => self.form = None,
                KeyCode::Enter if form.active == 0 && !form.suggestions.is_empty() => {
                    form.apply_suggestion();
                }
                KeyCode::Enter => match form.location() {
                    Ok(location) => {
                        let mut locations = self.config.locations.clone();
                        let index = form.editing.unwrap_or(locations.len());
                        if form.editing.is_some() {
                            locations[index] = location;
                        } else {
                            locations.push(location);
                        }
                        if self.save(locations, index) {
                            self.form = None;
                        }
                    }
                    Err(error) => form.error = Some(error.into()),
                },
                _ => form.input(key),
            }
            return false;
        }

        if let Some(meeting) = &mut self.meeting {
            match key.code {
                KeyCode::Up | KeyCode::Char('k') => {
                    meeting.offset = meeting.offset.saturating_sub(1);
                    return false;
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    meeting.offset += 1;
                    return false;
                }
                KeyCode::Esc | KeyCode::Char('q' | 'm' | 't') => {}
                _ => return false,
            }
        }

        let count = self.config.locations.len();
        self.notice = None;
        match key.code {
            KeyCode::Esc if self.meeting.is_some() => self.meeting = None,
            KeyCode::Esc | KeyCode::Char('q') => return true,
            KeyCode::Char('m') => {
                self.meeting_picker =
                    Some(MeetingPicker::new(&self.config.locations, self.selected));
            }
            KeyCode::Up | KeyCode::Char('k') => self.selected = self.selected.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                self.selected = (self.selected + 1).min(count.saturating_sub(1))
            }
            KeyCode::Home => self.selected = 0,
            KeyCode::End => self.selected = count.saturating_sub(1),
            KeyCode::Char('r') if count > 1 => {
                self.reorder = Some(Reorder {
                    original: self.config.locations.clone(),
                    selected: self.selected,
                });
            }
            KeyCode::Char('r') => self.notice = Some(" Add two cities to reorder.".into()),
            KeyCode::Char('g') => {
                let mut config = self.config.clone();
                config.layout = match config.layout {
                    Layout::Grid => Layout::List,
                    Layout::List => Layout::Grid,
                };
                self.commit(config);
            }
            KeyCode::Char('w') => {
                let mut config = self.config.clone();
                config.weather_icons = match config.weather_icons {
                    WeatherIcons::Pixel => WeatherIcons::Emoji,
                    WeatherIcons::Emoji => WeatherIcons::Pixel,
                };
                self.commit(config);
            }
            KeyCode::Char('t') => {
                let mut config = self.config.clone();
                config.clock_format = match config.clock_format {
                    ClockFormat::TwentyFourHour => ClockFormat::AmPm,
                    ClockFormat::AmPm => ClockFormat::TwentyFourHour,
                };
                self.commit(config);
            }
            KeyCode::Char('a') => self.form = Some(Form::new(None)),
            KeyCode::Char('e') | KeyCode::Enter if count > 0 => {
                self.form = Some(Form::new(Some((
                    self.selected,
                    &self.config.locations[self.selected],
                ))));
            }
            KeyCode::Char('d') | KeyCode::Delete if count > 0 => self.confirming_delete = true,
            _ => {}
        }
        false
    }

    fn reorder_key(&mut self, key: KeyCode) {
        self.notice = None;
        let destination = match key {
            KeyCode::Up | KeyCode::Char('k') => self.selected.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                (self.selected + 1).min(self.config.locations.len() - 1)
            }
            KeyCode::Enter => {
                if self.commit(self.config.clone()) {
                    self.reorder = None;
                }
                return;
            }
            KeyCode::Esc => {
                if let Some(reorder) = self.reorder.take() {
                    self.config.locations = reorder.original;
                    self.selected = reorder.selected;
                    self.cache.clear();
                }
                return;
            }
            _ => return,
        };
        self.config.locations.swap(self.selected, destination);
        self.cache.swap(self.selected, destination);
        self.selected = destination;
    }

    fn save(&mut self, locations: Vec<Location>, index: usize) -> bool {
        let config = Config {
            locations,
            ..self.config.clone()
        };
        if !self.commit(config) {
            return false;
        }
        self.selected = index.min(self.config.locations.len().saturating_sub(1));
        self.cache.clear();
        true
    }

    fn commit(&mut self, config: Config) -> bool {
        if let Err(error) = config.save(&self.path) {
            let message = format!("Save failed: {error}");
            if let Some(form) = &mut self.form {
                form.error = Some(message);
            } else {
                self.notice = Some(message);
            }
            return false;
        }
        self.config = config;
        true
    }

    fn draw(&mut self, frame: &mut Frame, instant: DateTime<Utc>) {
        let area = frame.area();
        frame.render_widget(
            Block::default().style(Style::new().fg(TEXT).bg(BACKGROUND)),
            area,
        );
        if area.width < 32 || area.height < CARD_HEIGHT + 3 {
            frame.render_widget(Paragraph::new("Resize to at least 32 × 12"), area);
            return;
        }

        if let Some(meeting) = &mut self.meeting {
            meeting.draw(frame, area, &self.config, instant);
            self.draw_meeting_dialog(frame, area);
            return;
        }

        let header = Line::from(vec![
            Span::styled(
                " WORLDCLOCK ",
                Style::new().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(
                    "  {} UTC",
                    instant.format(self.config.clock_format.with_seconds())
                ),
                Style::new().fg(MUTED),
            ),
        ]);
        frame.render_widget(Paragraph::new(header), Rect::new(0, 0, area.width, 1));

        let count = self.config.locations.len();
        let columns: u16 = match self.config.layout {
            Layout::Grid if area.width >= 76 => 2,
            _ => 1,
        };
        let rows = (area.height - 3) / CARD_HEIGHT;
        let capacity = usize::from(rows * columns);
        let columns_usize = usize::from(columns);
        let selected_row = self.selected / columns_usize;
        let last_offset = count
            .div_ceil(columns_usize)
            .saturating_sub(usize::from(rows));
        self.offset = self.offset.min(last_offset);
        if selected_row < self.offset {
            self.offset = selected_row;
        } else if selected_row >= self.offset + usize::from(rows) {
            self.offset = selected_row + 1 - usize::from(rows);
        }

        let start = self.offset * columns_usize;
        for (slot, location) in self
            .config
            .locations
            .iter()
            .skip(start)
            .take(capacity)
            .enumerate()
        {
            let index = start + slot;
            let column = slot as u16 % columns;
            let width = area.width / columns;
            let x = column * width;
            let width = if column + 1 == columns {
                area.width - x
            } else {
                width
            };
            let y = 1 + slot as u16 / columns * CARD_HEIGHT;
            draw_card(
                frame,
                Rect::new(x, y, width, CARD_HEIGHT),
                location,
                &self.cache[index].1,
                instant,
                index == self.selected,
                self.config.clock_format,
                self.weather
                    .for_location(location, self.config.weather_icons),
            );
        }

        if count == 0 {
            frame.render_widget(
                Paragraph::new(" Press a to add a location.").style(Style::new().fg(MUTED)),
                Rect::new(0, 2, area.width, 1),
            );
        }

        let status = self.notice.clone().unwrap_or_else(|| {
            let layout = match self.config.layout {
                Layout::Grid => "Grid",
                Layout::List => "List",
            };
            let format = match self.config.clock_format {
                ClockFormat::TwentyFourHour => "24h",
                ClockFormat::AmPm => "AM/PM",
            };
            let position = if count == 0 { 0 } else { self.selected + 1 };
            if self.reorder.is_some() {
                format!(" REORDER   {position}/{count}")
            } else {
                let icons = match self.config.weather_icons {
                    WeatherIcons::Pixel => "Pixel",
                    WeatherIcons::Emoji => "Emoji",
                };
                if area.width >= 43 {
                    format!(" r Reorder  g {layout}  t {format}  w {icons}  {position}/{count}")
                } else {
                    format!(" r Order g {layout} t {format} w {icons}")
                }
            }
        });
        frame.render_widget(
            Paragraph::new(status).style(Style::new().fg(MUTED)),
            Rect::new(0, area.height - 2, area.width, 1),
        );
        let keys = if self.reorder.is_some() {
            " ↑↓ Move  Enter Save  Esc Undo"
        } else if area.width >= 61 {
            " ↑↓ Select   m Meeting   a Add   e Edit   d Delete   q Quit"
        } else {
            " ↑↓ m Meet a Add e Edit d Del q"
        };
        frame.render_widget(
            Paragraph::new(keys).style(Style::new().fg(ACCENT)),
            Rect::new(0, area.height - 1, area.width, 1),
        );

        self.draw_meeting_dialog(frame, area);
        if let Some(form) = &self.form {
            form.draw(frame, area);
        } else if self.confirming_delete {
            let popup = centered(area, 52, 5);
            frame.render_widget(Clear, popup);
            frame.render_widget(
                Paragraph::new(vec![
                    Line::from(self.config.locations[self.selected].name.as_str()),
                    Line::from("y Delete   n Cancel"),
                ])
                .block(panel(" Remove location ", true)),
                popup,
            );
        }
    }
    fn draw_meeting_dialog(&self, frame: &mut Frame, area: Rect) {
        if let Some(form) = &self.meeting_form {
            form.draw(frame, area);
        } else if let Some(picker) = &self.meeting_picker {
            picker.draw(frame, area);
        }
    }
}

fn panel(title: impl Into<Line<'static>>, selected: bool) -> Block<'static> {
    Block::default()
        .style(
            Style::new()
                .fg(TEXT)
                .bg(if selected { SELECTION } else { BACKGROUND }),
        )
        .borders(Borders::ALL)
        .border_style(Style::new().fg(if selected { ACCENT } else { BORDER }))
        .title_style(Style::new().fg(if selected { ACCENT } else { TEXT }))
        .title(title)
}

fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    )
}

fn draw_card(
    frame: &mut Frame,
    area: Rect,
    location: &Location,
    day: &SolarDay,
    now: DateTime<Utc>,
    selected: bool,
    clock_format: ClockFormat,
    weather: weather::Display,
) {
    let local = now.with_timezone(&location.zone);
    let (phase, phase_color) = match solar::phase(now, location.latitude, location.longitude) {
        Phase::Dawn => ("Dawn", DAWN),
        Phase::Daylight => ("Daylight", SUN),
        Phase::Dusk => ("Dusk", DUSK),
        Phase::Night => ("Night", NIGHT),
    };
    let minutes = day.duration().num_minutes();
    let rise = day
        .daylight
        .iter()
        .find(|(start, _)| *start > day.start)
        .map(|(start, _)| {
            start
                .with_timezone(&location.zone)
                .format(clock_format.minutes())
                .to_string()
        });
    let set = day
        .daylight
        .iter()
        .find(|(_, end)| *end < day.end)
        .map(|(_, end)| {
            end.with_timezone(&location.zone)
                .format(clock_format.minutes())
                .to_string()
        });
    let bar_width = usize::from(area.width.saturating_sub(4));
    let seconds = (day.end - day.start).num_seconds();
    let marker = ((now - day.start).num_seconds() * bar_width as i64 / seconds)
        .clamp(0, bar_width as i64 - 1) as usize;
    let mut bar = vec![Span::raw(" ")];
    for index in 0..bar_width {
        let cell = day.start
            + chrono::Duration::seconds(seconds * (2 * index as i64 + 1) / (2 * bar_width as i64));
        let light = day
            .daylight
            .iter()
            .any(|(start, end)| *start <= cell && cell < *end);
        let (symbol, color) = if index == marker {
            ("◆", TEXT)
        } else if light {
            ("━", SUN)
        } else {
            ("─", NIGHT)
        };
        bar.push(Span::styled(symbol, Style::new().fg(color)));
    }
    let show_sprite = area.width >= 46 && !weather.sprite[0].is_empty();
    let lines = vec![
        Line::from(vec![
            Span::styled(
                format!(" {}  ", local.format(clock_format.with_seconds())),
                Style::new().fg(TEXT).add_modifier(Modifier::BOLD),
            ),
            Span::styled(phase, Style::new().fg(phase_color)),
        ]),
        Line::styled(
            format!(" {}  {}", local.format("%a %Y-%m-%d"), location.zone),
            Style::new().fg(MUTED),
        ),
        Line::styled(
            format!(" Daylight  {}h {:02}m", minutes / 60, minutes % 60),
            Style::new().fg(SUN),
        ),
        Line::styled(
            format!(" Sunrise  {}", rise.as_deref().unwrap_or("—")),
            Style::new().fg(MUTED),
        ),
        Line::styled(
            format!(" Sunset   {}", set.as_deref().unwrap_or("—")),
            Style::new().fg(MUTED),
        ),
        Line::styled(
            if show_sprite || weather.icon.is_empty() {
                format!(" {}", weather.label)
            } else {
                format!(" {}  {}", weather.icon, weather.label)
            },
            Style::new().fg(TEXT),
        ),
        Line::from(bar),
    ];
    frame.render_widget(
        Paragraph::new(lines).block(panel(format!(" {} ", location.name), selected)),
        area,
    );
    if show_sprite {
        let sprite = weather
            .sprite
            .map(|row| Line::styled(row, Style::new().fg(DAWN)));
        frame.render_widget(
            Paragraph::new(sprite.to_vec()),
            Rect::new(area.right() - 9, area.y + 3, 5, 3),
        );
    }
}

const LABELS: [&str; 4] = ["Name", "IANA time zone", "Latitude", "Longitude"];

struct Form {
    fields: [String; 4],
    active: usize,
    editing: Option<usize>,
    error: Option<String>,
    suggestions: Vec<cities::City>,
    suggested: usize,
}

impl Form {
    fn new(editing: Option<(usize, &Location)>) -> Self {
        let fields = editing.map_or_else(
            || std::array::from_fn(|_| String::new()),
            |(_, location)| {
                [
                    location.name.clone(),
                    location.zone.to_string(),
                    location.latitude.to_string(),
                    location.longitude.to_string(),
                ]
            },
        );
        Self {
            fields,
            active: 0,
            editing: editing.map(|(index, _)| index),
            error: None,
            suggestions: Vec::new(),
            suggested: 0,
        }
    }

    fn location(&self) -> Result<Location, &'static str> {
        let location = Location {
            name: self.fields[0].trim().into(),
            zone: self.fields[1]
                .trim()
                .parse()
                .map_err(|_| "Enter an IANA zone, e.g. Asia/Tokyo.")?,
            latitude: self.fields[2]
                .trim()
                .parse()
                .map_err(|_| "Enter latitude in decimal degrees.")?,
            longitude: self.fields[3]
                .trim()
                .parse()
                .map_err(|_| "Enter longitude in decimal degrees.")?,
        };
        location.validate()?;
        Ok(location)
    }

    fn apply_suggestion(&mut self) {
        let city = &self.suggestions[self.suggested];
        self.fields = [
            city.name.into(),
            city.zone.into(),
            city.latitude.into(),
            city.longitude.into(),
        ];
        self.suggestions.clear();
        self.suggested = 0;
        self.error = None;
        self.active = 1;
    }

    fn input(&mut self, key: KeyEvent) {
        self.error = None;
        match key.code {
            KeyCode::Up if self.active == 0 && !self.suggestions.is_empty() => {
                self.suggested = self.suggested.saturating_sub(1);
                return;
            }
            KeyCode::Down if self.active == 0 && !self.suggestions.is_empty() => {
                self.suggested = (self.suggested + 1).min(self.suggestions.len() - 1);
                return;
            }
            _ => {}
        }
        let previous_name = self.fields[0].clone();
        match key.code {
            KeyCode::BackTab | KeyCode::Up => {
                self.active = (self.active + self.fields.len() - 1) % self.fields.len()
            }
            KeyCode::Tab | KeyCode::Down => self.active = (self.active + 1) % self.fields.len(),
            _ => edit_field(&mut self.fields[self.active], key),
        }
        if self.fields[0] != previous_name {
            self.suggestions = cities::search(&self.fields[0]);
            self.suggested = 0;
        }
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let searching = self.active == 0 && !self.suggestions.is_empty();
        let visible_suggestions = if searching {
            self.suggestions
                .len()
                .min(usize::from(area.height.saturating_sub(9)))
        } else {
            0
        };
        let popup = centered(area, 66, 9 + visible_suggestions as u16);
        frame.render_widget(Clear, popup);
        let mut lines = Vec::new();
        for (index, (label, value)) in LABELS.iter().zip(&self.fields).enumerate() {
            let active = index == self.active;
            lines.push(Line::styled(
                format!(
                    "{} {:14} {}{}",
                    if active { "›" } else { " " },
                    label,
                    value,
                    if active { "▏" } else { "" }
                ),
                Style::new().fg(if active { ACCENT } else { TEXT }),
            ));
        }
        if searching {
            let start = (self.suggested + 1).saturating_sub(visible_suggestions);
            for (index, city) in self
                .suggestions
                .iter()
                .enumerate()
                .skip(start)
                .take(visible_suggestions)
            {
                let selected = index == self.suggested;
                lines.push(Line::styled(
                    format!(
                        "{} {}, {}  {}",
                        if selected { "›" } else { " " },
                        city.name,
                        city.region,
                        city.zone
                    ),
                    Style::new().fg(if selected { ACCENT } else { MUTED }),
                ));
            }
        }
        lines.push(Line::styled(
            if searching {
                " ↑↓ Choose  Enter Fill  Tab Next"
            } else {
                " Tab Next  Enter Save  Esc Cancel"
            },
            Style::new().fg(MUTED),
        ));
        lines.push(Line::styled(" Ctrl+U Clear field", Style::new().fg(MUTED)));
        if let Some(error) = &self.error {
            lines.push(Line::styled(
                error.as_str(),
                Style::new().fg(FEEDBACK).add_modifier(Modifier::BOLD),
            ));
        }
        let title = if self.editing.is_some() {
            " Edit location "
        } else {
            " Add location "
        };
        frame.render_widget(Paragraph::new(lines).block(panel(title, true)), popup);
    }
}

fn edit_field(field: &mut String, key: KeyEvent) {
    match key.code {
        KeyCode::Backspace => {
            field.pop();
        }
        KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => field.clear(),
        KeyCode::Char(character)
            if !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
                && !character.is_control() =>
        {
            field.push(character);
        }
        _ => {}
    }
}
