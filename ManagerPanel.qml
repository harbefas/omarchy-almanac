import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

import "Model.js" as Model
import "Khal.js" as Khal

// The full Almanac window: month grid, agenda, event editing, calendar
// filters and feed management, all driven from the keyboard.
//
// The bar popup answers "what is on today"; this answers everything else, so
// it is a real window rather than a taller popup — it is meant to be sat in
// for a while, and a layer-shell surface that dies on a stray click is not.
//
// Every mutation goes through the service, which serialises them: two
// overlapping writes to the same .ics would race, and the forms stay shut
// while one is in flight rather than trying to merge the result.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property var pluginRegistry: null
  property bool opened: false

  // Without an explicit screen the layer surface lands on whichever output
  // Quickshell picked first, which is rarely the one being looked at.
  property var targetScreen: null

  // Shares the [menu] surface tokens, so a theme that styles the Omarchy menu
  // styles this too.
  readonly property color cardBackground: Color.menu.background
  readonly property color cardBorder: Color.menu.border
  readonly property var cardBorderSpec: Border.surfaceSpec("menu", "border",
    cardBorder, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(900), Math.round(panel.width * 0.82))
  readonly property int cardHeight: Math.min(Style.space(620), Math.round(panel.height * 0.78))

  function currentScreen() {
    var name = ""
    try { name = Hyprland.focusedMonitor.name } catch (e) { name = "" }
    if (!name) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return null
  }

  // ---- view state
  property string view: "agenda"
  property string focusRegion: "grid"
  property string formMode: ""
  onFormModeChanged: if (formMode === "") Qt.callLater(function() {
    keyScope.forceActiveFocus()
  })
  property string pendingDelete: ""
  property string status: ""

  property date today: new Date()
  property date selectedDate: new Date()
  property int listIndex: 0
  property int calendarIndex: 0
  property int feedIndex: 0
  property string query: ""

  // Calendars hidden from the agenda. Kept here rather than written back to
  // khal's config: this is a view filter, not a subscription change, and
  // unticking a calendar should not stop it syncing.
  property var hidden: ({})

  property bool shortcutHintsActive: false
  property int heldModifierFlags: 0

  readonly property bool hintCtrlHeld: (heldModifierFlags & Qt.ControlModifier) !== 0
  readonly property bool hintShiftHeld: (heldModifierFlags & Qt.ShiftModifier) !== 0
  readonly property bool hintAltHeld: (heldModifierFlags & Qt.AltModifier) !== 0

  component KeyHint: ShortcutHint {
    ctrlHeld: root.hintCtrlHeld
    shiftHeld: root.hintShiftHeld
    altHeld: root.hintAltHeld
    active: root.shortcutHintsActive
    foreground: root.foreground
  }

  readonly property color foreground: Color.foreground
  readonly property color secondary: Util.alpha(foreground, 0.55)
  readonly property color accent: Color.accent

  readonly property string todayKey: Model.keyForDate(today)
  readonly property string selectedKey: Model.keyForDate(selectedDate)
  readonly property int viewYear: selectedDate.getFullYear()
  readonly property int viewMonth: selectedDate.getMonth()
  readonly property int weekStart: Model.normalizedWeekStart(null, Qt.locale().firstDayOfWeek)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  readonly property var calendars: service ? service.calendars : []
  readonly property var feeds: service ? service.feeds : []
  readonly property bool busy: service ? service.busy : false
  readonly property bool loading: service ? service.loading : false

  // The old hints named what a step meant on the calendar ("day", "week");
  // these name the direction the cursor moves, which is what someone reaching
  // for hjkl is actually asking. Phrased for wherever the cursor is, so the
  // line never advertises a key that does something else right now.
  readonly property string hintLine: {
    if (view === "feeds")
      return "j k  ↓ ↑     n  add     s  sync     Shift+S  sync all     d  remove"
    if (view === "calendars")
      return "j k  ↓ ↑     Space  show / hide"
    if (focusRegion === "list")
      return "j k  ↓ ↑     Enter  edit     d  delete     Tab  calendar     /  search"
    return "h l  ← →     j k  ↓ ↑     [ ]  month     t  today"
      + "     Tab  events     n  new     ?  keys"
  }

  function visibleEvents(list) {
    var out = []
    for (var i = 0; i < list.length; i++)
      if (!root.hidden[list[i].calendar]) out.push(list[i])
    return out
  }

  // Searching widens the list from one day to the whole loaded range: a
  // query the user typed is about finding an event, not about the day that
  // happened to be selected when they started typing.
  readonly property var dayEvents: {
    if (!service) return []
    if (query.trim() !== "")
      return Khal.filterEvents(visibleEvents(service.events), query)
    return visibleEvents(service.eventsByDay[selectedKey] || [])
  }
  readonly property var selectedEvent: listIndex >= 0 && listIndex < dayEvents.length
    ? dayEvents[listIndex] : null

  function calendarNamed(name) {
    for (var i = 0; i < calendars.length; i++)
      if (calendars[i].name === name) return calendars[i]
    return null
  }

  readonly property bool selectedEditable: {
    if (!selectedEvent) return false
    var calendar = calendarNamed(selectedEvent.calendar)
    return !!calendar && !calendar.readonly
  }

  // ---- lifecycle

  function open(payloadJson) {
    targetScreen = currentScreen()
    opened = true
    today = new Date()
    view = "agenda"
    focusRegion = "grid"
    query = ""
    listIndex = 0

    // The popup hands over the day it was showing, so the handoff lands where
    // the person was already looking rather than snapping back to today.
    var handoff = ""
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && typeof payload.date === "string") handoff = payload.date
    } catch (e) { handoff = "" }

    if (handoff !== "") selectKey(handoff)
    else selectedDate = new Date()

    refresh()
    Qt.callLater(function() { keyScope.forceActiveFocus() })
  }

  // Re-entrant: the shell's hide() calls back into close(), so the guard is
  // what stops the two from calling each other until the stack runs out.
  function close() {
    if (!opened) return
    opened = false
    formMode = ""
    pendingDelete = ""
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "harbefas.almanac")
  }

  function refresh() {
    if (!service) return
    service.setRange(weeks[0].days[0].key, weeks[weeks.length - 1].days[6].key)
    service.refreshCalendars()
    service.refreshFeeds()
  }

  onWeeksChanged: {
    if (opened && service)
      service.setRange(weeks[0].days[0].key, weeks[weeks.length - 1].days[6].key)
  }

  function note(message) {
    status = message
    statusTimer.restart()
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: root.status = ""
  }

  Connections {
    target: root.service
    function onMutated(ok, message) {
      root.note(ok ? "Done" : message)
      if (ok) {
        root.formMode = ""
        root.pendingDelete = ""
      }
    }
  }

  // ---- navigation

  function moveDay(delta) {
    var next = new Date(selectedDate)
    next.setDate(next.getDate() + delta)
    selectedDate = next
    listIndex = 0
  }

  function moveMonth(delta) {
    var next = new Date(selectedDate)
    next.setMonth(next.getMonth() + delta)
    selectedDate = next
    listIndex = 0
  }

  // Both the grid click and the keyboard land here, so the "moving the day
  // resets the event cursor" rule lives in one place.
  function selectKey(key) {
    var parts = key.split("-")
    selectedDate = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    listIndex = 0
  }

  function toggleCalendar(name) {
    if (name === "") return
    var next = {}
    for (var key in hidden) next[key] = hidden[key]
    if (next[name]) delete next[name]
    else next[name] = true
    hidden = next
  }

  function goToday() {
    selectedDate = new Date()
    listIndex = 0
  }

  function moveList(delta) {
    if (dayEvents.length === 0) return
    listIndex = Math.max(0, Math.min(dayEvents.length - 1, listIndex + delta))
  }

  function moveIn(list, index, delta) {
    if (list.length === 0) return 0
    return Math.max(0, Math.min(list.length - 1, index + delta))
  }

  onCalendarIndexChanged: calendarList.positionViewAtIndex(calendarIndex, ListView.Contain)
  onFeedIndexChanged: feedList.positionViewAtIndex(feedIndex, ListView.Contain)
  onListIndexChanged: agendaList.positionViewAtIndex(listIndex, ListView.Contain)

  function startEdit() {
    if (!selectedEvent) return note("Nothing selected")
    if (!selectedEditable)
      return note("'" + selectedEvent.calendar + "' is readonly")
    form.load(selectedEvent)
    formMode = "edit"
  }

  function startNew() {
    if (!service || service.writableCalendars.length === 0)
      return note("No writable calendar")
    form.reset(service.writableCalendars[0].name, selectedKey)
    formMode = "new"
  }

  function askDelete() {
    if (!selectedEvent) return note("Nothing selected")
    if (!selectedEditable)
      return note("'" + selectedEvent.calendar + "' is readonly")
    pendingDelete = selectedEvent.uid
  }

  // One confirmation surface covers both kinds of removal, so the pending
  // target carries which kind it is rather than a second flag.
  function confirmDelete() {
    if (pendingDelete === "") return
    if (pendingDelete.indexOf("feed:") === 0)
      service.removeFeed(pendingDelete.substring(5))
    else
      service.deleteEvent(pendingDelete)
  }

  function submitForm() {
    if (!service) return
    if (formMode === "feed") {
      if (form.feedName.trim() === "" || form.feedUrl.trim() === "")
        return note("Name and URL are required")
      service.addFeed(form.feedName.trim(), form.feedUrl.trim(), "light blue")
      return
    }
    if (form.title.trim() === "") return note("Title is required")
    if (formMode === "new")
      service.createEvent(form.calendar, form.start, form.end, form.title,
        form.location, form.description, form.repeat.trim())
    else if (formMode === "edit")
      service.updateEvent(form.uid, {
        title: form.title, start: form.start, end: form.end,
        location: form.location, description: form.description
      })
  }

  // ---- keys

  function isModifierKey(key) {
    return key === Qt.Key_Control || key === Qt.Key_Shift
      || key === Qt.Key_Alt || key === Qt.Key_AltGr || key === Qt.Key_Meta
  }

  function noteHeldModifiers(event) {
    heldModifierFlags = event.modifiers
  }

  // Text typed into a form must never be read as a command, so the whole
  // shortcut table is skipped while an input has focus. Escape still gets
  // through — it is the way back out.
  function textInputFocused() {
    var item = panel.activeFocusItem
    return !!item && (item.hasOwnProperty("inputMethodComposing")
      || String(item.toString()).indexOf("TextField") >= 0
      || String(item.toString()).indexOf("TextInput") >= 0
      || String(item.toString()).indexOf("TextArea") >= 0)
  }

  function handleKey(event) {
    var text = String(event.text || "").toLowerCase()
    var plain = event.modifiers === Qt.NoModifier

    if (event.key === Qt.Key_Escape) {
      if (shortcutHintsActive) shortcutHintsActive = false
      else if (pendingDelete !== "") pendingDelete = ""
      else if (formMode !== "") formMode = ""
      else if (query !== "" || focusRegion === "search") {
        query = ""
        focusRegion = "grid"
        // The search box has to give focus up explicitly. It lives inside
        // the key scope, so asking the scope to take focus back just hands
        // it to the field again, and every key after Escape kept landing in
        // the box.
        searchField.focus = false
        keyScope.forceActiveFocus()
      }
      else close()
      return true
    }

    if (pendingDelete !== "") {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || text === "y") {
        confirmDelete()
        return true
      }
      return true
    }

    if (formMode !== "") {
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
          && (event.modifiers & Qt.ControlModifier)) {
        submitForm()
        return true
      }
      // Everything else belongs to the field that has focus, Tab included.
      return false
    }

    if (textInputFocused()) return false

    // ---- view switching, live everywhere
    if (text === "?") {
      shortcutHintsActive = !shortcutHintsActive
      return true
    }
    if (plain && text === "a") { view = "agenda"; return true }
    if (plain && text === "c") { view = "calendars"; return true }
    if (plain && text === "f") { view = "feeds"; return true }
    if (plain && text === "r") { refresh(); note("Refreshing"); return true }

    if (view === "calendars") return handleCalendarsKey(event, text, plain)
    if (view === "feeds") return handleFeedsKey(event, text, plain)
    return handleAgendaKey(event, text, plain)
  }

  function handleAgendaKey(event, text, plain) {
    if (plain && text === "/") {
      focusRegion = "search"
      Qt.callLater(function() { searchField.forceActiveFocus() })
      return true
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      focusRegion = focusRegion === "list" ? "grid" : "list"
      return true
    }
    if (plain && text === "n") { startNew(); return true }
    if (plain && text === "e") { startEdit(); return true }
    if (plain && text === "d") { askDelete(); return true }
    if (plain && text === "t") { goToday(); return true }
    if (plain && text === "[") { moveMonth(-1); return true }
    if (plain && text === "]") { moveMonth(1); return true }

    if (focusRegion === "list") {
      if (event.key === Qt.Key_Down || (plain && text === "j")) { moveList(1); return true }
      if (event.key === Qt.Key_Up || (plain && text === "k")) { moveList(-1); return true }
      if (event.key === Qt.Key_Home || (plain && text === "g")) { listIndex = 0; return true }
      if (event.key === Qt.Key_End || (event.modifiers & Qt.ShiftModifier && text === "g")) {
        listIndex = Math.max(0, dayEvents.length - 1)
        return true
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { startEdit(); return true }
      return false
    }

    if (event.key === Qt.Key_Left || (plain && text === "h")) { moveDay(-1); return true }
    if (event.key === Qt.Key_Right || (plain && text === "l")) { moveDay(1); return true }
    if (event.key === Qt.Key_Down || (plain && text === "j")) { moveDay(7); return true }
    if (event.key === Qt.Key_Up || (plain && text === "k")) { moveDay(-7); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      focusRegion = "list"
      return true
    }
    return false
  }

  function handleCalendarsKey(event, text, plain) {
    if (event.key === Qt.Key_Down || (plain && text === "j")) {
      calendarIndex = moveIn(calendars, calendarIndex, 1)
      return true
    }
    if (event.key === Qt.Key_Up || (plain && text === "k")) {
      calendarIndex = moveIn(calendars, calendarIndex, -1)
      return true
    }
    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
        || event.key === Qt.Key_Enter) {
      toggleCalendar(calendars[calendarIndex] ? calendars[calendarIndex].name : "")
      return true
    }
    return false
  }

  function handleFeedsKey(event, text, plain) {
    if (event.key === Qt.Key_Down || (plain && text === "j")) {
      feedIndex = moveIn(feeds, feedIndex, 1)
      return true
    }
    if (event.key === Qt.Key_Up || (plain && text === "k")) {
      feedIndex = moveIn(feeds, feedIndex, -1)
      return true
    }
    if (plain && text === "s") {
      var feed = feeds[feedIndex]
      if (!feed) return true
      // The helper takes the feed name, not the pair name it is listed under.
      service.syncFeed(String(feed.name).replace(/_pair$/, ""))
      note("Syncing " + feed.name)
      return true
    }
    if (text === "s" && (event.modifiers & Qt.ShiftModifier)) {
      service.syncFeed("")
      note("Syncing every feed")
      return true
    }
    if (plain && text === "n") { form.resetFeed(); formMode = "feed"; return true }
    if (plain && text === "d") {
      var target = feeds[feedIndex]
      if (target) pendingDelete = "feed:" + String(target.name).replace(/_pair$/, "")
      return true
    }
    return false
  }

  // ---- form state, kept flat so both the new and edit paths write the same
  //      fields and the submit branch is the only thing that differs.
  QtObject {
    id: form
    property string uid: ""
    property string calendar: ""
    property string title: ""
    property string start: ""
    property string end: ""
    property string location: ""
    property string description: ""
    property string repeat: ""
    property string feedName: ""
    property string feedUrl: ""

    function reset(calendarName, dayKey) {
      uid = ""
      calendar = calendarName
      title = ""
      start = dayKey + "T09:00"
      end = dayKey + "T10:00"
      location = ""
      description = ""
      repeat = ""
    }

    function load(event) {
      uid = event.uid
      calendar = event.calendar
      title = event.title
      start = Khal.isoDateTime(new Date(event.date.split("-")[0],
        Number(event.date.split("-")[1]) - 1, event.date.split("-")[2]), event.time)
      end = Khal.isoDateTime(new Date(event.endDate.split("-")[0],
        Number(event.endDate.split("-")[1]) - 1, event.endDate.split("-")[2]), event.endTime)
      location = event.location || ""
      description = event.description || ""
    }

    function resetFeed() {
      feedName = ""
      feedUrl = ""
    }
  }

  // ---- view
  //
  // A title row with the pages beside it, then the page itself: the calendars
  // are their own page rather than a permanent sidebar, because the window is
  // mostly used for one thing at a time and the agenda wants the width.

  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-almanac"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.cardBackground
      borderSpec: root.cardBorderSpec

      // Clicks inside the card must not reach the dismissal surface below it.
      MouseArea { anchors.fill: parent; onClicked: {} }

    FocusScope {
      id: keyScope
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        root.noteHeldModifiers(event)
        if (root.isModifierKey(event.key)) return
        if (root.handleKey(event)) event.accepted = true
      }

      Keys.onReleased: function(event) {
        root.noteHeldModifiers(event)
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(10)

        // ---- header
        Item {
          width: parent.width
          height: Style.space(28)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Almanac"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Row {
            anchors.centerIn: parent
            spacing: Style.space(14)

            Repeater {
              model: [
                { key: "agenda", label: "Agenda", hint: "a" },
                { key: "calendars", label: "Calendars", hint: "c" },
                { key: "feeds", label: "Feeds", hint: "f" }
              ]

              Text {
                required property var modelData
                text: modelData.label
                color: root.view === modelData.key ? root.accent : root.secondary
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: root.view === modelData.key

                KeyHint {
                  sequences: [modelData.hint]
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.view = modelData.key
                }
              }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // A full-range khal sweep takes a couple of seconds, which is
            // long enough that a stepped month looks broken unless the wait
            // is on screen.
            text: root.busy ? "working…" : (root.loading ? "loading…" : root.status)
            color: root.busy || root.loading ? root.accent : root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- agenda
        Row {
          width: parent.width
          height: parent.height - Style.space(70)
          visible: root.view === "agenda"
          spacing: Style.space(16)

          Column {
            id: gridColumn
            width: Math.round(parent.width * 0.46)
            spacing: Style.space(8)

            // Cells are sized from the column so the grid fills it: a fixed
            // Style.space() width overflowed into the agenda on one display
            // and left the grid small on another.
            readonly property int gap: Style.space(2)
            readonly property int cell: Math.floor((width - 6 * gap) / 7)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: Qt.locale().monthName(root.viewMonth, Locale.LongFormat).toUpperCase()
                  + " " + root.viewYear
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Repeater {
                model: [{ glyph: "‹", step: -1 }, { glyph: "›", step: 1 }]

                Text {
                  required property var modelData
                  text: modelData.glyph
                  color: root.secondary
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body

                  KeyHint {
                    sequences: [modelData.step < 0 ? "[" : "]"]
                    showWash: false
                  }

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.moveMonth(modelData.step)
                  }
                }
              }
            }

            Grid {
              columns: 7
              spacing: gridColumn.gap

              Repeater {
                model: root.weekdays

                Text {
                  required property var modelData
                  width: gridColumn.cell
                  horizontalAlignment: Text.AlignHCenter
                  text: Qt.locale().dayName(modelData, Locale.ShortFormat).toUpperCase()
                  color: root.secondary
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Repeater {
              model: root.weeks

              Grid {
                required property var modelData
                columns: 7
                spacing: gridColumn.gap

                Repeater {
                  model: modelData.days

                  Rectangle {
                    required property var modelData
                    readonly property bool isSelected: modelData.key === root.selectedKey
                    readonly property var cellEvents: root.visibleEvents(
                      (root.service ? root.service.eventsByDay[modelData.key] : null) || [])

                    width: gridColumn.cell
                    height: Math.round(gridColumn.cell * 0.86)
                    radius: Style.cornerRadius
                    color: isSelected
                      ? Util.alpha(root.accent, 0.22)
                      : (modelData.key === root.todayKey
                        ? Util.alpha(root.foreground, 0.08) : "transparent")

                    Column {
                      anchors.centerIn: parent
                      spacing: Style.space(1)

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.day
                        color: modelData.inMonth ? root.foreground : root.secondary
                        font.family: Style.font.family
                        font.pixelSize: Style.font.subtitle
                      }

                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(2)

                        Repeater {
                          // Capped at three: past that the count stops being
                          // readable at a glance and the dots become a smear.
                          model: Math.min(3, parent.parent.parent.cellEvents.length)

                          Rectangle {
                            width: Style.space(3)
                            height: width
                            radius: width / 2
                            color: parent.parent.parent.isSelected
                              ? root.accent : root.secondary
                          }
                        }
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.selectKey(modelData.key)
                        root.focusRegion = "grid"
                      }
                    }
                  }
                }
              }
            }

          }

          Column {
            width: parent.width - gridColumn.width - Style.space(16)
            height: parent.height
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "/  search the loaded range"
              text: root.query
              onTextChanged: root.query = text
              Keys.onEscapePressed: {
                text = ""
                root.focusRegion = "grid"
                focus = false
                keyScope.forceActiveFocus()
              }

              KeyHint { sequences: ["/"] }
            }

            Text {
              text: root.query.trim() !== ""
                ? root.dayEvents.length + " MATCHING"
                : Qt.formatDate(root.selectedDate, "dddd, d MMMM").toUpperCase()
              color: root.secondary
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            ListView {
              id: agendaList
              width: parent.width
              height: parent.height - Style.space(46)
              clip: true
              model: root.dayEvents
              currentIndex: root.listIndex

              delegate: EventRow {
                required property var modelData
                required property int index
                width: agendaList.width
                event: modelData
                selected: index === root.listIndex && root.focusRegion === "list"
                readOnly: {
                  var calendar = root.calendarNamed(modelData.calendar)
                  return !calendar || calendar.readonly
                }
                foreground: root.foreground
                accent: root.accent
                onActivated: {
                  root.listIndex = index
                  root.focusRegion = "list"
                }
              }

              Text {
                anchors.centerIn: parent
                visible: agendaList.count === 0
                text: "No events"
                color: root.secondary
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              KeyHint {
                navHint: root.focusRegion === "list" ? "j k" : ""
                sequences: root.focusRegion === "list"
                  ? ["Enter", "d"] : ["Tab", "n"]
              }
            }

          }
        }

        // ---- calendars
        Column {
          width: parent.width
          height: parent.height - Style.space(70)
          visible: root.view === "calendars"
          spacing: Style.space(8)

          Text {
            text: "Space hides a calendar from the agenda. It keeps syncing."
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          ListView {
            id: calendarList
            width: parent.width
            height: parent.height - Style.space(30)
            clip: true
            model: root.calendars
            currentIndex: root.calendarIndex

            KeyHint {
              navHint: "j k"
              sequences: ["Space"]
            }

            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool shown: !root.hidden[modelData.name]

              width: calendarList.width
              height: Style.space(30)
              color: index === root.calendarIndex
                ? Util.alpha(root.foreground, 0.10) : "transparent"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                // A hollow dot reads as "off" where a greyed label would
                // just read as a different calendar.
                text: (parent.shown ? "●  " : "○  ") + modelData.name
                textFormat: Text.PlainText
                color: parent.shown ? root.foreground : root.secondary
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.readonly ? "readonly" : "writable"
                color: root.secondary
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.calendarIndex = index
                  root.toggleCalendar(modelData.name)
                }
              }
            }
          }
        }

        // ---- feeds
        Column {
          width: parent.width
          height: parent.height - Style.space(70)
          visible: root.view === "feeds"
          spacing: Style.space(8)

          ListView {
            id: feedList
            width: parent.width
            height: parent.height - Style.space(30)
            clip: true
            model: root.feeds
            currentIndex: root.feedIndex

            KeyHint {
              navHint: "j k"
              sequences: ["n", "s", "d"]
            }

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: feedList.width
              height: Style.space(40)
              color: index === root.feedIndex
                ? Util.alpha(root.foreground, 0.10) : "transparent"

              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: modelData.calendar
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: modelData.url
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.feedIndex = index
              }
            }
          }
        }

        // ---- keys, for wherever the cursor is
        Text {
          width: parent.width
          text: root.hintLine
          color: root.secondary
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

      }

      // ---- event form
      Rectangle {
        anchors.fill: parent
        visible: root.formMode === "new" || root.formMode === "edit"
        color: Util.alpha(Color.background, 0.96)

        Column {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(80), Style.space(300))
          spacing: Style.space(6)

          Text {
            text: root.formMode === "new" ? "NEW EVENT" : "EDIT EVENT"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: form.calendar
            textFormat: Text.PlainText
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // Tab walks the fields explicitly. QML gives a bare column of
          // TextFields no tab order, so without this the form could only be
          // filled with the mouse.
          TextField {
            id: titleField
            width: parent.width
            placeholderText: "Title"
            text: form.title
            onTextChanged: form.title = text
            KeyNavigation.tab: startField
          }

          TextField {
            id: startField
            width: parent.width
            // Dropping the time makes it an all-day event, which is what khal
            // does with a bare date on both ends.
            placeholderText: "Start — yyyy-mm-dd, or yyyy-mm-ddTHH:MM"
            text: form.start
            onTextChanged: form.start = text
            KeyNavigation.tab: endField
          }

          TextField {
            id: endField
            width: parent.width
            placeholderText: "End"
            text: form.end
            onTextChanged: form.end = text
            KeyNavigation.tab: locationField
          }

          TextField {
            id: locationField
            width: parent.width
            placeholderText: "Location"
            text: form.location
            onTextChanged: form.location = text
            KeyNavigation.tab: descriptionField
          }

          TextField {
            id: descriptionField
            width: parent.width
            placeholderText: "Description"
            text: form.description
            onTextChanged: form.description = text
            KeyNavigation.tab: repeatField
          }

          TextField {
            id: repeatField
            width: parent.width
            visible: root.formMode === "new"
            placeholderText: "Repeat — daily, weekly, monthly, yearly"
            text: form.repeat
            onTextChanged: form.repeat = text
            KeyNavigation.tab: titleField
          }

          Text {
            text: "Tab  next field     Ctrl+Enter  save     Esc  cancel"
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        onVisibleChanged: if (visible) Qt.callLater(function() { titleField.forceActiveFocus() })
      }

      // ---- feed form
      Rectangle {
        anchors.fill: parent
        visible: root.formMode === "feed"
        color: Util.alpha(Color.background, 0.96)

        Column {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(80), Style.space(300))
          spacing: Style.space(6)

          Text {
            text: "ADD FEED"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: "Writes a vdirsyncer pair and the matching khal calendar."
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: feedNameField
            width: parent.width
            placeholderText: "Calendar name — e.g. sports_f1"
            text: form.feedName
            onTextChanged: form.feedName = text
            KeyNavigation.tab: feedUrlField
          }

          TextField {
            id: feedUrlField
            width: parent.width
            placeholderText: "https://…/calendar.ics"
            text: form.feedUrl
            onTextChanged: form.feedUrl = text
            KeyNavigation.tab: feedNameField
          }

          Text {
            text: "Tab  next field     Ctrl+Enter  add     Esc  cancel"
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        onVisibleChanged: if (visible) Qt.callLater(function() { feedNameField.forceActiveFocus() })
      }

      // ---- delete confirmation
      Rectangle {
        anchors.fill: parent
        visible: root.pendingDelete !== ""
        color: Util.alpha(Color.background, 0.96)

        Column {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: root.pendingDelete.indexOf("feed:") === 0
              ? "Remove feed '" + root.pendingDelete.substring(5) + "'?"
              : "Delete '" + (root.selectedEvent ? root.selectedEvent.title : "") + "'?"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            text: root.pendingDelete.indexOf("feed:") === 0
              ? "It stops syncing. The events already downloaded stay on disk."
              : "The .ics file is removed. This cannot be undone."
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "y / Enter  confirm     Esc  cancel"
            color: root.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
    }
  }
}
