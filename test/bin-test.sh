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

# A config reached through a symlinked directory is refused: the walk opens
# every component with O_NOFOLLOW, so the path cannot be redirected part of
# the way along.
mkdir -p "$work/realconf"
cp "$here/fixtures/khal-config" "$work/realconf/khal-config"
ln -sfn "$work/realconf" "$work/linkconf"
KHAL_CONFIG="$work/linkconf/khal-config" "$root/bin/khal-calendars" >/dev/null 2>&1
check "a config behind a symlinked directory is refused" '66' "$?"
KHAL_CONFIG="$work/realconf/khal-config" "$root/bin/khal-calendars" >/dev/null 2>&1
check "the same config read directly is fine" '0' "$?"

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
for cmd in jq bash env sed awk cat printf timeout mktemp rm head stat python3; do
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

# ---- khal-events: producer ceilings
#
# The panel reads whatever comes out of here into a shell that never restarts,
# so the helper caps what it can hand over. A feed cannot decide either how
# many events the shell holds or how long any one string in them is.

for cmd in seq tr; do ln -sf "$(command -v "$cmd")" "$work/stub/$cmd"; done

cat >"$work/stub/khal" <<'STUB'
#!/usr/bin/env bash
# 3000 events on one day, one of them carrying a description far past the cap.
{
  printf '['
  for i in $(seq 1 3000); do
    [ "$i" -gt 1 ] && printf ','
    printf '{"start-date": "31/08/2026", "start-time": "13:30", "end-date": "31/08/2026", "end-time": "15:15", "title": "Event %s", "calendar": "flood", "uid": "u%s", "location": "", "description": "", "repeat-symbol": ""}' "$i" "$i"
  done
  printf ']\n'
}
STUB
chmod +x "$work/stub/khal"

out=$(PATH="$work/stub" KHAL_FILTERS="$work/no-filters.json" \
  "$root/bin/khal-events" 2026-08-31 2026-08-31)
check "capping the event list is not a failure" '0' "$?"
check "the event list is capped" '2000' "$(jq -c 'length' <<<"$out")"

cat >"$work/stub/khal" <<'STUB'
#!/usr/bin/env bash
printf '[{"start-date": "31/08/2026", "start-time": "13:30", "end-date": "31/08/2026", "end-time": "15:15", "title": "%s", "calendar": "flood", "uid": "u1", "location": "%s", "description": "%s", "repeat-symbol": ""}]\n' \
  "$(head -c 5000 /dev/zero | tr '\0' 'T')" \
  "$(head -c 5000 /dev/zero | tr '\0' 'L')" \
  "$(head -c 5000 /dev/zero | tr '\0' 'D')"
STUB
chmod +x "$work/stub/khal"

out=$(PATH="$work/stub" KHAL_FILTERS="$work/no-filters.json" \
  "$root/bin/khal-events" 2026-08-31 2026-08-31)
check "a runaway title is cut to the cap" '400' "$(jq -c '.[0].title | length' <<<"$out")"
check "a runaway location is cut to the cap" '400' "$(jq -c '.[0].location | length' <<<"$out")"
check "a runaway description is cut to the cap" '400' \
  "$(jq -c '.[0].description | length' <<<"$out")"

# ---- khal-calendars: the same ceiling on the config side

{
  echo '[calendars]'
  for i in $(seq 1 600); do
    printf '\n[[cal%s]]\npath = /tmp/cal%s/\ncolor = light blue\n' "$i" "$i"
  done
} >"$work/flood-khal-config"

out=$(KHAL_CONFIG="$work/flood-khal-config" "$root/bin/khal-calendars")
check "the calendar list is capped" '500' "$(jq -c 'length' <<<"$out")"

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

# An .ics is written by whoever publishes the feed, and one event per file is
# the format, so a file far past any real event is skipped rather than parsed.
# The uid lives only in the oversize file, so finding it would mean the cap
# did not bite.
{
  printf 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:huge-1\nSUMMARY:Huge\nX-PAD:'
  head -c 5000000 /dev/zero | tr '\0' 'x'
  printf '\nDTSTART;VALUE=DATE:20260920\nDTEND;VALUE=DATE:20260921\nEND:VEVENT\nEND:VCALENDAR\n'
} >"$work/cal/work/huge.ics"

