# WorldClock

A full-screen terminal dashboard for local times and daylight. Each location shows
its local date and time, the current solar phase, daylight duration, and today's
sunrise and sunset. The green portion of the timeline marks daylight, and the
diamond marks the current time. Solar times are approximations for an unobstructed
horizon.

## Run

From this directory, run the compiled binary:

```sh
./target/release/worldclock
```

To build from source with Rust and Cargo installed:

```sh
cargo build --release --locked
```

## macOS desktop app

Open `target/desktop/WorldClock.app` on macOS 14 or later. To build it yourself,
run `./desktop/build.sh` with Rust, Cargo, and Xcode installed.

The desktop app uses the same configuration file as `wclock` and picks up saved
terminal changes while the window is open. Drag a city card onto another card to
move it to that position and save the order. Use the arrow keys to select or move cities, A to add, E to edit,
D to remove, R to reorder, M for meetings, G for grid or list, T for the clock
format, S to show or hide seconds, and Q to quit. Desktop cards use weather symbols and a sun path that shows progress from sunrise to sunset. In the Add dialog, Ctrl+N opens
manual entry. Use Tab to move through form fields and Esc to go back.

### macOS widget

Launch WorldClock once, then right-click the desktop and choose **Edit
Widgets**. Search for **WorldClock** and choose a size. Small shows the first
saved city, Medium shows up to three, and Large shows up to six. Cities appear
in saved order, with day offsets relative to the first city. The widgets use
the app's 12/24-hour setting and show temperature in Celsius when available.
macOS controls when widgets redraw.

Local builds share a settings snapshot in your Application Support folder.
The widget has read-only access to that single file. For an App Group build,
set `WORLDCLOCK_SIGNING_IDENTITY` to your signing identity and
`WORLDCLOCK_APP_GROUP` to your team-prefixed group identifier.

## Controls

| Key | Action |
| --- | --- |
| ↑ / ↓ or k / j | Select a location |
| Home / End | Select the first or last location |
| a | Add a location |
| e or Enter | Edit the selected location |
| d or Delete | Remove the selected location after confirmation |
| r | Reorder saved locations |
| g | Switch between grid and single-column list |
| t | Switch between 24-hour time and AM/PM |
| w | Switch between pixel art and weather emoji |
| m | Choose a location and enter a meeting time |
| Esc | Return to live clocks or quit from the live dashboard |
| q | Quit |

Press `a` and start typing a city name to see suggestions. Use ↑ and ↓ to select a
result, then press Enter to fill in its name, time zone, and coordinates. Press
Enter again to save. Use Tab and Shift+Tab to move between fields, Ctrl+U to clear
a field, and Esc to cancel.

## Meeting times

Press `m` to open the meeting location picker. Use ↑ and ↓ to choose a saved
location, or type a city name to search the offline catalog. Press Enter to
continue to the time form, or Esc to return to the previous step.

For a new meeting the date starts at today in the chosen location. Type a time
such as `14:30` or `2:30 PM` and press Enter. Use Tab to change the date and
Ctrl+U to clear a field.

Results open in a separate timeline view with the meeting location first. The
highlighted column lines up the meeting across time zones, and each row shows
its exact local date and time. Date labels mark midnight crossings, and timeline
colors distinguish daylight, twilight, and night. The live countdown shows how
long until the meeting or how long ago it started. Use ↑ and ↓ to scroll.

If a daylight saving transition repeats the entered time, choose the earlier or
later UTC offset. If the transition skips that time, enter another time.

Press `m` again to choose a location and revise the meeting, or Esc to
return to live clocks. Meeting times are kept for the current session.

## Locations

The first run includes Phnom Penh, London, New York, and Tokyo. To add a place
manually, enter its name, then press Tab to enter an IANA time zone such as
`Asia/Tokyo` and coordinates in signed decimal degrees. Use negative values for
south and west.

Select a location and press `r` to reorder. Use ↑ or ↓ to move it one position at
a time, following reading order in the grid. Press Enter to save or Esc to undo
the changes.

The grid uses two columns when the terminal has room. The clock format applies to
the clocks, sunrise, and sunset. Sunrise or sunset is shown as “—” when that event
does not occur on the local date.

Live cards show current temperature and conditions from
[Open-Meteo](https://open-meteo.com/en/docs). Weather uses `curl` in the background
to request conditions for the saved coordinates about every fifteen minutes.
In pixel mode, wide cards show pixel art and narrow cards use ASCII. Press `w`
to switch to weather emoji. The icon preference is saved.
If a refresh fails, the last available reading is marked stale. The clocks,
daylight calculations, city search, and meeting view work offline.

Locations and display preferences are saved to
`~/.config/worldclock/config.toml`, or to
`$XDG_CONFIG_HOME/worldclock/config.toml` when an absolute config directory is set.


## City data

The bundled city catalog is adapted from [GeoNames](https://www.geonames.org/)
[cities15000](https://download.geonames.org/export/dump/cities15000.zip) under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The catalog keeps city
names, ASCII spellings, region codes, time zones, and coordinates and orders
entries by population.
