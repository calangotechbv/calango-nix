pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false
  property var  pendingNet: null      // network we are currently authenticating against
  property var  pskTarget: null       // network whose password field is expanded
  property string pskText: ""
  property string errorText: ""

  // The list the ListView actually draws. Normally NetworkService.wifiNetworks
  // straight through; a snapshot of it while a password field is open.
  //
  // wifiNetworks is a computed property that sorts into a NEW JavaScript array
  // every time anything about the scan changes. Handing a ListView a new array
  // object makes it destroy and rebuild every delegate -- which destroys the
  // TextInput the user is typing into, and the focus with it. Two things churn
  // it: scan ticks, and forget() itself, since `known` flips false and the sort
  // is (b.known - a.known), so the row moves.
  //
  // Freezing is the fix rather than pausing the scan, because pausing only
  // stops one of those two. A stale list for the seconds it takes to type a
  // password is not a cost worth engineering around.
  readonly property var listModel:
    pskTarget !== null && frozenNetworks !== null ? frozenNetworks
                                                  : NetworkService.wifiNetworks
  property var frozenNetworks: null

  onPskTargetChanged: frozenNetworks = pskTarget !== null
                                     ? NetworkService.wifiNetworks : null

  function toggle() { isOpen ? close() : open(); }

  function open() {
    errorText = "";
    pskTarget = null;
    pskText   = "";
    isOpen    = true;
  }

  function close() {
    isOpen    = false;
    pskTarget = null;
    pskText   = "";
  }

  // Only scan while the panel is actually on screen, and not at all while a
  // password is being typed -- a scan tick cannot reorder a frozen list, but it
  // still costs radio time nobody is looking at.
  Binding {
    target:   NetworkService
    property: "scanning"
    value:    root.isOpen && root.pskTarget === null
  }

  function activate(net) {
    if (!net) return;
    root.errorText = "";

    if (net.connected) {
      NetworkService.disconnectFrom(net);
      return;
    }

    // An expanded field submits, whatever opened it. This used to be nested
    // inside the needsPassword() branch, which meant a field opened for a
    // *saved* network -- see onConnectionFailed below -- submitted with no key
    // at all, because needsPassword() is false once a network is known.
    if (root.pskTarget === net) {
      if (root.pskText === "") return;   // still empty; leave the field open
      root.pendingNet = net;
      NetworkService.connectTo(net, root.pskText);
      root.pskTarget = null;
      root.pskText   = "";
      return;
    }

    if (NetworkService.needsPassword(net)) {
      root.pskTarget = net;
      root.pskText   = "";
      return;
    }
    root.pendingNet = net;
    NetworkService.connectTo(net);
  }

  function failReason(reason) {
    switch (reason) {
      case ConnectionFailReason.NoSecrets:              return "Wrong or missing password";
      case ConnectionFailReason.WifiAuthTimeout:        return "Authentication timed out";
      case ConnectionFailReason.WifiClientDisconnected: return "Disconnected by the access point";
      case ConnectionFailReason.WifiClientFailed:       return "Association failed";
      case ConnectionFailReason.WifiNetworkLost:        return "Network went out of range";
      default:                                          return "Connection failed";
    }
  }

  Connections {
    target: root.pendingNet
    ignoreUnknownSignals: true
    function onConnectionFailed(reason) {
      const net = root.pendingNet;

      // NoSecrets means NetworkManager could not produce a key, which is not the
      // same as the key being wrong, and on this desktop it is the common case.
      // Every saved connection here carries psk-flags=1 (agent-owned), so the
      // key lives in no file -- NM asks a secret agent for it at connect time.
      // Quickshell is not one: it drives NetworkManager over seven D-Bus
      // interfaces and AgentManager is not among them, so nothing answers.
      //
      // Asking for the key is therefore the useful response, and for a saved
      // network it is the only one -- needsPassword() is false once a network is
      // known, so the field never opened and the user was told the password was
      // wrong without being offered anywhere to type it.
      if (reason === ConnectionFailReason.NoSecrets && net && !NetworkService.isOpen(net)) {
        root.pskTarget = net;
        root.pskText   = "";
        root.errorText = net.known ? "Saved password unavailable -- type it again"
                                   : "Wrong or missing password";
      } else {
        root.errorText = root.failReason(reason);
      }
      // Last, as before. This is the Connections target, and clearing it earlier
      // would retarget the element from inside its own handler.
      root.pendingNet = null;
    }
  }

  IpcHandler {
    target: "network"
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
    WlrLayershell.namespace: "quickshell-network"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      width: 420
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
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: 10

          Icon {
            name: NetworkService.icon
            color: NetworkService.kind === "disconnected"
                   ? root.theme.textMuted : root.theme.accentGreen
            size: 18
          }

          ColumnLayout {
            spacing: 0
            Text {
              text: NetworkService.label
              color: root.theme.textPrimary
              font { pixelSize: 13; bold: true; family: root.font }
            }
            Icon {
              name: {
                if (!NetworkService.available) return "NetworkManager unavailable";
                if (NetworkService.limited)    return "Connected, no internet";
                if (NetworkService.kind === "wifi")
                  return Math.round(NetworkService.signalStrength * 100) + "%  ·  "
                         + NetworkService.securityLabel(NetworkService.activeNetwork);
                if (NetworkService.kind === "ethernet") return "Wired connection";
                return NetworkService.wifiEnabled ? "Not connected" : "Wi-Fi disabled";
              }
              color: NetworkService.limited ? root.theme.accentOrange : root.theme.textMuted
              size: 11
            }
          }

          Item { Layout.fillWidth: true }

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

        // Error banner
        Rectangle {
          Layout.fillWidth: true
          visible: root.errorText !== ""
          Layout.preferredHeight: 36
          radius: 8
          color: Qt.rgba(root.theme.accentRed.r, root.theme.accentRed.g, root.theme.accentRed.b, 0.15)
          border.color: root.theme.accentRed
          border.width: 1

          onVisibleChanged: if (visible) errorTimer.restart()
          Timer { id: errorTimer; interval: 6000; onTriggered: root.errorText = "" }

          Text {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            verticalAlignment: Text.AlignVCenter
            text: root.errorText
            color: root.theme.accentRed
            font { pixelSize: 11; family: root.font }
            elide: Text.ElideRight
          }
        }

        Text {
          text: NetworkService.wifiNetworks.length > 0 ? "Networks" : "Scanning…"
          color: root.theme.textMuted
          font { pixelSize: 10; family: root.font }
        }

        // Network list
        ListView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: 4
          model: root.listModel

          delegate: Rectangle {
            id: netRow
            required property var modelData
            readonly property bool expanded: root.pskTarget === modelData

            width: ListView.view.width
            height: expanded ? 84 : 44
            radius: 8
            color: modelData.connected ? root.theme.bgSelected
                 : rowHover.containsMouse ? root.theme.bgHover
                 : root.theme.bgSurface

            Behavior on height { NumberAnimation { duration: 120 } }

            // Declared before the row content so it sits *under* the forget
            // button, which takes its own clicks. Hit testing walks siblings
            // back to front: with this declared last, as it was, the full-size
            // MouseArea won every press aimed at the trash icon and forgetting
            // a network quietly toggled its connection instead.
            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              // Nothing on an expanded row should respond but the password field.
              enabled: !netRow.expanded
              onClicked: root.activate(netRow.modelData)
            }

            ColumnLayout {
              anchors { fill: parent; margins: 10 }
              spacing: 6

              RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Icon {
                  name: {
                    const s = netRow.modelData.signalStrength;
                    if (s >= 0.75) return "wifi-strength-4";
                    if (s >= 0.50) return "wifi-strength-3";
                    if (s >= 0.25) return "wifi-strength-2";
                    return "wifi-strength-1";
                  }
                  color: netRow.modelData.connected ? root.theme.accentGreen : root.theme.textSecondary
                  size: 15
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  Text {
                    Layout.fillWidth: true
                    text: netRow.modelData.name
                    color: root.theme.textPrimary
                    font { pixelSize: 12; bold: netRow.modelData.connected; family: root.font }
                    elide: Text.ElideRight
                  }

                  Text {
                    text: {
                      const bits = [];
                      if (netRow.modelData.connected) bits.push("connected");
                      else if (netRow.modelData.stateChanging) bits.push("connecting…");
                      else if (netRow.modelData.known) bits.push("saved");
                      const sec = NetworkService.securityLabel(netRow.modelData);
                      if (sec) bits.push(sec);
                      return bits.join("  ·  ");
                    }
                    color: root.theme.textMuted
                    font { pixelSize: 10; family: root.font }
                  }
                }

                // Forget — only meaningful for saved networks
                Icon {
                  visible: netRow.modelData.known
                  name: "delete"
                  color: forgetHover.containsMouse ? root.theme.accentRed : root.theme.textMuted
                  size: 13
                  MouseArea {
                    id: forgetHover
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.errorText = "";
                      NetworkService.forget(netRow.modelData);
                    }
                  }
                }
              }

              // Inline password entry for unsaved secured networks
              Rectangle {
                Layout.fillWidth: true
                visible: netRow.expanded
                Layout.preferredHeight: 28
                radius: 6
                color: root.theme.bgBase
                border.color: root.theme.bgBorder
                border.width: 1

                TextInput {
                  id: pskInput
                  anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                  verticalAlignment: TextInput.AlignVCenter
                  echoMode: TextInput.Password
                  color: root.theme.textPrimary
                  font { pixelSize: 11; family: root.font }
                  focus: netRow.expanded
                  onTextChanged: root.pskText = text
                  onAccepted: root.activate(netRow.modelData)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: pskInput.text === ""
                    text: "Password, then Enter"
                    color: root.theme.textMuted
                    font { pixelSize: 11; family: root.font }
                  }
                }
              }
            }
          }
        }

        // Footer
        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Text {
            text: NetworkService.wifiDevice
                  ? NetworkService.wifiDevice.name + "  ·  " + NetworkService.wifiNetworks.length + " visible"
                  : "No Wi-Fi device"
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
