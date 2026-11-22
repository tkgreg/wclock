use crate::{
    centered, cities,
    config::{ClockFormat, Config, Location},
    edit_field, panel, solar, ACCENT, BACKGROUND, BORDER, DAWN, FEEDBACK, MUTED, SELECTION, SUN,
    TEXT,
};
use chrono::{DateTime, Datelike, LocalResult, NaiveDate, NaiveTime, TimeZone, Timelike, Utc};
use chrono_tz::Tz;
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Clear, Paragraph},
    Frame,
};

pub struct Meeting {
    pub instant: DateTime<Utc>,
    source: Location,
    pub offset: usize,
}

#[derive(Clone)]
pub struct MeetingLocation {
    location: Location,
    region: Option<&'static str>,
}

pub struct MeetingPicker {
    query: String,
    choices: Vec<MeetingLocation>,
    selected: usize,
}

impl MeetingPicker {
    pub fn new(saved: &[Location], selected: usize) -> Self {
        let mut picker = Self {
            query: String::new(),
            choices: Vec::new(),
            selected: 0,
        };
        picker.refresh(saved);
        picker.selected = selected.min(picker.choices.len().saturating_sub(1));
        picker
    }

    fn refresh(&mut self, saved: &[Location]) {
        let query = self.query.trim().to_lowercase();
        self.choices = saved
            .iter()
            .filter(|location| location.name.to_lowercase().contains(&query))
            .map(|location| MeetingLocation {
                location: location.clone(),
                region: None,
            })
            .collect();
        for city in cities::search(&query) {
            let (Ok(zone), Ok(latitude), Ok(longitude)) = (
                city.zone.parse(),
                city.latitude.parse(),
                city.longitude.parse(),
            ) else {
                continue;
            };
            if !self.choices.iter().any(|choice| {
                choice.location.zone == zone && choice.location.name.eq_ignore_ascii_case(city.name)
            }) {
                self.choices.push(MeetingLocation {
                    location: Location {
                        name: city.name.into(),
                        zone,
                        latitude,
                        longitude,
                    },
                    region: Some(city.region),
                });
            }
        }
        self.selected = 0;
    }

    pub fn input(&mut self, key: KeyEvent, saved: &[Location]) -> Option<MeetingLocation> {
        match key.code {
            KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::Down => {
                self.selected = (self.selected + 1).min(self.choices.len().saturating_sub(1))
            }
            KeyCode::Enter => {
                return self.choices.get(self.selected).cloned();
            }
            _ => {
                let previous = self.query.clone();
                edit_field(&mut self.query, key);
                if self.query != previous {
                    self.refresh(saved);
                }
            }
        }
        None
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let visible = self
            .choices
            .len()
            .clamp(1, usize::from(area.height - 5).min(8));
        let popup = centered(area, 62, visible as u16 + 5);
        frame.render_widget(Clear, popup);
        let mut lines = vec![Line::styled(
            if self.query.is_empty() {
                " Type a city name ▏".into()
            } else {
                format!(" Search  {}▏", self.query)
            },
            Style::new().fg(TEXT),
        )];
        let offset = (self.selected + 1).saturating_sub(visible);
        for (index, choice) in self.choices.iter().enumerate().skip(offset).take(visible) {
            let selected = index == self.selected;
            lines.push(Line::styled(
                format!(
                    "{} {} · {} · {}",
                    if selected { "›" } else { " " },
                    choice.location.name,
                    choice.region.unwrap_or("Saved"),
                    choice.location.zone
                ),
                Style::new().fg(if selected { ACCENT } else { TEXT }),
            ));
        }
        if self.choices.is_empty() {
            lines.push(Line::styled(
                " No matching locations",
                Style::new().fg(MUTED),
            ));
        }
        lines.push(Line::styled(
            " ↑↓ Pick  Enter Next  Esc Back",
            Style::new().fg(MUTED),
        ));
        frame.render_widget(
            Paragraph::new(lines).block(panel(" Meeting location ", true)),
            popup,
        );
    }
}

pub struct MeetingForm {
    source: Location,
    fields: [String; 2],
    active: usize,
    error: Option<&'static str>,
    repeated: Option<[DateTime<Tz>; 2]>,
}

impl MeetingForm {
    pub fn new(
        location: MeetingLocation,
        previous: Option<DateTime<Utc>>,
        format: ClockFormat,
    ) -> Self {
        let local = previous
            .unwrap_or_else(Utc::now)
            .with_timezone(&location.location.zone);
        Self {
            source: location.location,
            fields: [
                local.format("%Y-%m-%d").to_string(),
                previous.map_or_else(String::new, |_| {
                    local.format(format.with_seconds()).to_string()
                }),
            ],
            active: 1,
            error: None,
            repeated: None,
        }
    }

