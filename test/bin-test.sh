#!/usr/bin/env bash
# Exercises the bin/ helpers against fixtures, with khal replaced by a stub.
# The stub is what makes the pipeline testable anywhere: khal-events has to
# flatten khal's per-day arrays, strip the feed advertising and carry the
# recurrence flag, and none of that needs a real calendar store to check.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"

check() {
  local name=$1 expected=$2 actual=$3
  [ "$expected" = "$actual" ] && return
  printf 'FAIL %s\n  expected %s\n  actual   %s\n' "$name" "$expected" "$actual" >&2
  failures=$((failures + 1))
}

# ---- khal-calendars

out=$(KHAL_CONFIG="$here/fixtures/khal-config" "$root/bin/khal-calendars")
check "calendars are listed in file order" '["personal","holidays"]' "$(jq -c 'map(.name)' <<<"$out")"
check "readonly is read from the config" '[false,true]' "$(jq -c 'map(.readonly)' <<<"$out")"
check "a leading tilde is expanded" "$HOME/.local/share/khal/calendars/personal/" \
  "$(jq -r '.[0].path' <<<"$out")"
check "sections that are not calendars are skipped" '2' "$(jq -c 'length' <<<"$out")"

KHAL_CONFIG="$work/missing" "$root/bin/khal-calendars" >/dev/null 2>&1
check "a missing config is an error, not an empty list" '66' "$?"

# ---- khal-events, against a stub khal

mkdir -p "$work/stub"
cat >"$work/stub/khal" <<'STUB'
#!/usr/bin/env bash
# khal prints one JSON array per day of the range, which is why the helper
# has to slurp. The promo trailer is what fixtur.es staples onto every event.
cat <<'JSON'
[{"start-date": "31/08/2026", "start-time": "13:30", "end-date": "31/08/2026", "end-time": "15:15", "title": "Lecce - AS Roma", "calendar": "sports_seriea", "uid": "a1", "location": "Via Del Mare", "description": "Calendar not up to date? Check https://fixtur.es/up-to-date?path=league/serie-a\n\nSupport Fixtur.es via Buy Me a Coffee https://buymeacoffee.com/fixtures", "repeat-symbol": ""}]
[{"start-date": "01/09/2026", "start-time": "", "end-date": "02/09/2026", "end-time": "", "title": "Standup", "calendar": "personal", "uid": "a2", "location": "", "description": "Every weekday", "repeat-symbol": "⟳"}, {"start-date": "01/09/2026", "start-time": "20:00", "end-date": "01/09/2026", "end-time": "22:00", "title": "STL @ LAD", "calendar": "sports_mlb", "uid": "a3", "location": "", "description": "", "repeat-symbol": ""}]
JSON
STUB
chmod +x "$work/stub/khal"
for cmd in jq bash env sed awk cat printf; do
  ln -sf "$(command -v "$cmd")" "$work/stub/$cmd"
done

echo '{}' >"$work/no-filters.json"
out=$(PATH="$work/stub" KHAL_FILTERS="$work/no-filters.json" \
  "$root/bin/khal-events" 2026-08-31 2026-09-01)

check "per-day arrays are flattened into one" '3' "$(jq -c 'length' <<<"$out")"
check "dates are turned around into ISO" '"2026-08-31"' "$(jq -c '.[0].date' <<<"$out")"
check "the promo trailer is cut" '""' "$(jq -c '.[0].description' <<<"$out")"
check "a real description survives" '"Every weekday"' \
  "$(jq -c 'map(select(.uid == "a2"))[0].description' <<<"$out")"
check "recurrence is carried" 'true' "$(jq -c 'map(select(.uid == "a2"))[0].repeats' <<<"$out")"
check "a one-off is not marked repeating" 'false' "$(jq -c '.[0].repeats' <<<"$out")"

echo '{"sports_mlb": "STL"}' >"$work/stl.json"
out=$(PATH="$work/stub" KHAL_FILTERS="$work/stl.json" \
  "$root/bin/khal-events" 2026-08-31 2026-09-01)
check "a filter keeps its matches" '3' "$(jq -c 'length' <<<"$out")"

