use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use std::{
    error::Error,
    fs, io,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Clone, Serialize, Deserialize)]
pub struct Location {
    pub name: String,
    pub zone: Tz,
    pub latitude: f64,
    pub longitude: f64,
}

impl Location {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.name.trim().is_empty() || self.name.chars().any(char::is_control) {
            return Err("Enter a location name.");
        }
        if !(-90.0..=90.0).contains(&self.latitude) {
            return Err("Latitude must be between −90 and 90.");
        }
        if !(-180.0..=180.0).contains(&self.longitude) {
            return Err("Longitude must be between −180 and 180.");
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Layout {
    #[default]
    Grid,
    List,
}

#[derive(Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClockFormat {
    #[default]
    TwentyFourHour,
    AmPm,
}

impl ClockFormat {
    pub fn with_seconds(self) -> &'static str {
        match self {
            Self::TwentyFourHour => "%H:%M:%S",
            Self::AmPm => "%-I:%M:%S %p",
        }
    }

    pub fn minutes(self) -> &'static str {
        match self {
            Self::TwentyFourHour => "%H:%M",
            Self::AmPm => "%-I:%M %p",
        }
    }
}

#[derive(Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WeatherIcons {
    #[default]
    Pixel,
    Emoji,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub layout: Layout,
    #[serde(default)]
    pub clock_format: ClockFormat,
    #[serde(default)]
    pub weather_icons: WeatherIcons,
    pub locations: Vec<Location>,
}

impl Config {
    pub fn path() -> io::Result<PathBuf> {
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
            .ok_or_else(|| io::Error::other("Set HOME or XDG_CONFIG_HOME"))?;
        Ok(base.join("worldclock").join("config.toml"))
    }

    pub fn load(path: &Path) -> Result<Self, Box<dyn Error>> {
        match fs::read_to_string(path) {
            Ok(contents) => {
                let config: Self = toml::from_str(&contents)?;
                for location in &config.locations {
                    location
                        .validate()
                        .map_err(|error| format!("{}: {error}", location.name))?;
                }
                Ok(config)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(error.into()),
        }
    }

    pub fn save(&self, path: &Path) -> Result<(), Box<dyn Error>> {
        let directory = path.parent().unwrap();
        fs::create_dir_all(directory)?;
        let mut file = tempfile::NamedTempFile::new_in(directory)?;
        file.write_all(toml::to_string_pretty(self)?.as_bytes())?;
        file.as_file().sync_all()?;
        file.persist(path)?;
        Ok(())
    }
}

impl Default for Config {
    fn default() -> Self {
        use chrono_tz::{America, Asia, Europe};
        Self {
            layout: Layout::default(),
            clock_format: ClockFormat::default(),
            weather_icons: WeatherIcons::default(),
            locations: [
                ("Phnom Penh", Asia::Phnom_Penh, 11.5564, 104.9282),
                ("London", Europe::London, 51.5072, -0.1276),
                ("New York", America::New_York, 40.7128, -74.006),
                ("Tokyo", Asia::Tokyo, 35.6762, 139.6503),
            ]
            .into_iter()
            .map(|(name, zone, latitude, longitude)| Location {
                name: name.into(),
                zone,
                latitude,
                longitude,
            })
            .collect(),
        }
    }
}
