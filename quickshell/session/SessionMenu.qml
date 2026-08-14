pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// Stands between SUPER+M and the end of your session. That key used to run
// `hyprctl dispatch exit` directly -- one keystroke, no confirmation, every
// unsaved buffer gone.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false
  property int selectedIndex: 0

  // Which entry is armed and waiting for a second press. -1 is none. Only the
  // destructive entries ever land here.
  property int armedIndex: -1

  readonly property var actions: [
    {
      key: "lock", label: "Lock", icon: "lock", destructive: false,
      // Via loginctl rather than calling hyprlock directly, so this takes the
      // same path as an idle lock: logind emits Lock, hypridle answers it with
      // its lock_cmd. Calling hyprlock here instead would work but would leave
      // two ways to lock that could drift apart.
      cmd: ["loginctl", "lock-session"]
    },
    { key: "suspend",  label: "Suspend",  icon: "sleep", destructive: false, cmd: ["systemctl", "suspend"] },
    // `uwsm stop`, not `hyprctl dispatch hl.dsp.exit()`, which is what this was
    // until uwsm took the session over.
    //
    // Both end the session -- killing the compositor makes wayland-wm@ exit,
    // and its OnSuccess pulls in wayland-session-shutdown.target. The
    // difference is the order. Stopping the compositor first destroys the
    // Wayland socket while the portals are still connected to it, and
    // xdg-desktop-portal-gtk answers a dead socket by exiting 1 -- "Error
    // reading events from display: Broken pipe" -- so systemd records a failed
    // unit rather than a stopped one. `uwsm stop` stops
    // graphical-session.target first, so everything PartOf it is asked to stop
    // while its socket still exists, and the compositor goes last.
    //
    // Observed 5 times in 14 days on suffer, and invisible until uwsm's fumon
    // started reporting failed units. It is cosmetic -- the portal is D-Bus
    // activated and comes back on demand -- but it is a real ordering fault and
    // this is the one-line fix for every deliberate log out. A crash or a
    // SIGKILL still races, and nothing in a config file can change that.
    //
    // The old form is not a typo, for the record: under the Lua config parser
    // `hyprctl dispatch` wraps its argument in `return hl.dispatch(...)`, so it
    // had to be an expression -- hence the call syntax.
    { key: "logout",   label: "Log out",  icon: "logout", destructive: true,  cmd: ["uwsm", "stop"] },
    { key: "reboot",   label: "Restart",  icon: "restart", destructive: true,  cmd: ["systemctl", "reboot"] },
    { key: "poweroff", label: "Shut down", icon: "power", destructive: true, cmd: ["systemctl", "poweroff"] }
  ]

  function toggle() { isOpen ? close() : open(); }

  function open() {
    // Always reopens on Lock. It is the only entry here that costs nothing if
    // triggered by accident, so a mistyped SUPER+M followed by a reflexive Enter
    // locks the screen rather than ending the session.
    root.selectedIndex = 0;
    root.armedIndex = -1;
    root.isOpen = true;
  }

  function close() {
    root.isOpen = false;
    root.armedIndex = -1;
  }

  function activate(i) {
    // Coerced because the arm check below is a strict comparison against
    // armedIndex. A caller handing in "3" instead of 3 would re-arm on every
    // press and never commit -- the destructive entries would look like they
    // simply did not work.
    const idx = Number(i);
    const action = root.actions[idx];
    if (!action) return;

    // Destructive entries take two presses. The first arms, the second commits;
    // moving away or pressing escape disarms.
    if (action.destructive && root.armedIndex !== idx) {
      root.armedIndex = idx;
      return;
    }

    root.close();
    runProc.command = action.cmd;
    runProc.running = true;
  }

  function move(delta) {
    const n = root.actions.length;
    root.selectedIndex = (root.selectedIndex + delta + n) % n;
    // Stepping off an armed entry cancels it, so a confirm can never be handed
    // to a neighbour by accident.
    root.armedIndex = -1;
  }

  Process { id: runProc; running: false }

  IpcHandler {
    target: "session"
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
    WlrLayershell.namespace: "quickshell-session"

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

      Keys.onEscapePressed: {
        // Escape backs out of an arm before it closes the menu, so the key does
        // the least destructive available thing at every step.
        if (root.armedIndex >= 0) root.armedIndex = -1;
        else root.close();
      }

      Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
          event.accepted = true; root.move(-1);
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
          event.accepted = true; root.move(1);
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          event.accepted = true; root.activate(root.selectedIndex);
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_5) {
          event.accepted = true;
          const i = event.key - Qt.Key_1;
          if (i < root.actions.length) { root.selectedIndex = i; root.armedIndex = -1; }
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

        RowLayout {
          Layout.alignment: Qt.AlignHCenter
          spacing: 12

          Repeater {
            model: root.actions

            Rectangle {
              id: tile
              required property var modelData
              required property int index

              readonly property bool isSelected: root.selectedIndex === index
              readonly property bool isArmed: root.armedIndex === index

              implicitWidth: 104
              implicitHeight: 104
              radius: 12
              color: isArmed      ? Qt.rgba(root.theme.accentRed.r, root.theme.accentRed.g, root.theme.accentRed.b, 0.18)
                   : isSelected   ? root.theme.bgSelected
                   : tileHover.containsMouse ? root.theme.bgHover
                   : root.theme.bgSurface

              border.width: (isSelected || isArmed) ? 1 : 0
              border.color: isArmed ? root.theme.accentRed : root.theme.accentPrimary

              Behavior on color { ColorAnimation { duration: 120 } }

              Accessible.role: Accessible.Button
              Accessible.name: tile.isArmed
                               ? tile.modelData.label + ", press again to confirm"
                               : tile.modelData.label

              ColumnLayout {
                anchors.centerIn: parent
                spacing: 8

                Icon {
                  Layout.alignment: Qt.AlignHCenter
                  name: tile.modelData.icon
                  color: tile.isArmed    ? root.theme.accentRed
                       : tile.isSelected ? root.theme.accentPrimary
                       : root.theme.textSecondary
                  size: 30
                }

                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: tile.isArmed ? "Confirm?" : tile.modelData.label
                  color: tile.isArmed    ? root.theme.accentRed
                       : tile.isSelected ? root.theme.textPrimary
                       : root.theme.textMuted
                  font { pixelSize: 11; bold: tile.isSelected || tile.isArmed; family: root.font }
                }
              }

              MouseArea {
                id: tileHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  root.selectedIndex = tile.index;
                  if (root.armedIndex !== tile.index) root.armedIndex = -1;
                }
                onClicked: root.activate(tile.index)
              }
            }
          }
        }

        Text {
          Layout.alignment: Qt.AlignHCenter
          text: root.armedIndex >= 0
                ? "press again to " + root.actions[root.armedIndex].label.toLowerCase()
                : "←→ or 1-5 to choose  ·  enter to confirm  ·  esc to cancel"
          color: root.armedIndex >= 0 ? root.theme.accentRed : root.theme.textMuted
          font { pixelSize: 10; family: root.font }
        }
      }
    }
  }
}