echo '{"sports_mlb": "NOPE"}' >"$work/nope.json"
out=$(PATH="$work/stub" KHAL_FILTERS="$work/nope.json" \
  "$root/bin/khal-events" 2026-08-31 2026-09-01)
check "a filter drops what it does not match" '["a1","a2"]' "$(jq -c 'map(.uid)' <<<"$out")"

rm "$work/stub/khal"
PATH="$work/stub" "$root/bin/khal-events" 2026-08-31 2026-09-01 >/dev/null 2>&1
check "a missing khal is an error, not an empty day" '127' "$?"

# ---- khal-event-edit: moving between calendars is a file move
#
# No stub needed here: the helper reads the config and manipulates .ics files
# itself, because khal edit is interactive-only and has no flag for either.

mkdir -p "$work/cal/work" "$work/cal/archive" "$work/cal/locked"
cat >"$work/edit-config" <<CONFIG
[calendars]

[[work]]
path = $work/cal/work/
color = light green

[[archive]]
path = $work/cal/archive/
color = light blue

[[locked]]
path = $work/cal/locked/
color = dark red
readonly = True

[sqlite]
path = $work/khal.db
CONFIG

cat >"$work/cal/work/probe.ics" <<'ICS'
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:probe-1
SUMMARY:Original
DTSTART;VALUE=DATE:20260920
DTEND;VALUE=DATE:20260921
END:VEVENT
END:VCALENDAR
ICS

export KHAL_CONFIG="$work/edit-config"

"$root/bin/khal-event-edit" probe-1 --title Renamed >/dev/null
check "an edit rewrites the summary" '1' \
  "$(grep -c '^SUMMARY:Renamed' "$work/cal/work/probe.ics")"

"$root/bin/khal-event-edit" probe-1 --calendar archive >/dev/null
check "a move leaves the source calendar" '0' "$(find "$work/cal/work" -type f | wc -l)"
check "a move lands in the target calendar" '1' "$(find "$work/cal/archive" -type f | wc -l)"
check "a move keeps the uid" '1' \
  "$(grep -c '^UID:probe-1' "$work/cal/archive/probe.ics")"
check "no temp file is left behind" '0' \
  "$(find "$work/cal" -name '*.tmp' | wc -l)"

"$root/bin/khal-event-edit" probe-1 --calendar locked >/dev/null 2>&1
check "a readonly target is refused" '1' "$?"
check "the refused move changed nothing" '1' "$(find "$work/cal/archive" -type f | wc -l)"

"$root/bin/khal-event-edit" probe-1 --calendar nowhere >/dev/null 2>&1
check "an unknown target is refused" '1' "$?"

"$root/bin/khal-event-edit" probe-1 --delete >/dev/null
check "a delete removes the file" '0' "$(find "$work/cal/archive" -type f | wc -l)"

"$root/bin/khal-event-edit" probe-1 --delete >/dev/null 2>&1
check "a uid that is gone is refused" '1' "$?"

unset KHAL_CONFIG

# ---- khal-feeds

# The fixture points at $HOME by default, which made the timestamp checks
# read this machine's real vdirsyncer state. Redirect both into the sandbox.
sed "s|~/.local/share/vdirsyncer/status/|$work/status/|; \
     s|~/.local/share/khal/calendars/|$work/calendars/|" \
  "$here/fixtures/vdirsyncer-config" >"$work/vdirsyncer-config"
cp "$here/fixtures/khal-config" "$work/khal-config"
export KHAL_CONFIG="$work/khal-config" VDIRSYNCER_CONFIG="$work/vdirsyncer-config"

# The round-trip is checked against these, not the fixtures, since the paths
# above were rewritten into the sandbox.
cp "$work/vdirsyncer-config" "$work/vdirsyncer-config.pristine"
cp "$work/khal-config" "$work/khal-config.pristine"