"$root/bin/khal-event-edit" huge-1 --title Renamed >/dev/null 2>&1
check "an oversize .ics is not searched" '1' "$?"
check "the oversize file is left alone" '1' \
  "$(find "$work/cal/work" -name 'huge.ics' | wc -l)"
rm "$work/cal/work/huge.ics"

# ---- khal-event-edit: the search is bounded three ways
#
# A calendar directory is filled by vdirsyncer on behalf of whoever publishes
# the feed, so the number of files, their total size and the time spent
# walking them are all capped. Each ceiling is lowered by an environment
# variable here rather than built up to honestly.

mkdir -p "$work/cal/many"
for i in $(seq 1 12); do
  cat >"$work/cal/many/event$i.ics" <<ICS
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:many-$i
SUMMARY:Event $i
DTSTART;VALUE=DATE:20260920
DTEND;VALUE=DATE:20260921
END:VEVENT
END:VCALENDAR
ICS
done

cat >"$work/many-config" <<CONFIG
[calendars]

[[many]]
path = $work/cal/many/
color = light green

[sqlite]
path = $work/khal.db
CONFIG

export KHAL_CONFIG="$work/many-config"

# Asked for a uid that is not there, so the whole directory is walked and the
# ceiling is what ends it. Which of the twelve files scandir hands back first
# is not fixed, so the message is what is checked, not the exit code that a
# plain "not found" would share.
err=$(KHAL_SEARCH_FILES=3 "$root/bin/khal-event-edit" nobody --title X 2>&1 >/dev/null)
check "the file count ceiling stops the search" 'searched 3 files without finding' \
  "${err%% [\'\"]*}"

err=$(KHAL_SEARCH_BYTES=10 "$root/bin/khal-event-edit" nobody --title X 2>&1 >/dev/null)
check "the byte ceiling stops the search" 'read 10 bytes without finding' \
  "${err%% [\'\"]*}"

err=$(KHAL_SEARCH_TIMEOUT=0 "$root/bin/khal-event-edit" nobody --title X 2>&1 >/dev/null)
check "the search deadline stops the search" 'longer than 0s' "${err##*took }"

"$root/bin/khal-event-edit" many-12 --title Renamed >/dev/null
check "an unbounded-enough search still finds the event" '1' \
  "$(grep -c '^SUMMARY:Renamed' "$work/cal/many/event12.ics")"

ln -sfn "$work/cal/many" "$work/cal/many-link"
cat >"$work/linked-config" <<CONFIG
[calendars]

[[many]]
path = $work/cal/many-link/
color = light green
CONFIG
KHAL_CONFIG="$work/linked-config" \
  "$root/bin/khal-event-edit" many-1 --title X >/dev/null 2>&1
check "a symlinked calendar directory is refused" '1' "$?"

export KHAL_CONFIG="$work/edit-config"

unset KHAL_CONFIG

# ---- the mutation helpers take their payload on stdin
#
# A title, a location and a description are the private part of a calendar,
# and /proc/<pid>/cmdline is readable by anything running on the machine, so
# the panel sends them down a pipe. The positional form stays for terminal
# use, where the person typing the arguments is the person reading them.

mkdir -p "$work/cal/stdin"
cat >"$work/stdin-config" <<CONFIG
[calendars]

[[stdin]]
path = $work/cal/stdin/
color = light green

[sqlite]
path = $work/khal.db
CONFIG

cat >"$work/cal/stdin/probe.ics" <<'ICS'
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:stdin-1
SUMMARY:Before
DTSTART;VALUE=DATE:20260920
DTEND;VALUE=DATE:20260921
END:VEVENT
END:VCALENDAR
ICS

export KHAL_CONFIG="$work/stdin-config"

jq -nc '{uid: "stdin-1", title: "From stdin"}' |
  "$root/bin/khal-event-edit" --stdin >/dev/null
check "an edit reads its payload from stdin" '1' \
  "$(grep -c '^SUMMARY:From stdin' "$work/cal/stdin/probe.ics")"

echo 'not json' | "$root/bin/khal-event-edit" --stdin >/dev/null 2>&1
check "an unreadable payload is refused" '1' "$?"

jq -nc '{title: "no uid here"}' | "$root/bin/khal-event-edit" --stdin >/dev/null 2>&1
check "a payload naming no event is refused" '1' "$?"

