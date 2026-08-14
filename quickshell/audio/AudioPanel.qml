import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// Output/input device picker, plus a row per application currently holding the
// device. Clicking a device row makes it the PipeWire default; the slider on a
// device row sets the device volume, the slider on an app row sets that app's
// own, and the two multiply the way they do in pavucontrol.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false

  function toggle() { isOpen ? close() : open(); }
  function open()   { isOpen = true; }
  function close()  { isOpen = false; }

  IpcHandler {
    target: "audio"
    function toggle(): void { root.toggle(); }
    function open(): void   { root.open(); }
    function close(): void  { root.close(); }
  }

  Scrim { active: overlay.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: overlay
    visible: root.isOpen
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-audio"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      width: 460
      // Fixed, not derived from the content. Sizing this to contentCol's implicit
      // height while the Flickable inside uses Layout.fillHeight is circular, and
      // QML resolves that by collapsing the list to zero height -- silently, with
      // no binding-loop warning.
      height: 560
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1
      focus: true
      Keys.onEscapePressed: root.close()

      MouseArea {
        anchors.fill: parent
        onClicked: event => event.accepted = true
      }

      ColumnLayout {
        id: contentCol
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: 10

          Icon {
            name: AudioService.outputIcon
            color: AudioService.muted ? root.theme.textMuted : root.theme.accentGreen
            size: 18
          }

          ColumnLayout {
            spacing: 0
            Text {
              text: "Audio"
              color: root.theme.textPrimary
              font { pixelSize: 13; bold: true; family: root.font }
            }
            Text {
              text: AudioService.ready
                    ? AudioService.outputLabel + "  ·  " + AudioService.inputLabel
                    : "PipeWire unavailable"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
              elide: Text.ElideRight
              Layout.maximumWidth: 330
            }
          }

          Item { Layout.fillWidth: true }

          CloseButton {
            theme: root.theme
            font: root.font
            onClicked: root.close()
          }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.theme.bgBorder }

        Flickable {
          id: scroller
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: sections.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: sections
            // Bound to the Flickable, not to `parent`: a Flickable's children are
            // reparented into contentItem, whose width is 0 until contentWidth is
            // set, so `parent.width` here yields zero-width rows.
            width: scroller.width
            spacing: 12

            DeviceSection {
              Layout.fillWidth: true
              theme: root.theme
              font: root.font
              title: "Output"
              emptyText: "No output devices"
              devices: AudioService.sinks
              isActive: node => AudioService.isDefaultSink(node)
              onSelect: node => AudioService.selectSink(node)
            }

            // Sits under Output rather than at the bottom of the panel: these
            // are the streams feeding the device above, and that is the pairing
            // you reach for when one app is drowning out another.
            StreamSection {
              Layout.fillWidth: true
              theme: root.theme
              font: root.font
              title: "Playing"
              streams: AudioService.playbackStreams
            }

            DeviceSection {
              Layout.fillWidth: true
              theme: root.theme
              font: root.font
              title: "Input"
              emptyText: "No input devices"
              devices: AudioService.sources
              isActive: node => AudioService.isDefaultSource(node)
              onSelect: node => AudioService.selectSource(node)
            }

            StreamSection {
              Layout.fillWidth: true
              theme: root.theme
              font: root.font
              title: "Recording"
              fallbackIcon: "microphone"
              streams: AudioService.recordStreams
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            // Stream counts only when there are any, so the line does not carry
            // two permanent zeroes on an idle machine.
            text: {
              const parts = [AudioService.sinks.length + " out",
                             AudioService.sources.length + " in"];
              if (AudioService.playbackStreams.length > 0)
                parts.push(AudioService.playbackStreams.length + " playing");
              if (AudioService.recordStreams.length > 0)
                parts.push(AudioService.recordStreams.length + " recording");
              return parts.join("  ·  ");
            }
            color: root.theme.textMuted
            font { pixelSize: 10; family: root.font }
          }
          Item { Layout.fillWidth: true }
          Text {
            text: "esc to close"
            color: root.theme.textMuted
            font { pixelSize: 10; family: root.font }
          }
        }
      }
    }
  }
}