out=$("$root/bin/khal-feeds" list)
check "http pairs are listed as feeds" '["holidays_pair"]' "$(jq -c 'map(.name)' <<<"$out")"
check "the local storage names the calendar" '"holidays"' "$(jq -c '.[0].calendar' <<<"$out")"
# Two different questions, so two different fields: whether the sync ran, and
# whether the publisher said anything. A dead feed syncs happily forever.
# Two different questions, so two different fields: whether the sync ran, and
# whether the publisher said anything. A dead feed syncs happily forever.
check "a pair that never synced reports zero" '0' "$(jq -c '.[0].synced' <<<"$out")"
check "a calendar with no directory reports zero" '0' "$(jq -c '.[0].changed' <<<"$out")"

mkdir -p "$work/status" "$work/calendars/holidays"
touch -d "2026-08-31 07:48" "$work/status/holidays_pair.items"
touch -d "2026-06-19 03:00" "$work/calendars/holidays"
out=$("$root/bin/khal-feeds" list)
check "synced is the pair status file" "$(date -d '2026-08-31 07:48' +%s)" \
  "$(jq -c '.[0].synced' <<<"$out")"
check "changed is the calendar directory" "$(date -d '2026-06-19 03:00' +%s)" \
  "$(jq -c '.[0].changed' <<<"$out")"

"$root/bin/khal-feeds" add sports_f1 "https://example.com/f1.ics" >/dev/null
check "adding a feed registers it" '2' "$("$root/bin/khal-feeds" list | jq -c 'length')"
check "the khal calendar is written too" '1' \
  "$(grep -c '^\[\[sports_f1\]\]' "$work/khal-config")"

"$root/bin/khal-feeds" add sports_f1 "https://example.com/f1.ics" >/dev/null 2>&1
check "a duplicate feed is refused" '1' "$?"

"$root/bin/khal-feeds" add ../escape "https://example.com/f1.ics" >/dev/null 2>&1
check "a feed name cannot escape the calendar directory" '1' "$?"

"$root/bin/khal-feeds" add bad_url "webcal://example.com/f1.ics" >/dev/null 2>&1
check "a feed URL must be http or https" '1' "$?"

"$root/bin/khal-feeds" add bad_space "https://example.com/f1 calendar.ics" >/dev/null 2>&1
check "a feed URL cannot contain raw spaces" '1' "$?"

"$root/bin/khal-feeds" add bad_config $'https://example.com/f1.ics"\n[[evil]]' >/dev/null 2>&1
check "a feed URL cannot inject config lines" '1' "$?"

"$root/bin/khal-feeds" add bad_color "https://example.com/f1.ics" \
  --color $'red\n[[evil]]' >/dev/null 2>&1
check "a feed color cannot inject config lines" '1' "$?"

"$root/bin/khal-feeds" remove sports_f1 >/dev/null
check "removing restores the vdirsyncer config byte for byte" '' \
  "$(diff "$work/vdirsyncer-config.pristine" "$work/vdirsyncer-config")"
check "removing restores the khal config byte for byte" '' \
  "$(diff "$work/khal-config.pristine" "$work/khal-config")"

VDIRSYNCER_CONFIG="$work/missing-vdirsyncer" \
  "$root/bin/khal-feeds" add missing_vdir "https://example.com/f1.ics" >/dev/null 2>&1
check "adding a feed needs an existing vdirsyncer config" '1' "$?"
check "a missing vdirsyncer config is not created" 'missing' \
  "$([ -e "$work/missing-vdirsyncer" ] && echo created || echo missing)"

KHAL_CONFIG="$work/missing-khal" \
  "$root/bin/khal-feeds" add missing_khal "https://example.com/f1.ics" >/dev/null 2>&1
check "adding a feed needs an existing khal config" '1' "$?"
check "a missing khal config leaves vdirsyncer untouched" '' \
  "$(diff "$work/vdirsyncer-config.pristine" "$work/vdirsyncer-config")"

# khal-feeds add always creates the directory under the real XDG data dir,
# so this one is the test's to clean up. Removing a feed deliberately leaves
# a directory behind, which is why it is still here.
rmdir "$HOME/.local/share/khal/calendars/sports_f1" 2>/dev/null

if [ "$failures" -gt 0 ]; then
  printf '\n%d failing\n' "$failures" >&2
  exit 1
fi
echo "bin/: all checks passed"
