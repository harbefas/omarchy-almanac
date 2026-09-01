// Pure event math for the Almanac service and its panels. Everything here is
// Qt-free so it can be run under node the way the clock's Model.js is; the QML
// owns anything locale-shaped.

// Everything that reaches the UI came out of an .ics file that someone else
// publishes, so it is treated as hostile: bounded in size, stripped of
// control characters, and capped per field. Without the cap one runaway feed
// could stall the shell laying out a single line.
var MAX_PROCESS_OUTPUT = 4 * 1024 * 1024
var MAX_FIELD_LENGTH = 400

function clean(value) {
  return String(value)
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .substring(0, MAX_FIELD_LENGTH)
}

function sanitize(value) {
  if (typeof value === "string") return clean(value)
  if (Array.isArray(value)) {
    var list = []
    for (var i = 0; i < value.length; i++) list.push(sanitize(value[i]))
    return list
  }
  if (value && typeof value === "object") {
    var out = {}
    for (var key in value) out[key] = sanitize(value[key])
    return out
  }
  return value
}

// Stream ceiling, applied while a helper is still writing. The collector that
// used to sit on these pipes buffered a whole stream before anything could
// look at it, so the cap below could only ever be checked once the memory had
// already been taken; BoundedReader calls this per chunk instead and kills the
// producer the moment the total would go over. Returns the new accumulated
// text, or null to say "over the line, stop reading".
//
// Lengths are UTF-16 code units, which are never more than the byte count of
// the UTF-8 they were decoded from, so a limit here is at least as strict as
// the same number of bytes.
function appendBounded(text, chunk, limit) {
  var next = String(chunk === undefined || chunk === null ? "" : chunk)
  if (String(text || "").length + next.length > limit) return null
  return String(text || "") + next
}

// A helper's stdout is JSON, but a helper that dies mid-write still produces
// something parseable-looking, so every parse is guarded and every failure
// degrades to empty rather than throwing inside a signal handler.
//
// The size check here is now a backstop behind appendBounded, not the only
// ceiling: by the time text reaches this function it is already bounded.
function parseJson(text, fallback) {
  var raw = String(text || "")
  if (raw.length > MAX_PROCESS_OUTPUT) return fallback
  try {
    var value = JSON.parse(raw)
    return value === null ? fallback : sanitize(value)
  } catch (e) {
    return fallback
  }
}

// "yyyy-MM-dd" — the same key shape monthGrid() puts on every calendar cell,
// so events index straight into the grid without a second conversion.
function isoDate(date) {
  var month = date.getMonth() + 1
  var day = date.getDate()
  return date.getFullYear()
    + "-" + (month < 10 ? "0" + month : month)
    + "-" + (day < 10 ? "0" + day : day)
}

function isoDateTime(date, time) {
  return isoDate(date) + (time ? "T" + time : "")
}

// Events arrive flat and sorted; the grid wants them keyed by day. An all-day
// event spanning several days is reported by khal under its start date only,
// so it is spread across the days it covers — otherwise a tournament running
// all fortnight shows up on one cell and the other thirteen look empty.
//
// A *timed* event is never spread, even when it crosses midnight. A ballgame
// starting 23:10 and ending 02:10 belongs to the night it starts; listing it
// on the next day too put "23:10" on a day it never began.
function groupByDay(events, firstKey, lastKey) {
  var map = {}
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    var day = event.date
    var last = event.time ? day : (event.endDate || event.date)
    // An all-day event's DTEND is exclusive, so the final day is not its own.
    if (!event.time && last > day) last = addDays(last, -1)
    while (day <= last) {
      if (day >= firstKey && day <= lastKey) {
        if (!map[day]) map[day] = []
        map[day].push(event)
      }
      if (day === last) break
      day = addDays(day, 1)
    }
  }
  return map
}

function addDays(key, delta) {
  var parts = key.split("-")
  var date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  date.setDate(date.getDate() + delta)
  return isoDate(date)
}

// Case-insensitive substring over the fields a person would search by. Kept
// here rather than pushed down to `khal search` so typing filters what is
// already on screen instead of waiting on a process per keystroke.
function filterEvents(events, term) {
  var needle = String(term || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (needle === "") return events
  var out = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    var haystack = [event.title, event.calendar, event.location, event.description]
      .join(" ").toLowerCase()
    if (haystack.indexOf(needle) >= 0) out.push(event)
  }
  return out
}

// "13:30", or an em-dash-free placeholder for an all-day event so the agenda
// column stays aligned.
function timeLabel(event) {
  return event && event.time ? event.time : "—"
}

function rangeLabel(event) {
  if (!event) return ""
  if (!event.time) return "All day"
  var end = event.endTime ? " – " + event.endTime : ""
  return event.time + end
}
