import QtQuick
import Quickshell
import Quickshell.Io

import "Khal.js" as Khal

// Shared khal state for the bar popup and the full manager panel. Both show
// the same events over the same range, so the helper runs once here rather
// than once per surface.
//
// Everything that touches khal goes through bin/: khal has no library API
// worth binding from QML, and keeping the shelling-out in scripts means the
// whole data layer stays testable from a terminal.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "harbefas.almanac"

  // The shell hands settings to bar widgets, not to services, so the widget
  // forwards them here — this is the only place both surfaces can read them
  // from.
  property string defaultCalendar: ""

  function applySettings(settings) {
    if (!settings) return
    if (typeof settings.defaultCalendar === "string")
      defaultCalendar = settings.defaultCalendar
  }

  // The configured calendar only counts if khal still has it and it is
  // writable; otherwise a renamed calendar would silently send every new
  // event nowhere.
  function calendarForNewEvents() {
    var writable = writableCalendars
    for (var i = 0; i < writable.length; i++)
      if (writable[i].name === defaultCalendar) return defaultCalendar
    return writable.length > 0 ? writable[0].name : ""
  }

  function helper(name) {
    return String(Qt.resolvedUrl("bin/" + name)).replace("file://", "")
  }

  // ---- Events. The range is driven by whichever grid is on screen; both
  //      surfaces show a month, so the wider of the two requests wins and the
  //      narrower one reads the same map.
  property string rangeStart: ""
  property string rangeEnd: ""
  property var events: []
  property var eventsByDay: ({})
  property bool loading: false

  // A range change while a fetch is in flight is remembered rather than
  // dropped: stepping through months faster than khal answers would otherwise
  // leave the grid showing the month before last.
  property bool refetch: false

  // A read that failed is not an empty calendar. Without this the panel drew
  // "No events" whether khal had nothing to say or was not installed at all.
  property string error: ""

  function noteFailure(code, message) {
    if (code === 0) return false
    error = message !== "" ? message : "a helper in bin/ exited with " + code
    return true
  }

  // A producer stopped for running over its ceiling exits on a signal with
  // nothing left on stderr, so the overflow has to name itself — otherwise the
  // panel reports a bare exit code for the one failure it can explain exactly.
  function overflowed(proc) {
    return proc.stdout.overflowed || proc.stderr.overflowed
  }

  function noteOverflow(proc) {
    if (!overflowed(proc)) return false
    error = "a helper in bin/ wrote more than " + Math.floor(proc.stdout.limit / 1024)
      + " KB and was stopped"
    return true
  }

  // Both streams start fresh on every run; a Process is reused, and the
  // previous run's bytes are not part of this one's budget.
  function resetReaders(proc) {
    proc.stdout.reset()
    proc.stderr.reset()
  }

  function errorTextOf(proc) {
    return String(proc.stderr.text || "").trim()
  }

  function setRange(first, last) {
    if (first === rangeStart && last === rangeEnd) return
    rangeStart = first
    rangeEnd = last
    refreshEvents()
  }

  function refreshEvents() {
    if (rangeStart === "" || rangeEnd === "") return
    if (eventsProc.running) {
      refetch = true
      return
    }
    loading = true
    eventsProc.command = [helper("khal-events"), rangeStart, rangeEnd]
    eventsProc.running = true
  }

  Process {
    id: eventsProc

    stdout: BoundedReader { process: eventsProc }
    stderr: BoundedReader { process: eventsProc; limit: 64 * 1024 }

    onStarted: root.resetReaders(eventsProc)
    onExited: function(exitCode) {
      root.loading = false
      if (root.noteOverflow(eventsProc)) return
      if (!root.noteFailure(exitCode, root.errorTextOf(eventsProc))) {
        root.error = ""
        var list = Khal.parseJson(eventsProc.stdout.text, [])
        root.events = list
        root.eventsByDay = Khal.groupByDay(list, root.rangeStart, root.rangeEnd)
      }
      if (root.refetch) {
        root.refetch = false
        root.refreshEvents()
      }
    }
  }

  // ---- Calendars. khal printcalendars drops the readonly flag, so the
  //      helper reads the config instead; the panel needs it before it can
  //      offer to create or delete anything.
  property var calendars: []
  readonly property var writableCalendars: calendars.filter(function(c) { return !c.readonly })

  function refreshCalendars() {
    if (!calendarsProc.running) calendarsProc.running = true
  }

  Process {
    id: calendarsProc
    command: [root.helper("khal-calendars")]

    stdout: BoundedReader { process: calendarsProc; limit: 1024 * 1024 }
    stderr: BoundedReader { process: calendarsProc; limit: 64 * 1024 }

    onStarted: root.resetReaders(calendarsProc)
    onExited: function(exitCode) {
      if (root.noteOverflow(calendarsProc)) return
      if (!root.noteFailure(exitCode, root.errorTextOf(calendarsProc)))
        root.calendars = Khal.parseJson(calendarsProc.stdout.text, [])
    }
  }

  // ---- Feeds.
  property var feeds: []

  function refreshFeeds() {
    if (!feedsProc.running) feedsProc.running = true
  }

  Process {
    id: feedsProc
    command: [root.helper("khal-feeds"), "list"]

    stdout: BoundedReader { process: feedsProc; limit: 1024 * 1024 }
    stderr: BoundedReader { process: feedsProc; limit: 64 * 1024 }

    onStarted: root.resetReaders(feedsProc)
    onExited: function(exitCode) {
      if (root.noteOverflow(feedsProc)) return
      if (!root.noteFailure(exitCode, root.errorTextOf(feedsProc)))
        root.feeds = Khal.parseJson(feedsProc.stdout.text, [])
    }
  }

  // ---- Mutations. One at a time: every one of them ends in a refresh, and
  //      two overlapping writes would race to describe the result. The panel
  //      reads `busy` to keep its forms shut while one is in flight.
  property bool busy: false
  property string status: ""
  signal mutated(bool ok, string message)

  function run(args) {
    if (busy) return false
    busy = true
    status = ""
    mutationProc.command = args
    mutationProc.running = true
    return true
  }

  function createEvent(calendar, start, end, title, location, description, repeat) {
    return run([helper("khal-event-new"), calendar, start, end, title,
      location || "", description || "", repeat || ""])
  }

  function updateEvent(uid, fields) {
    var args = [helper("khal-event-edit"), uid]
    var names = ["title", "start", "end", "location", "description", "calendar"]
    for (var i = 0; i < names.length; i++) {
      var value = fields[names[i]]
      if (value !== undefined && value !== null)
        args.push("--" + names[i], String(value))
    }
    return run(args)
  }

  function deleteEvent(uid) {
    return run([helper("khal-event-edit"), uid, "--delete"])
  }

  function addFeed(name, url, color) {
    return run([helper("khal-feeds"), "add", name, url, "--color", color || "light blue"])
  }

  function removeFeed(name) {
    return run([helper("khal-feeds"), "remove", name])
  }

  function syncFeed(name) {
    return run(name ? [helper("khal-feeds"), "sync", name] : [helper("khal-feeds"), "sync"])
  }

  Process {
    id: mutationProc

    // The helpers report failure on stderr in plain prose ("calendar 'x' is
    // readonly"), which is the message worth putting in front of someone —
    // stdout only ever carries the success envelope.
    stdout: BoundedReader { process: mutationProc; limit: 1024 * 1024 }
    stderr: BoundedReader { process: mutationProc; limit: 64 * 1024 }

    onStarted: root.resetReaders(mutationProc)
    onExited: function(exitCode) {
      root.busy = false
      if (root.noteOverflow(mutationProc)) {
        root.mutated(false, root.error)
        return
      }
      var ok = exitCode === 0
      if (ok) root.status = mutationProc.stdout.text
      root.mutated(ok, ok ? "" : (root.errorTextOf(mutationProc) || "failed"))
      if (ok) {
        root.refreshEvents()
        root.refreshCalendars()
        root.refreshFeeds()
      }
    }
  }

  // ---- Manager panel plumbing. The bar popup keeps its own IPC on the bare
  //      plugin id; this is the full window, so it goes through the shell's
  //      panel loader rather than the bar.
  function call(name, id, payloadJson) {
    if (!shell || typeof shell[name] !== "function") return false
    return (payloadJson === undefined
      ? shell[name](id)
      : shell[name](id, payloadJson)) === true
  }

  IpcHandler {
    target: root.pluginId + ".manager"

    function open(): string { return root.call("summon", root.pluginId) ? "opened" : "unavailable" }
    function close(): string { return root.call("hide", root.pluginId) ? "closed" : "unavailable" }
    function toggle(): string { return root.call("toggle", root.pluginId) ? "toggled" : "unavailable" }
    function refresh(): string {
      root.refreshEvents()
      root.refreshCalendars()
      root.refreshFeeds()
      return "refreshing"
    }
  }

  Component.onCompleted: {
    refreshCalendars()
    refreshFeeds()
  }
}
