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

# ---- khal-feeds

cp "$here/fixtures/khal-config" "$work/khal-config"
cp "$here/fixtures/vdirsyncer-config" "$work/vdirsyncer-config"
export KHAL_CONFIG="$work/khal-config" VDIRSYNCER_CONFIG="$work/vdirsyncer-config"

out=$("$root/bin/khal-feeds" list)
check "http pairs are listed as feeds" '["holidays_pair"]' "$(jq -c 'map(.name)' <<<"$out")"
check "the local storage names the calendar" '"holidays"' "$(jq -c '.[0].calendar' <<<"$out")"

"$root/bin/khal-feeds" add sports_f1 "https://example.com/f1.ics" >/dev/null
check "adding a feed registers it" '2' "$("$root/bin/khal-feeds" list | jq -c 'length')"
check "the khal calendar is written too" '1' \
  "$(grep -c '^\[\[sports_f1\]\]' "$work/khal-config")"

"$root/bin/khal-feeds" add sports_f1 "https://example.com/f1.ics" >/dev/null 2>&1
check "a duplicate feed is refused" '1' "$?"

"$root/bin/khal-feeds" remove sports_f1 >/dev/null
check "removing restores the vdirsyncer config byte for byte" '' \
  "$(diff "$here/fixtures/vdirsyncer-config" "$work/vdirsyncer-config")"
check "removing restores the khal config byte for byte" '' \
  "$(diff "$here/fixtures/khal-config" "$work/khal-config")"

# The feed's own directory is deliberately left behind, so nothing here
# should have deleted it.
rmdir "$HOME/.local/share/khal/calendars/sports_f1" 2>/dev/null

if [ "$failures" -gt 0 ]; then
  printf '\n%d failing\n' "$failures" >&2
  exit 1
fi
echo "bin/: all checks passed"
