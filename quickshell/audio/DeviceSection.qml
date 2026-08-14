pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../common"

// One titled group of devices (Output or Input). Clicking a row makes it the
// default; the slider sets that device's volume independently of which one is
// currently default.
ColumnLayout {
  id: section

  property var theme
  property string font: "AdwaitaMono Nerd Font"
  property string title: ""
  property string emptyText: "No devices"
  property var devices: []

  // Predicate rather than a plain bool so the same component serves sinks and
  // sources without knowing which it is holding.
  property var isActive: node => false

  signal select(var node)

  spacing: 6

  Text {
    text: section.title
    color: section.theme.textMuted
    font { pixelSize: 10; family: section.font }
  }

  Text {
    visible: section.devices.length === 0
    text: section.emptyText
    color: section.theme.textMuted
    font { pixelSize: 11; family: section.font }
  }

  Repeater {
    model: section.devices

    delegate: Rectangle {
      id: row
      required property var modelData
      readonly property bool active: section.isActive(modelData)

      Layout.fillWidth: true
      implicitHeight: 60
      radius: 8
      color: active ? section.theme.bgSelected
           : rowHover.containsMouse ? section.theme.bgHover
           : section.theme.bgSurface

      // Sits behind the mute button and slider so those take their own clicks.
      MouseArea {
        id: rowHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: section.select(row.modelData)
      }

      ColumnLayout {
        anchors { fill: parent; margins: 10 }
        spacing: 6

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Icon {
            name: row.active ? "check" : "checkbox-blank-circle-outline"
            color: row.active ? section.theme.accentGreen : section.theme.textMuted
            size: 12
          }

          Text {
            Layout.fillWidth: true
            text: AudioService.shortLabel(row.modelData)
            color: section.theme.textPrimary
            font { pixelSize: 12; bold: row.active; family: section.font }
            elide: Text.ElideRight
          }

          Text {
            text: Math.round(AudioService.volumeOf(row.modelData) * 100) + "%"
            color: section.theme.textMuted
            font { pixelSize: 10; family: section.font }
          }

          Icon {
            name: AudioService.mutedOf(row.modelData) ? "volume-mute" : "volume-high"
            color: AudioService.mutedOf(row.modelData)
                   ? section.theme.accentRed : section.theme.textSecondary
            size: 13
            MouseArea {
              anchors.fill: parent
              anchors.margins: -4
              cursorShape: Qt.PointingHandCursor
              onClicked: AudioService.toggleMute(row.modelData)
            }
          }
        }

        // The active device's slider is green to match its checkmark, so the
        // default is identifiable without reading the rows.
        VolumeSlider {
          Layout.fillWidth: true
          theme: section.theme
          value: AudioService.volumeOf(row.modelData)
          fillColor: AudioService.mutedOf(row.modelData)
                     ? section.theme.textMuted
                     : (row.active ? section.theme.accentGreen : section.theme.accentPrimary)
          onMoved: v => AudioService.setVolume(row.modelData, v)
        }
      }
    }
  }
}