# 512 KB of payload against a 256 KB ceiling. Assembled on the pipe rather
# than through an argument, because a payload that size does not fit in argv,
# which is rather the point of sending it this way.
{
  printf '{"uid":"stdin-1","description":"'
  head -c 524288 /dev/zero | tr '\0' 'x'
  printf '"}'
} | "$root/bin/khal-event-edit" --stdin >/dev/null 2>&1
check "an oversize payload is refused" '1' "$?"

# The file is named after the uid, which is how vdirsyncer and khal name them,
# so the search should not have had to walk anything to find it.
mv "$work/cal/stdin/probe.ics" "$work/cal/stdin/stdin-1.ics"
jq -nc '{uid: "stdin-1", title: "Found by name"}' |
  KHAL_SEARCH_FILES=0 "$root/bin/khal-event-edit" --stdin >/dev/null
check "a file named after the uid is found without a walk" '1' \
  "$(grep -c '^SUMMARY:Found by name' "$work/cal/stdin/stdin-1.ics")"

jq -nc '{uid: "stdin-1", delete: true}' |
  "$root/bin/khal-event-edit" --stdin >/dev/null
check "a delete reads its payload from stdin" '0' \
  "$(find "$work/cal/stdin" -name '*.ics' | wc -l)"

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

# ---- khal-feeds sync: a producer that never stops talking
#
# vdirsyncer's output is quoted into the JSON this helper prints, and that
# JSON is read into the shell. A sync that writes forever must be stopped by
# the helper rather than drained, and the helper has to keep saying so in
# valid JSON — a truncated document would be indistinguishable from a feed
# with nothing to report.

mkdir -p "$work/sync-stub"
cat >"$work/sync-stub/vdirsyncer" <<'STUB'
#!/usr/bin/env bash
# Writes until it is killed. `discover` is just as noisy, which is the other
# half of the test: none of it may reach the JSON on stdout.
exec 2>&1
while :; do
  head -c 4096 /dev/zero | tr ' ' 'x'
  echo
done
STUB
chmod +x "$work/sync-stub/vdirsyncer"
for cmd in bash env head tr jq python3; do
  ln -sf "$(command -v "$cmd")" "$work/sync-stub/$cmd"
done

out=$(PATH="$work/sync-stub:$PATH" timeout 30 "$root/bin/khal-feeds" sync)
check "an endless sync still prints one JSON document" '0' "$?"
check "the document parses" 'ok' "$(jq -e . >/dev/null 2>&1 <<<"$out" && echo ok || echo broken)"
check "the overflow is reported as a failure" 'false' "$(jq -c '.ok' <<<"$out")"
check "the overflow is named" 'true' "$(jq -c '.truncated' <<<"$out")"
# 64 KiB of output plus the sentence explaining the cut, and nothing like the
# unbounded string the old capture_output would have built.
check "the captured output is bounded" 'true' \
  "$(jq -c '(.output | length) < 70000' <<<"$out")"

# ---- khal-feeds sync: a producer that goes quiet and never finishes
#
# The byte ceiling only bounds a producer that talks. A remote that accepts the
# connection and then says nothing leaves vdirsyncer waiting on it, and the
# panel waiting on vdirsyncer, so the wall clock is bounded too.

cat >"$work/sync-stub/vdirsyncer" <<'STUB'
#!/usr/bin/env bash
# Says one thing, then hangs forever without closing its stdout.
echo "connecting"
sleep 600
STUB
chmod +x "$work/sync-stub/vdirsyncer"
ln -sf "$(command -v sleep)" "$work/sync-stub/sleep"

start=$(date +%s)
out=$(PATH="$work/sync-stub:$PATH" VDIRSYNCER_TIMEOUT=1 timeout 30 "$root/bin/khal-feeds" sync)
check "a hung sync still prints one JSON document" '0' "$?"
elapsed=$(($(date +%s) - start))
check "a hung sync gives up on the deadline" 'true' "$([ "$elapsed" -lt 15 ] && echo true || echo false)"
check "the hung sync is reported as a failure" 'false' "$(jq -c '.ok' <<<"$out")"
check "the deadline is named" 'true' "$(jq -c '.timedOut' <<<"$out")"
check "what it said before hanging is kept" 'true' \
  "$(jq -c '.output | contains("connecting")' <<<"$out")"

