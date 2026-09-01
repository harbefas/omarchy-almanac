// Unit tests for Khal.js, which is kept Qt-free precisely so these can run
// under plain node instead of by opening the panel and looking.

const fs = require("fs");

const K = {};
new Function("exports", fs.readFileSync(process.argv[2], "utf8") + ";" +
  "Object.assign(exports, { parseJson, appendBounded, clean, sanitize, isoDate," +
  " isoDateTime, groupByDay, addDays, filterEvents, timeLabel, rangeLabel });")(K);

let failures = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) return;
  console.error(`FAIL ${name}\n  expected ${e}\n  actual   ${a}`);
  failures++;
}

// ---- parseJson: the boundary every byte from a feed crosses

const ESC = String.fromCharCode(27);
const nasty = JSON.stringify([{ title: `a${ESC}[31mb\nc`, url: "x".repeat(900) }]);
check("control characters become spaces", K.parseJson(nasty, [])[0].title, "a [31mb c");
check("fields are capped", K.parseJson(nasty, [])[0].url.length, 400);
check("oversize output degrades", K.parseJson("x".repeat(5 * 1024 * 1024), []), []);
check("unparseable output degrades", K.parseJson("not json", []), []);
check("null degrades", K.parseJson("null", []), []);
check("non-strings pass through", K.parseJson('[{"repeats":true,"n":3}]', [])[0],
  { repeats: true, n: 3 });
check("nested strings are cleaned", K.parseJson('[{"a":{"b":"x\\ty"}}]', [])[0].a.b, "x y");

// ---- appendBounded: the ceiling BoundedReader enforces while a helper is
//      still writing. Returning null is what tells the reader to kill the
//      producer, so "null" here means "the process gets stopped".

check("a chunk under the limit accumulates", K.appendBounded("ab", "cd", 10), "abcd");
check("the budget is cumulative, not per chunk",
  K.appendBounded("x".repeat(9), "yy", 10), null);
check("landing exactly on the limit is allowed",
  K.appendBounded("x".repeat(8), "yy", 10), "x".repeat(8) + "yy");
check("one oversize chunk on an empty buffer is refused",
  K.appendBounded("", "x".repeat(11), 10), null);
check("an empty chunk is not an overflow", K.appendBounded("abc", "", 3), "abc");
check("a missing chunk is treated as empty", K.appendBounded("abc", null, 3), "abc");
// Whatever the reader accumulated before the overflow is dropped rather than
// handed on: half a JSON document parses to nothing anyway, and keeping it
// would leave the memory the ceiling exists to reclaim.
check("a dropped buffer parses to the fallback", K.parseJson("", []), []);

// ---- dates

check("isoDate pads", K.isoDate(new Date(2026, 8, 2)), "2026-09-02");
check("isoDate keeps two digits", K.isoDate(new Date(2026, 11, 25)), "2026-12-25");
check("isoDateTime with time", K.isoDateTime(new Date(2026, 8, 2), "09:00"), "2026-09-02T09:00");
check("isoDateTime without time", K.isoDateTime(new Date(2026, 8, 2), ""), "2026-09-02");
check("addDays forward", K.addDays("2026-08-31", 1), "2026-09-01");
check("addDays backward over a month", K.addDays("2026-09-01", -1), "2026-08-31");
check("addDays over a year", K.addDays("2026-12-31", 1), "2027-01-01");

// ---- grouping: an all-day event covers its span, a timed one does not

const allDay = { date: "2026-08-31", endDate: "2026-09-13", time: "", title: "US Open" };
// Ends 02:10 the next morning; it belongs to the night it starts.
const overnight = { date: "2026-09-01", endDate: "2026-09-02", time: "23:10", title: "STL" };
const grouped = K.groupByDay([allDay, overnight], "2026-08-31", "2026-09-03");
check("all-day spans its days",
  Object.keys(grouped).sort(), ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03"]);
check("timed event stays on its start day",
  grouped["2026-09-02"].map(e => e.title), ["US Open"]);
check("the night it starts has both",
  grouped["2026-09-01"].map(e => e.title).sort(), ["STL", "US Open"]);
check("nothing leaks outside the range", grouped["2026-08-30"], undefined);
// DTEND is exclusive for an all-day event, so the last day is not its own.
const twoDay = { date: "2026-09-05", endDate: "2026-09-07", time: "", title: "Probe" };
check("all-day DTEND is exclusive",
  Object.keys(K.groupByDay([twoDay], "2026-09-01", "2026-09-10")).sort(),
  ["2026-09-05", "2026-09-06"]);

// ---- search

const events = [
  { title: "Aston Villa - Arsenal", calendar: "sports_pl", location: "Villa Park", description: "" },
  { title: "Lecce - AS Roma", calendar: "sports_seriea", location: "Via Del Mare", description: "" }
];
check("search is case-insensitive", K.filterEvents(events, "ARSENAL").map(e => e.calendar), ["sports_pl"]);
check("search covers the location", K.filterEvents(events, "del mare").length, 1);
check("search covers the calendar", K.filterEvents(events, "seriea").length, 1);
check("an empty query keeps everything", K.filterEvents(events, "  ").length, 2);
check("no match is empty, not everything", K.filterEvents(events, "zzz").length, 0);

// ---- labels

check("a timed event shows its time", K.timeLabel({ time: "13:30" }), "13:30");
check("an all-day event gets a placeholder", K.timeLabel({ time: "" }), "—");
check("range with an end", K.rangeLabel({ time: "13:30", endTime: "15:15" }), "13:30 – 15:15");
check("range without an end", K.rangeLabel({ time: "13:30", endTime: "" }), "13:30");
check("all-day range", K.rangeLabel({ time: "" }), "All day");
check("no event at all", K.rangeLabel(null), "");

if (failures > 0) {
  console.error(`\n${failures} failing`);
  process.exit(1);
}
console.log("Khal.js: all checks passed");
