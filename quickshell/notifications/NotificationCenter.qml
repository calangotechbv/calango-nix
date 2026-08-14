pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import "../common"

// The archive behind the popups. NotificationPopup shows what is arriving now
// and forgets it seconds later; this is where everything that scrolled past
// while you were away can still be read.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false

  function toggle() { isOpen ? close() : open(); }

  function open() {
    isOpen = true;
    // Opening is the act of reading. The badge clears here rather than on close
    // so a glance at the list is enough to quiet the bar.
    NotificationService.markAllRead();
  }

  function close() { isOpen = false; }

  // Ticks the relative timestamps ("3m ago") while the panel is up. Bound to
  // isOpen because a clock that runs against a hidden list is pure wakeups.
  property double now: Date.now()
  Timer {
    running: root.isOpen
    interval: 30000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  function ago(ms) {
    const s = Math.max(0, Math.floor((root.now - ms) / 1000));
    if (s < 60) return "just now";
    const m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    const h = Math.floor(m / 60);
    if (h < 24) return h + "h ago";
    return Math.floor(h / 24) + "d ago";
  }

  // Lives here rather than in NotificationPopup because a target may only be
  // registered once, and the centre is the natural owner of the whole feature.
  IpcHandler {
    target: "notifications"

    function toggle(): void  { root.toggle(); }
    function open(): void    { root.open(); }
    function close(): void   { root.close(); }

    function dismiss_all(): void { NotificationService.dismissAll(); }
    function dnd_toggle(): void  { NotificationService.doNotDisturb = !NotificationService.doNotDisturb; }
    function clear(): void       { NotificationService.clearHistory(); }
  }

  Scrim { active: overlay.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: overlay
    visible: root.isOpen
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-notification-center"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      width: 460
      height: 600
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
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: 10

          Icon {
            name: NotificationService.doNotDisturb ? "bell-off" : "bell"
            color: NotificationService.doNotDisturb ? root.theme.accentOrange
                                                    : root.theme.accentPrimary
            size: 18
          }

          ColumnLayout {
            spacing: 0
            Text {
              text: "Notifications"
              color: root.theme.textPrimary
              font { pixelSize: 13; bold: true; family: root.font }
            }
            Text {
              text: {
                const n = NotificationService.history.length;
                const base = n === 0 ? "Nothing archived"
                           : n === 1 ? "1 notification"
                           : n + " notifications";
                return NotificationService.doNotDisturb
                     ? base + "  ·  silenced" : base;
              }
              color: NotificationService.doNotDisturb ? root.theme.accentOrange
                                                      : root.theme.textMuted
              font { pixelSize: 11; family: root.font }
            }
          }

          Item { Layout.fillWidth: true }

          // Before DND rather than after it, because this is the one that comes
          // and goes: everything to the right of a hidden item keeps its place,
          // so clearing the list leaves DND and the close button exactly where
          // the pointer left them. The other order moved them both sideways at
          // the moment of the click.
          Rectangle {
            Layout.preferredHeight: 26
            Layout.preferredWidth: 26
            radius: 13
            visible: NotificationService.history.length > 0
            color: clearHover.containsMouse ? root.theme.bgHover : root.theme.bgSurface

            Behavior on color { ColorAnimation { duration: 120 } }

            Accessible.role: Accessible.Button
            Accessible.name: "Clear all notifications"

            // The same bin the clipboard, bluetooth and network panels delete
            // with. Red on hover, unlike the close button beside it: this one
            // really does throw something away.
            Icon {
              anchors.centerIn: parent
              name: "delete"
              color: clearHover.containsMouse ? root.theme.accentRed : root.theme.textSecondary
              size: 14
            }

            MouseArea {
              id: clearHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: NotificationService.clearHistory()
            }
          }

          // Do not disturb. Notifications still land in the list below while
          // this is on -- it silences the popup, it does not drop anything.
          Rectangle {
            Layout.preferredHeight: 26
            Layout.preferredWidth: 26
            radius: 13
            color: NotificationService.doNotDisturb ? root.theme.accentOrange
                 : dndHover.containsMouse          ? root.theme.bgHover
                 : root.theme.bgSurface

            Behavior on color { ColorAnimation { duration: 120 } }

            Accessible.role: Accessible.CheckBox
            Accessible.name: "Do not disturb"
            Accessible.checked: NotificationService.doNotDisturb

            // One icon in both states -- the crossed bell says what the
            // button does, and the filled pill says whether it is on. Swapping
            // the icon as well left it ambiguous whether it showed the
            // current state or the one a click would bring about.
            Icon {
              anchors.centerIn: parent
              name: "bell-off"
              color: NotificationService.doNotDisturb ? root.theme.bgBase
                                                      : root.theme.textSecondary
              size: 14
            }

            MouseArea {
              id: dndHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: NotificationService.doNotDisturb = !NotificationService.doNotDisturb
            }
          }

          CloseButton {
            theme: root.theme
            font: root.font
            onClicked: root.close()
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 1
          color: root.theme.bgBorder
        }

        // Empty state
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: NotificationService.history.length === 0
          spacing: 8

          Item { Layout.fillHeight: true }

          // Centred with fillWidth + horizontalAlignment rather than
          // Layout.alignment: Qt.AlignHCenter. A nested layout takes its size
          // hints from its children, and an aligned child is by definition never
          // stretched -- so with only aligned children this column's maximum
          // width collapses to its implicit width, its own Layout.fillWidth has
          // nothing to expand into, and the whole block sits left-aligned in the
          // panel. One filling child is what lets the column span the panel.
          // Still fillWidth for the reason above, but an Icon has no
          // horizontalAlignment: it centres its own drawing inside whatever box
          // it is given, so filling the width is all the centring it needs.
          Icon {
            Layout.fillWidth: true
            name: "bell-outline"
            color: root.theme.textMuted
            size: 40
          }
          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: "No notifications yet"
            color: root.theme.textMuted
            font { pixelSize: 12; family: root.font }
          }

          Item { Layout.fillHeight: true }
        }

        // History
        ListView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: NotificationService.history.length > 0
          clip: true
          spacing: 4
          model: NotificationService.history

          delegate: Rectangle {
            id: histRow
            required property var modelData

            width: ListView.view.width
            height: rowContent.implicitHeight + 20
            radius: 8
            color: rowHover.containsMouse ? root.theme.bgHover : root.theme.bgSurface

            Accessible.role: Accessible.StaticText
            Accessible.name: (histRow.modelData.appName || "Notification")
                             + ": " + histRow.modelData.summary
                             + ", " + root.ago(histRow.modelData.time)

            // Urgency stripe, same vocabulary as the popup card.
            Rectangle {
              width: 3
              height: parent.height - 16
              radius: 2
              anchors.left: parent.left
              anchors.leftMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              color: histRow.modelData.urgency === NotificationUrgency.Critical ? root.theme.urgencyCritical
                   : histRow.modelData.urgency === NotificationUrgency.Low      ? root.theme.urgencyLow
                   : root.theme.urgencyNormal
            }

            ColumnLayout {
              id: rowContent
              anchors {
                fill: parent
                leftMargin: 18; rightMargin: 10
                topMargin: 10;  bottomMargin: 10
              }
              spacing: 4

              RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item {
                  Layout.preferredWidth: 14
                  Layout.preferredHeight: 14
                  Layout.alignment: Qt.AlignVCenter

                  IconImage {
                    anchors.centerIn: parent
                    source: Quickshell.iconPath(histRow.modelData.appIcon, true)
                    implicitSize: 14
                    visible: histRow.modelData.appIcon !== ""
                  }

                  Icon {
                    anchors.centerIn: parent
                    visible: histRow.modelData.appIcon === ""
                    name: "bell"
                    color: root.theme.textMuted
                    size: 12
                  }
                }

                Text {
                  text: histRow.modelData.appName || "Notification"
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                }

                Item { Layout.fillWidth: true }

                Text {
                  text: root.ago(histRow.modelData.time)
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                }

                Icon {
                  visible: rowHover.containsMouse
                  name: "close"
                  color: removeHover.containsMouse ? root.theme.accentRed : root.theme.textMuted
                  size: 11

                  MouseArea {
                    id: removeHover
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: NotificationService.removeFromHistory(histRow.modelData.key)
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                text: histRow.modelData.summary
                color: root.theme.textPrimary
                font { pixelSize: 12; bold: true; family: root.font }
                elide: Text.ElideRight
                visible: text !== ""
              }

              // Collapsed to two lines until hovered. A wall of full bodies makes
              // the list unscannable; the long ones are almost never the point.
              Text {
                Layout.fillWidth: true
                text: histRow.modelData.body
                color: root.theme.textSecondary
                font { pixelSize: 11; family: root.font }
                wrapMode: Text.Wrap
                maximumLineCount: rowHover.containsMouse ? 8 : 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
                visible: text !== ""
              }
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              // No click action: the notification is already closed on the bus by
              // the time it lands here, so its actions are dead and a clickable
              // row would only promise something it cannot do.
              acceptedButtons: Qt.NoButton
              z: -1
            }
          }
        }

        // Footer
        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Text {
            text: NotificationService.history.length >= NotificationService.historyLimit
                  ? "Keeping the last " + NotificationService.historyLimit
                  : ""
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
