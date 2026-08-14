import QtQuick

// The volume track shared by the device and stream rows. Hand-rolled rather
// than QtQuick.Controls' Slider to match the rest of this config, which pulls
// in no Controls dependency.
Rectangle {
  id: track

  property var theme
  property real value: 0
  property color fillColor: track.theme.accentPrimary

  // Emitted continuously through a drag, not on release: the point of a volume
  // slider is hearing where you are as you move it.
  signal moved(real value)

  implicitHeight: 6
  radius: height / 2
  color: track.theme.bgBase

  Rectangle {
    width: Math.max(0, Math.min(1, track.value)) * track.width
    height: parent.height
    radius: parent.radius
    color: track.fillColor
  }

  MouseArea {
    anchors.fill: parent
    // Generous vertical target; a 6px-tall strip is unusable with a mouse.
    anchors.topMargin: -8
    anchors.bottomMargin: -8
    cursorShape: Qt.PointingHandCursor
    preventStealing: true

    function apply(x) { track.moved(x / track.width); }

    onPressed: mouse => apply(mouse.x)
    onPositionChanged: mouse => { if (pressed) apply(mouse.x); }
  }
}