# ---- khal-events: bounds that hold before anything is aggregated

cat >"$work/stub/khal" <<'STUB'
#!/usr/bin/env bash
# One array per day, forever: the events can never be counted without a
# ceiling on the bytes, because the stream has no end to count up to.
while :; do
  printf '[{"start-date": "31/08/2026", "start-time": "13:30", "end-date": "31/08/2026", "end-time": "15:15", "title": "Flood", "calendar": "flood", "uid": "u1", "location": "", "description": "", "repeat-symbol": ""}]\n'
done
STUB
chmod +x "$work/stub/khal"

start=$(date +%s)
out=$(PATH="$work/stub" KHAL_FILTERS="$work/no-filters.json" \
  timeout 60 "$root/bin/khal-events" 2026-08-31 2026-08-31)
# Hitting a ceiling closes a pipe upstream. That is the bound doing its job,
# so it must not surface as a failed run.
check "an endless calendar is not reported as a failure" '0' "$?"
elapsed=$(($(date +%s) - start))
check "an endless calendar still terminates" 'true' "$([ "$elapsed" -lt 45 ] && echo true || echo false)"
check "an endless calendar still parses" 'ok' \
  "$(jq -e . >/dev/null 2>&1 <<<"$out" && echo ok || echo broken)"
check "an endless calendar is cut to the event cap" 'true' \
  "$(jq -c 'length <= 2000' <<<"$out")"

cat >"$work/stub/khal" <<'STUB'
#!/usr/bin/env bash
# Accepts the call and then says nothing, which no byte ceiling can catch.
sleep 600
STUB
chmod +x "$work/stub/khal"
ln -sf "$(command -v sleep)" "$work/stub/sleep"
ln -sf "$(command -v date)" "$work/stub/date"

start=$(date +%s)
PATH="$work/stub" KHAL_FILTERS="$work/no-filters.json" KHAL_TIMEOUT=1 \
  timeout 30 "$root/bin/khal-events" 2026-08-31 2026-08-31 >/dev/null 2>&1
check "a hung khal is an error, not an empty day" '124' "$?"
elapsed=$(($(date +%s) - start))
check "a hung khal gives up on the deadline" 'true' "$([ "$elapsed" -lt 15 ] && echo true || echo false)"

# ---- khal-event-edit: the helper it shells out to is bounded the same way
#
# A config on a mount that has stopped answering is the shape of this: the
# read blocks, so khal-calendars never finishes and never says anything. A
# fifo nobody writes to is that mount, without needing one.

mkfifo "$work/hanging-config"
start=$(date +%s)
KHAL_CONFIG="$work/hanging-config" KHAL_HELPER_TIMEOUT=1 \
  timeout 30 "$root/bin/khal-event-edit" probe-1 --title Renamed >/dev/null 2>&1
check "a hung calendar helper is an error" '1' "$?"
elapsed=$(($(date +%s) - start))
check "a hung calendar helper gives up on the deadline" 'true' \
  "$([ "$elapsed" -lt 15 ] && echo true || echo false)"

# ---- configs are read as files, not as names

ln -sf "$work/khal-config" "$work/symlinked-config"
KHAL_CONFIG="$work/symlinked-config" "$root/bin/khal-calendars" >/dev/null 2>&1
check "a symlinked khal config is refused" '66' "$?"

ln -sf "$work/vdirsyncer-config" "$work/symlinked-vdirsyncer"
VDIRSYNCER_CONFIG="$work/symlinked-vdirsyncer" "$root/bin/khal-feeds" list >/dev/null 2>&1
check "khal-feeds refuses a symlinked config too" '1' "$?"

mkfifo "$work/fifo-config" 2>/dev/null || true
KHAL_CONFIG="$work/fifo-config" timeout 10 "$root/bin/khal-calendars" >/dev/null 2>&1
check "a khal config that is not a regular file is refused" '66' "$?"

head -c $((300 * 1024)) /dev/zero | tr '\0' '#' >"$work/huge-config"
KHAL_CONFIG="$work/huge-config" "$root/bin/khal-calendars" >/dev/null 2>&1
check "an oversize khal config is refused" '66' "$?"

