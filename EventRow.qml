import QtQuick
import qs.Commons

import "Khal.js" as Khal

// One event in a list, shared by the agenda and the search results so both
// stay identical. One hue at two opacities, matching the rest of the shell:
// the calendar's own colour is carried by a dot rather than by tinting text.
Rectangle {
  id: root

  property var event: null
  property bool selected: false
  property bool readOnly: false
  property color foreground: Color.foreground
  property color accent: Color.accent

  readonly property color secondary: Util.alpha(foreground, 0.55)
  readonly property string timeText: Khal.timeLabel(event)

  signal activated()

  height: Style.space(38)
  color: selected
    ? Util.alpha(foreground, 0.10)
    : (mouse.containsMouse ? Util.alpha(foreground, 0.06) : "transparent")

  Text {
    id: timeLabel
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(30)
    text: root.timeText
    color: root.secondary
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Column {
    anchors.left: timeLabel.right
    anchors.leftMargin: Style.space(8)
    anchors.right: calendarLabel.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(1)

    Text {
      width: parent.width
      text: root.event ? root.event.title : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: root.event && root.event.location ? root.event.location : ""
      textFormat: Text.PlainText
      color: root.secondary
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    id: calendarLabel
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    // Capped so a long calendar name cannot eat the title beside it.
    width: Math.min(implicitWidth, Math.round(root.width * 0.34))
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    // A readonly calendar is marked here rather than by grey text, so the
    // reason an event refuses to be edited is legible before the attempt.
    text: (root.event ? root.event.calendar : "") + (root.readOnly ? " ·" : "")
    color: root.secondary
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true
    onClicked: root.activated()
  }
}
