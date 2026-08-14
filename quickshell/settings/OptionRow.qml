pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// A labelled row of chips, one of which is current: the Appearance tab is
// nothing but these. Extracted at the fourth copy.
//
// Options carry their own display text rather than being formatted here, so a
// row of percentages and a row of on/off use the same component.
RowLayout {
  id: row

  required property var theme
  required property string font

  property string label: ""
  property var options: []      // [{ value: <anything>, label: "…" }]
  property var current: null    // whichever value is selected now

  signal picked(var value)

  Layout.fillWidth: true
  spacing: 8

  Text {
    Layout.preferredWidth: 70
    text: row.label
    color: row.theme.textMuted
    font { pixelSize: 10; family: row.font }
  }

  Repeater {
    model: row.options

    Rectangle {
      id: chip
      required property var modelData

      // Numbers compared with a tolerance: these are alphas that made a round
      // trip through a text file, so 0.5 is not always exactly 0.5.
      readonly property bool selected:
        (typeof chip.modelData.value === "number" && typeof row.current === "number")
        ? Math.abs(chip.modelData.value - row.current) < 0.01
        : chip.modelData.value === row.current

      implicitWidth: Math.max(44, chipText.implicitWidth + 20)
      implicitHeight: 26
      radius: 6
      color: chip.selected ? row.theme.accentPrimary
           : chipHover.containsMouse ? row.theme.bgHover
           : row.theme.bgSurface
      border.color: row.theme.bgBorder
      border.width: 1

      Accessible.role: Accessible.RadioButton
      Accessible.name: row.label + " " + chip.modelData.label

      Text {
        id: chipText
        anchors.centerIn: parent
        text: chip.modelData.label
        color: chip.selected ? row.theme.bgBase : row.theme.textPrimary
        font { pixelSize: 10; family: row.font }
      }

      MouseArea {
        id: chipHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.picked(chip.modelData.value)
      }
    }
  }

  Item { Layout.fillWidth: true }
}
