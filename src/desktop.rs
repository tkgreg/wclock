use crate::{
    cities,
    config::{Config, Location},
    meeting,
    solar::{self, SolarDay},
};
use chrono::{DateTime, LocalResult, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use std::error::Error;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum Request {
    ConfigPath,
    Load,
    Save {
        config: Config,
    },
    Search {
        query: String,
    },
    Solar {
        locations: Vec<Location>,
        timestamp: i64,
    },
    Meeting {
        location: Location,
        date: String,
        time: String,
    },
}

pub fn run() -> Result<(), Box<dyn Error>> {
    let result = serde_json::from_reader(std::io::stdin().lock())
        .map_err(Into::into)
        .and_then(handle);
    let response =
        result.unwrap_or_else(|error: Box<dyn Error>| json!({ "error": error.to_string() }));
    serde_json::to_writer(std::io::stdout().lock(), &response)?;
    Ok(())
}

fn handle(request: Request) -> Result<Value, Box<dyn Error>> {
    Ok(match request {
        Request::ConfigPath => json!(Config::path()?),
        Request::Load => serde_json::to_value(Config::load(&Config::path()?)?)?,
        Request::Save { config } => {
            for location in &config.locations {
                location.validate()?;
            }
            config.save(&Config::path()?)?;
            json!({})
        }
        Request::Search { query } => {
            json!(cities::search(&query)
                .iter()
                .map(|city| {
                    json!({
                        "name": city.name, "zone": city.zone, "region": city.region,
                        "latitude": city.latitude.parse::<f64>().ok(),
                        "longitude": city.longitude.parse::<f64>().ok()
                    })
                })
                .collect::<Vec<_>>())
        }
        Request::Solar {
            locations,
            timestamp,
        } => {
            let now = DateTime::from_timestamp(timestamp, 0).ok_or("Invalid date")?;
            let days = locations.iter().map(|location| {
                let date = now.with_timezone(&location.zone).date_naive();
                let day = SolarDay::calculate(date, location.zone, location.latitude, location.longitude);
                json!({
                    "start": day.start.timestamp(),
                    "end": day.end.timestamp(),
                    "intervals": day.daylight.iter().map(|(from, to)| [from.timestamp(), to.timestamp()]).collect::<Vec<_>>(),
                    "phase": match solar::phase(now, location.latitude, location.longitude) {
                        solar::Phase::Dawn => "Dawn",
                        solar::Phase::Daylight => "Daylight",
                        solar::Phase::Dusk => "Dusk",
                        solar::Phase::Night => "Night",
                    },
                })
            }).collect::<Vec<_>>();
            json!(days)
        }
        Request::Meeting {
            location,
            date,
            time,
        } => {
            let options = match meeting::resolve(location.zone, &date, &time)? {
                LocalResult::Single(time) => vec![time],
                LocalResult::Ambiguous(first, second) => vec![first, second],
                LocalResult::None => {
                    return Err("That local time is skipped. Enter another time.".into())
                }
            };
            json!(options
                .iter()
                .map(|time| json!({
                    "timestamp": time.with_timezone(&Utc).timestamp(),
                    "offset": time.format("%:z").to_string()
                }))
                .collect::<Vec<_>>())
        }
    })
}
