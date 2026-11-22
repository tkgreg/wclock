use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;

const HORIZON: f64 = -0.833;
const CIVIL_TWILIGHT: f64 = -6.0;

pub struct SolarDay {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub daylight: Vec<(DateTime<Utc>, DateTime<Utc>)>,
}

impl SolarDay {
    pub fn calculate(date: NaiveDate, zone: Tz, latitude: f64, longitude: f64) -> Self {
        let start = day_start(date, zone);
        let end = day_start(date.succ_opt().unwrap(), zone);
        let above = |time| elevation(time, latitude, longitude) >= HORIZON;
        let mut daylight = Vec::new();
        let mut previous = start;
        let mut was_above = above(start);
        let mut opened = was_above.then_some(start);

        while previous < end {
            let next = (previous + Duration::minutes(1)).min(end);
            let is_above = above(next);

            if is_above != was_above {
                let mut low = previous;
                let mut high = next;
                while (high - low).num_seconds() > 1 {
                    let middle = low + (high - low) / 2;
                    if above(middle) == was_above {
                        low = middle;
                    } else {
                        high = middle;
                    }
                }

                if is_above {
                    opened = Some(high);
                } else if let Some(sunrise) = opened.take() {
                    daylight.push((sunrise, high));
                }
            }

            previous = next;
            was_above = is_above;
        }

        if let Some(sunrise) = opened.filter(|sunrise| *sunrise < end) {
            daylight.push((sunrise, end));
        }

        Self {
            start,
            end,
            daylight,
        }
    }

    pub fn duration(&self) -> Duration {
        self.daylight.iter().map(|(start, end)| *end - *start).sum()
    }
}

fn day_start(date: NaiveDate, zone: Tz) -> DateTime<Utc> {
    let mut local = date.and_hms_opt(0, 0, 0).unwrap();
    loop {
        if let Some(time) = zone.from_local_datetime(&local).earliest() {
            return time.to_utc();
        }
        local += Duration::minutes(1);
    }
}

#[derive(Clone, Copy)]
pub enum Phase {
    Dawn,
    Daylight,
    Dusk,
    Night,
}

pub fn phase(now: DateTime<Utc>, latitude: f64, longitude: f64) -> Phase {
    let current = elevation(now, latitude, longitude);
    if current >= HORIZON {
        Phase::Daylight
    } else if current < CIVIL_TWILIGHT {
        Phase::Night
    } else if elevation(now + Duration::seconds(30), latitude, longitude)
        > elevation(now - Duration::seconds(30), latitude, longitude)
    {
        Phase::Dawn
    } else {
        Phase::Dusk
    }
}

fn elevation(time: DateTime<Utc>, latitude: f64, longitude: f64) -> f64 {
    // Approximate solar coordinates from days since J2000.0.
    let days = time.timestamp() as f64 / 86_400.0 - 10_957.5;
    let mean_longitude = 280.460 + 0.9856474 * days;
    let anomaly = (357.528 + 0.9856003 * days).to_radians();
    let ecliptic_longitude =
        (mean_longitude + 1.915 * anomaly.sin() + 0.020 * (2.0 * anomaly).sin()).to_radians();
    let obliquity = (23.439 - 0.0000004 * days).to_radians();
    let right_ascension =
        (obliquity.cos() * ecliptic_longitude.sin()).atan2(ecliptic_longitude.cos());
    let declination = (obliquity.sin() * ecliptic_longitude.sin()).asin();
    let sidereal = (280.46061837 + 360.98564736629 * days + longitude)
        .rem_euclid(360.0)
        .to_radians();
    let latitude = latitude.to_radians();
    (latitude.sin() * declination.sin()
        + latitude.cos() * declination.cos() * (sidereal - right_ascension).cos())
    .clamp(-1.0, 1.0)
    .asin()
    .to_degrees()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn polar_day_and_night() {
        let zone = chrono_tz::Europe::Oslo;
        for (month, expected_hours) in [(6, 24), (12, 0)] {
            let date = NaiveDate::from_ymd_opt(2026, month, 21).unwrap();
            assert_eq!(
                SolarDay::calculate(date, zone, 69.65, 18.95)
                    .duration()
                    .num_hours(),
                expected_hours
            );
        }
    }

    #[test]
    fn daylight_and_dst_follow_the_local_day() {
        let date = NaiveDate::from_ymd_opt(2026, 3, 8).unwrap();
        let day = SolarDay::calculate(date, chrono_tz::America::New_York, 40.7128, -74.006);
        assert_eq!((day.end - day.start).num_hours(), 23);
        assert_eq!(day.daylight.len(), 1);
        assert!((690..720).contains(&day.duration().num_minutes()));
    }
}
