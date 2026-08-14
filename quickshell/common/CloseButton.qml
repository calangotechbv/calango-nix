import QtQuick

// Shared panel close affordance.
//
// Replaces a bare "✕" Text whose MouseArea filled only the glyph itself: a
// ~13px target with no hover state, so nothing indicated it was clickable and
// it was easy to miss. This is a proper circular target with feedback on both
// hover and press.
//
// Deliberately neutral rather than red on hover -- red reads as destructive,
// and this only dismisses a panel. That matches how Adwaita styles dialog
// close buttons.
Rectangle {
  id: root

  property var theme
  property string font: "AdwaitaMono Nerd Font"
  property real size: 26
  property string tooltip: "Close"

  signal clicked()

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size
  radius: size / 2

  // Guarded: the bindings below evaluate during construction, which can happen
  // before the parent has assigned `theme`.
  color: !theme               ? "transparent"
       : hoverArea.pressed    ? theme.bgSelected
       : hoverArea.containsMouse ? theme.bgSurface
       : "transparent"

  Accessible.role: Accessible.Button
  Accessible.name: root.tooltip
  Accessible.onPressAction: root.clicked()

  Behavior on color { ColorAnimation { duration: 120 } }

  scale: hoverArea.pressed ? 0.9 : 1.0
  Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

  // Icon carries its own colour transition, so the Behavior that used to live
  // here moved with it.
  Icon {
    anchors.centerIn: parent
    name: "close"
    color: !root.theme                  ? "#c0caf5"
         : hoverArea.containsMouse      ? root.theme.textPrimary
         : root.theme.textMuted
    size: Math.round(root.size * 0.5)
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
