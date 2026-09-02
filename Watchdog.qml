import QtQuick

// A deadline for a Process, in two phases.
//
// Every helper in bin/ carries a deadline of its own, but a deadline inside
// the helper only covers the helper being slow. A helper that never gets as
// far as arming it, or that is stopped in a way it cannot notice, leaves the
// service holding `busy` forever, and the panel keeps its forms shut for as
// long as that lasts. So the side that cares about the answer keeps its own
// clock.
//
// TERM first, because a helper mid-write should get the chance to finish the
// rename it is in the middle of. KILL after the grace period, because a
// helper wedged on a mount that has stopped answering will not act on TERM
// either. `running = false` is the TERM; Process signals the group.
Timer {
  id: watchdog

  required property var process
  property string label: "a helper in bin/"
  property int deadlineMs: 60000
  property int graceMs: 2000

  // Read by the exit handler: a killed helper exits like any other failure,
  // and "it was still going after a minute" is the more useful thing to say
  // than whatever signal ended it.
  property bool fired: false

  repeat: false
  interval: deadlineMs

  function begin() {
    fired = false
    interval = deadlineMs
    restart()
  }

  onTriggered: {
    if (!fired) {
      fired = true
      interval = graceMs
      process.running = false
      restart()
      return
    }
    // Still there after the grace period. SIGKILL, which cannot be ignored.
    process.signal(9)
  }
}
