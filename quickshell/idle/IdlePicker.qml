pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// How long to stay awake for. Opens from the bar pill; the state it writes
// lives in IdleService, which is also where the IPC surface is.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property int selectedIndex: 0

  // Minutes, or 0 for indefinite. Six is what fits on one row at a readable
  // size, and covers a call at one end and an evening at the other.
  readonly property var options: [
    { minutes: 15,  label: "15m",  hint: "a call" },
    { minutes: 30,  label: "30m",  hint: "a meeting" },
    { minutes: 60,  label: "1h",   hint: "an episode" },
    { minutes: 120, label: "2h",   hint: "a film" },
    { minutes: 240, label: "4h",   hint: "an evening" },
    { minutes: 0,   label: "∞",    hint: "until stopped" }
  ]

  // The default the pill and `qs ipc call idle toggle` use, marked in the grid
  // so the picker doubles as a readout of what the quick path does.
  readonly property int defaultIndex:
    root.options.findIndex(o => o.minutes === IdleService.limitMinutes)

  // Which option is currently held, so re-opening the picker lands on it.
  // Matches on the duration asked for, which the service records, rather than
  // on what is left of it.
  readonly property int activeIndex:
    IdleService.inhibited
      ? root.options.findIndex(o => o.minutes === IdleService.requestedMinutes)
      : -1

  function close() { IdleService.closePicker(); }

  function apply(i) {
    const option = root.options[Number(i)];
    if (!option) return;
    IdleService.inhibit(option.minutes);
    root.close();
  }

  function stop() {
    IdleService.release();
    root.close();
  }

  function move(delta) {
    const n = root.options.length;
    root.selectedIndex = (root.selectedIndex + delta + n) % n;
  }

  // The pill opens the picker through IdleService, so pick the selection up
  // here rather than making the bar reach into this file.
  Connections {
    target: IdleService
    function onPickerOpenChanged() {
      if (!IdleService.pickerOpen) return;
      root.selectedIndex = root.activeIndex >= 0 ? root.activeIndex
                         : root.defaultIndex >= 0 ? root.defaultIndex : 0;
    }
  }

  Scrim { active: overlay.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: overlay
    visible: IdleService.pickerOpen
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-idle"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      width: menuColumn.implicitWidth + 48
      height: menuColumn.implicitHeight + 40
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1
      focus: true

      Keys.onEscapePressed: root.close()

      Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
          event.accepted = true; root.move(-1);
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
          event.accepted = true; root.move(1);
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          event.accepted = true; root.apply(root.selectedIndex);
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
          // Pick and commit in one press. Nothing here is destructive and the
          // worst case is a duration you change with another keypress.
          event.accepted = true;
          root.apply(event.key - Qt.Key_1);
        } else if (event.key === Qt.Key_0 || event.key === Qt.Key_Backspace
                   || event.key === Qt.Key_Delete) {
          event.accepted = true;
          if (IdleService.inhibited) root.stop(); else root.close();
        }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: event => event.accepted = true
      }

      ColumnLayout {
        id: menuColumn
        anchors.centerIn: parent
        spacing: 14

        Text {
          Layout.alignment: Qt.AlignHCenter
          text: IdleService.inhibited
                ? "staying awake  ·  " + IdleService.remainingLabel + " left"
                : "stay awake for"
          color: IdleService.inhibited ? root.theme.accentOrange : root.theme.textSecondary
          font { pixelSize: 11; family: root.font }
        }

        RowLayout {
          Layout.alignment: Qt.AlignHCenter
          spacing: 12

          Repeater {
            model: root.options

            Rectangle {
              id: tile
              required property var modelData
              required property int index

              readonly property bool isSelected: root.selectedIndex === index
              readonly property bool isActive: root.activeIndex === index

              implicitWidth: 92
              implicitHeight: 92
              radius: 12
              color: isSelected ? root.theme.bgSelected
                   : tileHover.containsMouse ? root.theme.bgHover
                   : root.theme.bgSurface

              border.width: (isSelected || isActive) ? 1 : 0
              border.color: isSelected ? root.theme.accentPrimary : root.theme.bgBorder

              Behavior on color { ColorAnimation { duration: 120 } }

              Accessible.role: Accessible.Button
              Accessible.name: tile.isActive
                               ? tile.modelData.hint + ", currently held"
                               : "Stay awake for " + tile.modelData.hint

              ColumnLayout {
                anchors.centerIn: parent
                spacing: 6

                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: tile.modelData.label
                  color: tile.isSelected ? root.theme.textPrimary : root.theme.textSecondary
                  font {
                    pixelSize: tile.modelData.minutes === 0 ? 26 : 20
                    bold: tile.isSelected
                    family: root.font
                  }
                }

                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: tile.isActive ? "held" : tile.modelData.hint
                  color: tile.isActive ? root.theme.accentGreen : root.theme.textMuted
                  font { pixelSize: 9; family: root.font }
                }
              }

              MouseArea {
                id: tileHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = tile.index
                onClicked: root.apply(tile.index)
              }
            }
          }
        }

        // Only there when there is something to stop, so the picker is one row
        // of choices in the common case.
        Rectangle {
          Layout.alignment: Qt.AlignHCenter
          Layout.fillWidth: true
          visible: IdleService.inhibited
          implicitHeight: 30
          radius: 8
          color: stopHover.containsMouse ? root.theme.bgHover : root.theme.bgSurface

          Accessible.role: Accessible.Button
          Accessible.name: "Stop staying awake"

          Row {
            anchors.centerIn: parent
            spacing: 6

            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: "stop"
              color: stopHover.containsMouse ? root.theme.accentRed : root.theme.textSecondary
              size: 11
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "let it lock again"
              color: stopHover.containsMouse ? root.theme.accentRed : root.theme.textSecondary
              font { pixelSize: 11; family: root.font }
            }
          }

          MouseArea {
            id: stopHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.stop()
          }
        }

        Text {
          Layout.alignment: Qt.AlignHCenter
          text: IdleService.inhibited
                ? "←→ to choose  ·  1-6 to jump  ·  0 to stop  ·  esc to cancel"
                : "←→ to choose  ·  1-6 to jump  ·  enter to apply  ·  esc to cancel"
          color: root.theme.textMuted
          font { pixelSize: 10; family: root.font }
        }
      }
    }
  }
}
