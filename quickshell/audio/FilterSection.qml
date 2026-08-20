pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../common"

// The noise-canceling source, shown as what it is rather than as a device you
// pick.
//
// It is deliberately NOT in the Input list above, and this section exists
// because of that absence. The filter FOLLOWS the default input, so making it
// the default leaves WirePlumber deciding which microphone feeds it. Keeping it
// out of that list means the list IS the choice of what gets noise-cancelled,
// and PipeWire persists that choice by itself.
//
// So the row does not select. It reports: which microphone is feeding the
// filter right now, read from the live graph, and the reminder that this is a
// source you choose inside an application rather than here. The volume slider
// is real -- the filtered source has its own volume like any other device.
//
// Not built on DeviceSection: that component is shared with Output, and
// teaching it a non-selectable row would push this feature's concerns into code
// that has nothing to do with it.
ColumnLayout {
  id: section

  property var theme
  property string font: "AdwaitaMono Nerd Font"
  property string title: "Noise cancellation"

  // The filtered source node, or null when filter-chain.service is not running.
  property var node: null

  // The microphone currently feeding it, and a label for it.
  property var from: null
  property string fromLabel: ""

  // True when something outside this panel made the filter the default input.
  property bool isDefault: false

  spacing: 6

  Text {
    text: section.title
    color: section.theme.textMuted
    font { pixelSize: 10; family: section.font }
  }

  // Absence is a real state and gets a real message: the unit carries no
  // `nofail`, so a graph that will not load leaves the service failed and this
  // node simply gone. Saying so beats an empty gap.
  Text {
    visible: !section.node
    text: "Not running -- check filter-chain.service"
    color: section.theme.textMuted
    font { pixelSize: 11; family: section.font }
  }

  Rectangle {
    visible: !!section.node
    Layout.fillWidth: true
    implicitHeight: 82
    radius: 8
    color: section.theme.bgSurface

    ColumnLayout {
      anchors { fill: parent; margins: 10 }
      spacing: 4

      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Icon {
          name: "microphone"
          color: section.from ? section.theme.accentPrimary : section.theme.textMuted
          size: 12
        }

        Text {
          Layout.fillWidth: true
          text: section.node ? AudioService.shortLabel(section.node) : ""
          color: section.theme.textPrimary
          font { pixelSize: 12; family: section.font }
          elide: Text.ElideRight
        }

        Text {
          text: Math.round(AudioService.volumeOf(section.node) * 100) + "%"
          color: section.theme.textMuted
          font { pixelSize: 10; family: section.font }
        }

        Icon {
          name: AudioService.mutedOf(section.node) ? "volume-mute" : "volume-high"
          color: AudioService.mutedOf(section.node)
                 ? section.theme.accentRed : section.theme.textSecondary
          size: 13
          MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: AudioService.toggleMute(section.node)
          }
        }
      }

      // Which microphone is actually feeding it. Read from the graph, not from
      // the default input, because the two can differ -- and when they differ,
      // this is the one that is true.
      Text {
        Layout.fillWidth: true
        text: "from " + section.fromLabel
        color: section.from ? section.theme.textSecondary : section.theme.accentOrange
        font { pixelSize: 10; family: section.font }
        elide: Text.ElideRight
      }

      // Two different sentences, because two different situations. Normally
      // this is a per-application choice. When the filter has been made the
      // default from outside this panel, the Input list above shows no active
      // row at all, which reads as a bug -- so say what happened instead.
      Text {
        Layout.fillWidth: true
        text: section.isDefault
              ? "Currently the default input, so the list above shows none selected"
              : "Select it as the microphone inside your app"
        color: section.isDefault ? section.theme.accentOrange : section.theme.textMuted
        font { pixelSize: 10; family: section.font }
        elide: Text.ElideRight
      }

      VolumeSlider {
        Layout.fillWidth: true
        theme: section.theme
        value: AudioService.volumeOf(section.node)
        fillColor: AudioService.mutedOf(section.node)
                   ? section.theme.textMuted : section.theme.accentPrimary
        onMoved: v => AudioService.setVolume(section.node, v)
      }
    }
  }
}
