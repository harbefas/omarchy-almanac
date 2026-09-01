import Quickshell.Io

import "Khal.js" as Khal

// A collector with a ceiling.
//
// StdioCollector appends every byte a helper writes into one buffer and only
// hands it over once the stream ends, so a calendar, a config or a chatty
// vdirsyncer large enough to matter is already resident in the shell before
// any check can run. This reads the stream instead: an empty splitMarker
// makes SplitParser emit each chunk as it arrives rather than holding one
// back waiting for a delimiter — which a single-line JSON document never
// contains anyway — and the total is counted on the way past.
//
// Going over the limit is a failure, not a truncation: half a JSON document
// parses to nothing useful and would be indistinguishable from an empty
// calendar. The producer is terminated, `overflowed` says why, and the
// process's exit handler reports it.
SplitParser {
  id: reader

  splitMarker: ""

  // The Process being read. Needed because stopping the reader is not enough:
  // the helper on the other end has to be told to stop writing.
  required property var process
  property int limit: 4 * 1024 * 1024

  readonly property string text: accumulated
  property bool overflowed: false

  property string accumulated: ""

  // Called before each run; a Process is reused across runs and the previous
  // run's bytes are not part of this one's budget.
  function reset() {
    accumulated = ""
    overflowed = false
  }

  onRead: function(data) {
    if (overflowed) return
    var next = Khal.appendBounded(accumulated, data, limit)
    if (next === null) {
      overflowed = true
      accumulated = ""
      process.running = false
      return
    }
    accumulated = next
  }
}
