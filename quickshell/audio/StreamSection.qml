pragma ComponentBehavior: Bound
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts
import "../common"

// One titled group of application streams (Playback or Recording). Unlike
// DeviceSection there is nothing to pick: where a stream is routed is
// PipeWire's business, and all a row does is set that one app's own volume,
// independently of the device volume above it.
ColumnLayout {
  id: section

  property var theme
  property string font: "AdwaitaMono Nerd Font"
  property string title: ""
  property var streams: []

  // Drawn when the app has no resolvable icon.
  property string fallbackIcon: "music"

  // No empty state, unlike DeviceSection: devices are a fixed set worth telling
  // you is empty, whereas streams are transient, and a permanent "nothing is
  // playing" row would sit between the device lists most of the time.
  visible: section.streams.length > 0

  spacing: 6

  Text {
    text: section.title
    color: section.theme.textMuted
    font { pixelSize: 10; family: section.font }
  }

  Repeater {
    model: section.streams

    delegate: Rectangle {
      id: row
      required property var modelData

      readonly property string subtitle: AudioService.streamTitle(modelData)
      readonly property bool muted: AudioService.mutedOf(modelData)

      Layout.fillWidth: true
      // Content-derived, because the subtitle line is only there for apps that
      // publish a media.name.
      implicitHeight: rowCol.implicitHeight + 20
      radius: 8
      color: section.theme.bgSurface

      ColumnLayout {
        id: rowCol
        anchors { fill: parent; margins: 10 }
        spacing: 6

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Item {
            implicitWidth: 18
            implicitHeight: 18
            Layout.alignment: Qt.AlignVCenter

            IconImage {
              id: appIcon
              anchors.fill: parent
              source: AudioService.streamIcon(row.modelData)
              visible: status === Image.Ready
            }

            Icon {
              anchors.centerIn: parent
              visible: !appIcon.visible
              name: section.fallbackIcon
              color: section.theme.accentPrimary
              size: 13
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              Layout.fillWidth: true
              text: AudioService.streamApp(row.modelData)
              color: section.theme.textPrimary
              font { pixelSize: 12; family: section.font }
              elide: Text.ElideRight
            }

            Text {
              Layout.fillWidth: true
              visible: row.subtitle !== ""
              text: row.subtitle
              color: section.theme.textMuted
              font { pixelSize: 10; family: section.font }
              elide: Text.ElideRight
            }
          }

          Text {
            text: Math.round(AudioService.volumeOf(row.modelData) * 100) + "%"
            color: section.theme.textMuted
            font { pixelSize: 10; family: section.font }
          }

          Icon {
            name: row.muted ? "volume-mute" : "volume-high"
            color: row.muted ? section.theme.accentRed : section.theme.textSecondary
            size: 13
            MouseArea {
              anchors.fill: parent
              anchors.margins: -4
              cursorShape: Qt.PointingHandCursor
              onClicked: AudioService.toggleMute(row.modelData)
            }
          }
        }

        VolumeSlider {
          Layout.fillWidth: true
          theme: section.theme
          value: AudioService.volumeOf(row.modelData)
          fillColor: row.muted ? section.theme.textMuted : section.theme.accentCyan
          onMoved: v => AudioService.setVolume(row.modelData, v)
        }
      }
    }
  }
}
