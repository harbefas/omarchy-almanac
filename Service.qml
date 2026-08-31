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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = Khal.parseJson(text, [])
        root.events = list
        root.eventsByDay = Khal.groupByDay(list, root.rangeStart, root.rangeEnd)
        root.loading = false
      }
    }
    onExited: {
      root.loading = false
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendars = Khal.parseJson(text, [])
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.feeds = Khal.parseJson(text, [])
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
    var names = ["title", "start", "end", "location", "description"]
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
    property string errorText: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.status = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: mutationProc.errorText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.busy = false
      var ok = exitCode === 0
      root.mutated(ok, ok ? "" : (mutationProc.errorText || "failed"))
      mutationProc.errorText = ""
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
  function call(name, id) {
    return !!shell && typeof shell[name] === "function" && shell[name](id) === true
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
