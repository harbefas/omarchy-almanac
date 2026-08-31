# Almanac

Almanac is a native Omarchy plugin for reading and managing a `khal` calendar.
It provides a bar widget with a month popup and a full overlay panel with
keyboard navigation, event creation and editing, calendar filters, and `.ics`
feed management.

## Requirements

- Omarchy with Quickshell plugin support
- `khal`, `jq`, `python3` with `icalendar` (a `khal` dependency)
- `vdirsyncer`, for feeds

Calendars come from `~/.config/khal/config`. Almanac never invents its own
store: whatever `khal` already reads is what shows up.

## Installation

```bash
omarchy plugin add https://github.com/harbefas/omarchy-almanac.git
omarchy bar put harbefas.almanac --section center
```

Installing with `--enable` breaks `bar put`, so the two steps stay separate.

The plugin can also be installed from a local checkout:

```bash
omarchy plugin add /path/to/omarchy-almanac
```

To open the full panel from anywhere, add this optional binding to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + C", "Almanac", "omarchy shell -q harbefas.almanac.manager toggle")
```

Then reload the shell:

```bash
omarchy restart shell
```

## Usage

### Bar popup

The widget shows the date. Clicking it opens the month.

| Key | Action |
| --- | --- |
| `h` `l` | Previous / next day |
| `j` `k` | Previous / next week |
| `[` `]` | Previous / next month |
| `{` `}` | Previous / next year |
| `Enter` | Step into the day's events, where `j` `k` walk them |
| `Esc` | Back to the grid, then close |
| `t` | Today |
| `w` | Toggle the first day of the week |
| `p` | Open the full panel on the selected day |

### Full panel

| Key | Action |
| --- | --- |
| `h` `l` | Previous / next day |
| `j` `k` | Previous / next week, or previous / next event in the list |
| `[` `]` | Previous / next month |
| `t` | Today |
| `Tab` | Move between the grid and the day's events |
| `n` | New event |
| `e` | Edit the selected event |
| `d` | Delete the selected event, after a confirmation |
| `/` | Search the loaded range |
| `a` `c` `f` | Agenda, Calendars, Feeds |
| `?` | Show the shortcut overlay |
| `Esc` | Close |

On the Calendars page, `Space` hides a calendar from the agenda. It keeps
syncing; this is a view filter, not a subscription change.

On the Feeds page, `n` adds a feed, `s` syncs the selected one, `Shift+S`
syncs every feed, and `d` removes one.

## How it talks to khal

Everything goes through the scripts in `bin/`, so the whole data layer can be
exercised from a terminal without opening the panel:

| Script | Purpose |
| --- | --- |
| `khal-calendars` | Calendars with their `readonly` flag, which `khal printcalendars` does not report |
| `khal-events` | Events for a date range, as JSON |
| `khal-event-new` | Create an event, refusing readonly calendars |
| `khal-event-edit` | Edit or delete an event by UID |
| `khal-feeds` | List, add, remove and sync `.ics` feeds |

Creation goes through `khal new`. Editing and deletion do not: `khal edit` is
interactive-only, with no flag for either, so they act on the `.ics` file
directly — filesystem calendars keep one file per event, and `khal` reindexes
from mtime. The file is located by reading UIDs rather than trusting the
filename.

Adding a feed writes both configs, the `vdirsyncer` pair and the `khal`
calendar, because either one alone leaves `khal` pointing at a directory
nothing syncs. Both are edited as text so their comments survive.

Removing a feed unregisters it from both configs but leaves the events it
already downloaded on disk. `path` in those configs is yours to set and can
point anywhere, so removal does not recurse into it; the result says where the
leftovers are.

## Filtering noisy feeds

Some feeds are far too busy to read: a league feed can be fifteen events a
day. `~/.config/omarchy/khal-filters.json` keeps only the events whose title
matches, per calendar:

```json
{ "sports_mlb": "STL" }
```

## Tests

```bash
./test/run
```

`Khal.js` is deliberately Qt-free so the parsing, sanitising and grouping
rules can be checked under `node` rather than by opening the panel and
looking.

## License

MIT

## Previews

![Full panel](preview.png)

![Bar popup](preview-popup.png)