    pub fn input(&mut self, key: KeyEvent) -> Option<Meeting> {
        if let Some(choices) = self.repeated {
            match key.code {
                KeyCode::Char('1') => return Some(self.meeting(choices[0])),
                KeyCode::Char('2') => return Some(self.meeting(choices[1])),
                KeyCode::Backspace => self.repeated = None,
                _ => {}
            }
            return None;
        }

        self.error = None;
        match key.code {
            KeyCode::Tab | KeyCode::BackTab | KeyCode::Up | KeyCode::Down => {
                self.active = 1 - self.active;
            }
            KeyCode::Enter => match resolve(self.source.zone, &self.fields[0], &self.fields[1]) {
                Ok(LocalResult::Single(time)) => return Some(self.meeting(time)),
                Ok(LocalResult::Ambiguous(first, second)) => self.repeated = Some([first, second]),
                Ok(LocalResult::None) => self.error = Some("Skipped local time. Try another."),
                Err(error) => self.error = Some(error),
            },
            _ => {
                edit_field(&mut self.fields[self.active], key);
            }
        }
        None
    }

    fn meeting(&self, time: DateTime<Tz>) -> Meeting {
        Meeting {
            instant: time.to_utc(),
            source: self.source.clone(),
            offset: 0,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let popup = centered(area, 52, 10);
        frame.render_widget(Clear, popup);
        let mut lines = vec![Line::styled(
            format!(" {} · {}", self.source.name, self.source.zone),
            Style::new().fg(TEXT),
        )];
        if let Some([first, second]) = self.repeated {
            lines.push(Line::from(" This local time occurs twice."));
            for (label, time) in [("1 Earlier", first), ("2 Later", second)] {
                lines.push(Line::styled(
                    format!(" {label} · UTC{}", time.format("%:z")),
                    Style::new().fg(ACCENT),
                ));
            }
            lines.push(Line::from(" Backspace Edit  Esc Back"));
        } else {
            for (index, (label, value)) in ["Date", "Time"].iter().zip(&self.fields).enumerate() {
                let active = index == self.active;
                lines.push(Line::styled(
                    format!(
                        "{} {label}  {value}{}",
                        if active { "›" } else { " " },
                        if active { "▏" } else { "" },
                    ),
                    Style::new().fg(if active { ACCENT } else { TEXT }),
                ));
            }
            lines.push(Line::styled(
                " YYYY-MM-DD · 14:30 or 2:30 PM",
                Style::new().fg(MUTED),
            ));
            lines.push(Line::styled(
                " Tab Field  Enter Convert",
                Style::new().fg(MUTED),
            ));
            lines.push(Line::styled(
                " Ctrl+U Clear  Esc Back",
                Style::new().fg(MUTED),
            ));
            if let Some(error) = self.error {
                lines.push(Line::styled(
                    format!(" {error}"),
                    Style::new().fg(FEEDBACK).add_modifier(Modifier::BOLD),
                ));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).block(panel(" Meeting time ", true)),
            popup,
        );
    }
}

pub(crate) fn resolve(
    zone: Tz,
    date: &str,
    time: &str,
) -> Result<LocalResult<DateTime<Tz>>, &'static str> {
    let date =
        NaiveDate::parse_from_str(date.trim(), "%Y-%m-%d").map_err(|_| "Use date YYYY-MM-DD.")?;
    if !(1..=9999).contains(&date.year()) {
        return Err("Use a year from 0001 to 9999.");
    }
    let time = time.trim().to_ascii_uppercase();
    let time = ["%H:%M", "%I:%M %p", "%H:%M:%S", "%I:%M:%S %p"]
        .into_iter()
        .find_map(|format| NaiveTime::parse_from_str(&time, format).ok())
        .filter(|time| time.nanosecond() == 0)
        .ok_or("Use 14:30 or 2:30 PM.")?;
    Ok(zone.from_local_datetime(&date.and_time(time)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono_tz::{America::New_York, Asia::Tokyo};

    #[test]
    fn conversion_preserves_the_instant_across_midnight() {
        let time = resolve(New_York, "2026-11-22", "6:30 pm")
            .unwrap()
            .single()
            .unwrap();
        assert_eq!(
            time.with_timezone(&Tokyo)
                .format("%Y-%m-%d %H:%M")
                .to_string(),
            "2026-11-23 08:30"
        );
        assert_eq!(
            resolve(New_York, "2026-11-22", "18:30").unwrap().single(),
            Some(time)
        );
    }

    #[test]
    fn daylight_saving_gaps_and_repeats_require_resolution() {
        assert!(matches!(
            resolve(New_York, "2026-03-08", "02:30"),
            Ok(LocalResult::None)
        ));
        let Ok(LocalResult::Ambiguous(earlier, later)) = resolve(New_York, "2026-11-01", "01:30")
        else {
            panic!("expected a repeated local time");
        };
        assert_eq!((later - earlier).num_hours(), 1);
    }
}

const ROW_HEIGHT: u16 = 3;
const HOUR_WIDTH: u16 = 5;

impl Meeting {
    pub fn draw(&mut self, frame: &mut Frame, area: Rect, config: &Config, now: DateTime<Utc>) {
        let format = config.clock_format;
        let header = Line::from(vec![
            Span::styled(
                " MEETING ",
                Style::new().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(" {} UTC", self.instant.format(format.with_seconds())),
                Style::new().fg(MUTED),
            ),
        ]);
        frame.render_widget(header, Rect::new(0, 0, area.width, 1));
        frame.render_widget(
            Line::styled(
                format!(" {}", countdown(self.instant - now)),
                Style::new().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Rect::new(0, 1, area.width, 1),
        );

        let locations: Vec<_> = std::iter::once(&self.source)
            .chain(
                config
                    .locations
                    .iter()
                    .filter(|loc| loc.name != self.source.name || loc.zone != self.source.zone),
            )
            .collect();
        let capacity = usize::from((area.height - 4) / ROW_HEIGHT);
        self.offset = self.offset.min(locations.len().saturating_sub(capacity));
        let info_width = if area.width < 46 { 17 } else { 27 };
        let hours_each_side = ((area.width - info_width) / HOUR_WIDTH - 1) / 2;
        let meeting_x = info_width + hours_each_side * HOUR_WIDTH;
        frame.render_widget(
            Line::styled("  ▼  ", Style::new().fg(ACCENT)),
            Rect::new(meeting_x, 2, HOUR_WIDTH, 1),
        );

        for (slot, (index, location)) in locations
            .iter()
            .enumerate()
            .skip(self.offset)
            .take(capacity)
            .enumerate()
        {
            let y = 3 + slot as u16 * ROW_HEIGHT;
            let local = self.instant.with_timezone(&location.zone);
            let name = if index == 0 {
                format!(" ◆ {}", location.name)
            } else {
                format!("   {}", location.name)
            };
            frame.render_widget(
                Paragraph::new(vec![
                    Line::styled(
                        name,
                        Style::new()
                            .fg(if index == 0 { ACCENT } else { TEXT })
                            .add_modifier(Modifier::BOLD),
                    ),
                    Line::styled(
                        format!(
                            "   {}  {}",
                            local.format(format.with_seconds()),
                            local.format("%:z")
                        ),
                        Style::new().fg(TEXT),
                    ),
                    Line::styled(
                        format!("   {}", local.format("%a %Y-%m-%d")),
                        Style::new().fg(MUTED),
                    ),
                ]),
                Rect::new(0, y, info_width, ROW_HEIGHT),
            );

            let hour_format = match format {
                ClockFormat::TwentyFourHour => "%H",
                ClockFormat::AmPm => "%-I%p",
            };
            let mut previous = (self.instant
                - chrono::Duration::hours(i64::from(hours_each_side) + 1))
            .with_timezone(&location.zone);
            for column in 0..=hours_each_side * 2 {
                let delta = i64::from(column) - i64::from(hours_each_side);
                let instant = self.instant + chrono::Duration::hours(delta);
                let time = instant.with_timezone(&location.zone);
                let x = info_width + column * HOUR_WIDTH;
                let style = if delta == 0 {
                    Style::new()
                        .fg(BACKGROUND)
                        .bg(ACCENT)
                        .add_modifier(Modifier::BOLD)
                } else {
                    match solar::phase(instant, location.latitude, location.longitude) {
                        solar::Phase::Daylight => Style::new().fg(SUN).bg(SELECTION),
                        solar::Phase::Dawn | solar::Phase::Dusk => {
                            Style::new().fg(DAWN).bg(SELECTION)
                        }
                        solar::Phase::Night => Style::new().fg(TEXT).bg(BORDER),
                    }
                };
                if time.date_naive() != previous.date_naive() {
                    frame.render_widget(
                        Line::styled(time.format("%d%b").to_string(), Style::new().fg(MUTED)),
                        Rect::new(x, y, HOUR_WIDTH, 1),
                    );
                }
                frame.render_widget(
                    Line::styled(
                        format!("{:^5}", time.format(hour_format).to_string()),
                        style,
                    ),
                    Rect::new(x, y + 1, HOUR_WIDTH, 1),
                );
                if delta == 0 {
                    frame.render_widget(
                        Line::styled("  │  ", Style::new().fg(ACCENT)),
                        Rect::new(x, y + 2, HOUR_WIDTH, 1),
                    );
                }
                previous = time;
            }
        }

        let footer = if area.width >= 64 {
            format!(
                " ↑↓ Scroll   m Edit   t Format   Esc Live   q Quit  {}/{}",
                self.offset + 1,
                locations.len()
            )
        } else {
            " ↑↓ m Edit t Format Esc Live q".into()
        };
        frame.render_widget(
            Line::styled(footer, Style::new().fg(MUTED)),
            Rect::new(0, area.height - 1, area.width, 1),
        );
    }
}

fn countdown(delta: chrono::Duration) -> String {
    let seconds = delta.num_seconds();
    if seconds == 0 {
        return "Starting now".into();
    }
    let seconds_left = seconds.unsigned_abs();
    let duration = if seconds_left < 60 {
        "<1m".to_string()
    } else {
        let minutes = if seconds > 0 {
            seconds_left.div_ceil(60)
        } else {
            seconds_left / 60
        };
        if minutes >= 60 {
            format!("{}h {:02}m", minutes / 60, minutes % 60)
        } else {
            format!("{minutes}m")
        }
    };
    if seconds > 0 {
        format!("Starts in {duration}")
    } else {
        format!("Started {duration} ago")
    }
}
