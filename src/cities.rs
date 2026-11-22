use chrono_tz::Tz;
use std::sync::LazyLock;

const LIMIT: usize = 5;

#[derive(Clone, Copy)]
pub struct City {
    pub name: &'static str,
    pub region: &'static str,
    pub zone: &'static str,
    pub latitude: &'static str,
    pub longitude: &'static str,
}

struct SearchEntry {
    city: City,
    name: String,
    ascii_name: String,
}

static CITIES: LazyLock<Vec<SearchEntry>> = LazyLock::new(|| {
    include_str!("../data/cities.tsv")
        .lines()
        .filter_map(|line| {
            let [name, ascii_name, region, zone, latitude, longitude] =
                line.split('\t').collect::<Vec<_>>().try_into().ok()?;
            zone.parse::<Tz>().ok()?;
            Some(SearchEntry {
                city: City {
                    name,
                    region,
                    zone,
                    latitude,
                    longitude,
                },
                name: name.to_lowercase(),
                ascii_name: ascii_name.to_lowercase(),
            })
        })
        .collect()
});

pub fn search(query: &str) -> Vec<City> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }

    // The catalog is ordered by population, so ties favor larger cities.
    let mut ranked: [Vec<City>; 3] = Default::default();
    for entry in CITIES.iter() {
        let names = [&entry.name, &entry.ascii_name];
        let rank = if names.iter().any(|name| **name == query) {
            0
        } else if names.iter().any(|name| name.starts_with(&query)) {
            1
        } else if names.iter().any(|name| name.contains(&query)) {
            2
        } else {
            continue;
        };
        if ranked[rank].len() < LIMIT {
            ranked[rank].push(entry.city);
        }
        if ranked[0].len() == LIMIT {
            break;
        }
    }
    ranked.into_iter().flatten().take(LIMIT).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_prefers_exact_names_and_accepts_ascii_queries() {
        let paris = search(" pArIs ");
        assert_eq!(paris[0].name, "Paris");
        assert_eq!(paris[0].zone, "Europe/Paris");
        assert!(paris.len() <= LIMIT);
        assert_eq!(search("Sao Paulo")[0].zone, "America/Sao_Paulo");
        assert!(search(" ").is_empty());
    }
}
