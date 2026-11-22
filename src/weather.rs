use crate::config::{Location, WeatherIcons};
use serde::Deserialize;
use std::{
    collections::HashMap,
    process::Command,
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
    time::{Duration, Instant},
};

const REFRESH: Duration = Duration::from_secs(15 * 60);
const RETRY: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
struct Coordinates(u64, u64);

impl From<&Location> for Coordinates {
    fn from(location: &Location) -> Self {
        Self(location.latitude.to_bits(), location.longitude.to_bits())
    }
}

#[derive(Clone, Copy, Deserialize)]
pub struct Reading {
    temperature_2m: f64,
    weather_code: u8,
    is_day: u8,
}

#[derive(Deserialize)]
struct Forecast {
    current: Option<Reading>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ForecastResponse {
    One(Forecast),
    Many(Vec<Forecast>),
}

type Update = Vec<(Coordinates, Option<Reading>)>;

#[derive(Default)]
pub struct Weather {
    readings: HashMap<Coordinates, (Reading, bool)>,
    requested: Vec<Coordinates>,
    pending: Option<Receiver<Update>>,
    next_refresh: Option<Instant>,
}

impl Weather {
    pub fn refresh(&mut self, locations: &[Location]) {
        let mut cities: Vec<_> = locations.iter().map(Coordinates::from).collect();
        cities.sort_unstable();
        cities.dedup();
        self.readings
            .retain(|key, _| cities.binary_search(key).is_ok());

        if let Some(receiver) = &self.pending {
            let update = match receiver.try_recv() {
                Ok(update) => update,
                Err(TryRecvError::Empty) => return,
                Err(TryRecvError::Disconnected) => {
                    self.requested.iter().map(|&key| (key, None)).collect()
                }
            };
            let mut retry = false;
            for (key, reading) in update {
                if cities.binary_search(&key).is_err() {
                    continue;
                }
                if let Some(reading) = reading {
                    self.readings.insert(key, (reading, false));
                } else {
                    retry = true;
                    if let Some((_, stale)) = self.readings.get_mut(&key) {
                        *stale = true;
                    }
                }
            }
            self.pending = None;
            self.next_refresh = Some(Instant::now() + if retry { RETRY } else { REFRESH });
        }

        if cities.is_empty() {
            self.requested.clear();
            self.next_refresh = None;
            return;
        }
        if cities == self.requested && self.next_refresh.is_some_and(|next| Instant::now() < next) {
            return;
        }
        self.requested = cities.clone();
        let (sender, receiver) = mpsc::channel();
        self.pending = Some(receiver);
        thread::spawn(move || {
            let update = cities.chunks(25).flat_map(fetch).collect();
            let _ = sender.send(update);
        });
    }

    pub fn for_location(&self, location: &Location, icons: WeatherIcons) -> Display {
        match self.readings.get(&Coordinates::from(location)) {
            Some(&(reading, stale)) => {
                let mut display = reading.display(stale);
                if let WeatherIcons::Emoji = icons {
                    display.icon = reading.emoji();
                    display.sprite = ["", "", ""];
                }
                display
            }
            None => Display {
                label: if self.pending.is_some() {
                    "Weather loading…".into()
                } else {
                    "Weather unavailable".into()
                },
                icon: "",
                sprite: ["", "", ""],
            },
        }
    }
}

fn fetch(cities: &[Coordinates]) -> Update {
    let coordinate_list = |latitude: bool| {
        cities
            .iter()
            .map(|city| f64::from_bits(if latitude { city.0 } else { city.1 }).to_string())
            .collect::<Vec<_>>()
            .join(",")
    };
    let url = format!(
        "https://api.open-meteo.com/v1/forecast?latitude={}&longitude={}&current=temperature_2m,weather_code,is_day",
        coordinate_list(true),
        coordinate_list(false),
    );
    let readings = Command::new("curl")
        .args(["-q", "--fail", "--silent", "--max-time", "8", &url])
        .output()
        .ok()
        .filter(|response| response.status.success())
        .and_then(|response| serde_json::from_slice::<ForecastResponse>(&response.stdout).ok())
        .map(|response| match response {
            ForecastResponse::One(forecast) => vec![forecast],
            ForecastResponse::Many(forecasts) => forecasts,
        })
        .filter(|forecasts| forecasts.len() == cities.len())
        .unwrap_or_default();
    cities
        .iter()
        .enumerate()
        .map(|(index, &key)| {
            (
                key,
                readings.get(index).and_then(|forecast| forecast.current),
            )
        })
        .collect()
}

pub struct Display {
    pub label: String,
    pub icon: &'static str,
    pub sprite: [&'static str; 3],
}

impl Reading {
    fn emoji(self) -> &'static str {
        match self.weather_code {
            0 | 1 if self.is_day == 0 => "🌙",
            0 => "☀️",
            1 | 2 => "🌤️",
            3 => "☁️",
            45 | 48 => "🌫️",
            51..=67 | 80..=82 => "🌧️",
            71..=77 | 85..=86 => "❄️",
            95..=99 => "⛈️",
            _ => "❔",
        }
    }

    fn display(self, stale: bool) -> Display {
        let (condition, icon, sprite) = match self.weather_code {
            0 if self.is_day == 0 => ("Clear", " ) ", ["  ▟▀ ", " ▐▌  ", "  ▀▀ "]),
            0 => ("Sunny", "\\|/", [" ▖▗▖ ", "▐███▌", " ▘▝▘ "]),
            1 => ("Mostly clear", "\\|/", [" ▖▗▖ ", "▐███▌", " ▘▝▘ "]),
            2..=3 => ("Cloudy", "(o)", ["  ▄▄ ", "▄████", " ▀▀▀ "]),
            45 | 48 => ("Fog", "===", [" ▄▄▄ ", "▄▄▄▄▄", " ▀▀▀ "]),
            51..=67 | 80..=82 => ("Rain", "///", [" ▄▄▄ ", "▀▀▀▀▀", " ▘▘▘ "]),
            71..=77 | 85..=86 => ("Snow", "* *", [" ▄▄▄ ", "▀▀▀▀▀", " ▖▗▖ "]),
            95..=99 => ("Storm", "/!/", [" ▄▄▄ ", "▀▀█▀▀", " ▟▘  "]),
            _ => ("Unknown", " ? ", [" ▄▄  ", "   ▘ ", "  ▘  "]),
        };
        let age = if stale { " (stale)" } else { "" };
        Display {
            label: format!("{:.0}°C {condition}{age}", self.temperature_2m),
            icon,
            sprite,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_current_conditions_and_labels_stale_data() {
        let ForecastResponse::One(forecast) = serde_json::from_str(
            r#"{"current":{"temperature_2m":29.3,"weather_code":0,"is_day":1}}"#,
        )
        .unwrap() else {
            panic!("expected one forecast")
        };
        let reading = forecast.current.unwrap();
        assert_eq!(reading.display(false).label, "29°C Sunny");
        assert_eq!(reading.display(true).label, "29°C Sunny (stale)");
        assert_eq!(reading.display(false).sprite.len(), 3);
    }
}