# The filter map is the one file the panel can do without, so a bad one is not
# an error: it means no filtering, and the agenda still comes back.
cat >"$work/stub/khal" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"start-date": "31/08/2026", "start-time": "13:30", "end-date": "31/08/2026", "end-time": "15:15", "title": "Lecce - AS Roma", "calendar": "sports_seriea", "uid": "a1", "location": "", "description": "", "repeat-symbol": ""}]
[{"start-date": "01/09/2026", "start-time": "", "end-date": "02/09/2026", "end-time": "", "title": "Standup", "calendar": "personal", "uid": "a2", "location": "", "description": "", "repeat-symbol": ""}, {"start-date": "01/09/2026", "start-time": "20:00", "end-date": "01/09/2026", "end-time": "22:00", "title": "STL @ LAD", "calendar": "sports_mlb", "uid": "a3", "location": "", "description": "", "repeat-symbol": ""}]
JSON
STUB
chmod +x "$work/stub/khal"

ln -sf "$work/nope.json" "$work/symlinked-filters"
out=$(PATH="$work/stub" KHAL_FILTERS="$work/symlinked-filters" \
  "$root/bin/khal-events" 2026-08-31 2026-09-01)
# nope.json drops one of the three, so obeying it through the symlink would
# show as two events rather than three.
check "a symlinked filter map is ignored, not obeyed" '3' "$(jq -c 'length' <<<"$out")"

# ---- config writes are atomic and land in both files or neither

cp "$work/vdirsyncer-config.pristine" "$work/vdirsyncer-config"
cp "$work/khal-config.pristine" "$work/khal-config"

# khal's config is made unwritable after the vdirsyncer half has been built,
# which is the failure the two writes have to survive as a pair.
chmod 500 "$work"
chmod 400 "$work/khal-config"
"$root/bin/khal-feeds" add rollback_me "https://example.com/f1.ics" >/dev/null 2>&1
check "a feed that cannot be written to both configs fails" '1' "$?"
chmod 700 "$work"
chmod 600 "$work/khal-config"
check "the vdirsyncer half is rolled back" '' \
  "$(diff "$work/vdirsyncer-config.pristine" "$work/vdirsyncer-config")"
check "no half-written feed is left registered" '["holidays_pair"]' \
  "$("$root/bin/khal-feeds" list | jq -c 'map(.name)')"
check "no temp config is left behind" '0' \
  "$(find "$work" -maxdepth 1 -name '.*almanac.tmp' | wc -l)"

rmdir "$HOME/.local/share/khal/calendars/rollback_me" 2>/dev/null

# ---- the config ceiling bites before the sections are assembled

{
  echo '[general]'
  echo 'status_path = "/tmp/status/"'
  for i in $(seq 1 700); do
    printf '\n[pair p%s]\na = "p%s_local"\nb = "p%s_remote"\n' "$i" "$i" "$i"
  done
} >"$work/many-sections"
VDIRSYNCER_CONFIG="$work/many-sections" "$root/bin/khal-feeds" list >/dev/null 2>&1
check "a config with more sections than the cap is still read" '0' "$?"

# ---- a sync leaves nothing of its own behind
#
# vdirsyncer does its transport work in children, so killing the process this
# helper started is not the same as stopping the sync.

cat >"$work/sync-stub/vdirsyncer" <<'STUB'
#!/usr/bin/env bash
# A transport child that outlives its parent unless the group is killed.
bash -c 'while :; do sleep 1; done' &
echo "$!" >"$SYNC_CHILD_PIDFILE"
echo "connecting"
sleep 600
STUB
chmod +x "$work/sync-stub/vdirsyncer"

export SYNC_CHILD_PIDFILE="$work/sync-child.pid"
: >"$SYNC_CHILD_PIDFILE"
PATH="$work/sync-stub:$PATH" VDIRSYNCER_TIMEOUT=1 timeout 30 \
  "$root/bin/khal-feeds" sync >/dev/null 2>&1
child=$(cat "$SYNC_CHILD_PIDFILE")
sleep 1
check "the transport child dies with the sync" 'gone' \
  "$(kill -0 "$child" 2>/dev/null && echo alive || echo gone)"
unset SYNC_CHILD_PIDFILE

if [ "$failures" -gt 0 ]; then
  printf '\n%d failing\n' "$failures" >&2
  exit 1
fi
echo "bin/: all checks passed"
