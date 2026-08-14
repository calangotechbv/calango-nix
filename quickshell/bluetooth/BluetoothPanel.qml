pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// Bluetooth devices, in the shape of the network panel: one list, one click per
// row to do the obvious thing, and a trash icon on the rows where forgetting
// means something.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false

  // The device we last asked to pair or connect, and which of the two it was.
  // BlueZ reports neither failures nor reasons, so watching this settle is the
  // only way to tell a refused attempt from one still in flight.
  property var pendingDevice: null
  property string pendingAction: ""
  property string errorText: ""

  function toggle() { isOpen ? close() : open(); }

  function open() {
    root.errorText = "";
    root.isOpen = true;
  }

  function close() {
    root.isOpen = false;
    root.pendingDevice = null;
    root.pendingAction = "";
  }

  // Discover only while the panel is up.
  Binding {
    target:   BluetoothService
    property: "scanning"
    value:    root.isOpen
  }

  function activate(device) {
    if (!device) return;
    root.errorText = "";

    // Cancelling is a click on the same row, so a mis-click is undone the same
    // way it was made. Pending is cleared *before* the call so the handlers
    // below see nothing to report: a cancelled pair lands in exactly the same
    // state as a refused one, and without this it would raise "could not pair"
    // for something the user called off on purpose.
    if (BluetoothService.isPending(device)) {
      root.pendingDevice = null;
      root.pendingAction = "";
      BluetoothService.cancel(device);
      return;
    }

    if (device.connected) {
      root.pendingDevice = null;
      root.pendingAction = "";
    } else {
      root.pendingDevice = device;
      root.pendingAction = device.paired ? "connect" : "pair";
    }
    BluetoothService.activate(device);
  }

  Connections {
    target: root.pendingDevice
    ignoreUnknownSignals: true

    // Pairing is done when the flag drops. Whether it worked is a separate
    // question, answered by whether the device ended up paired.
    function onPairingChanged() {
      const device = root.pendingDevice;
      if (root.pendingAction !== "pair" || !device || device.pairing) return;

      if (!device.paired) {
        root.errorText = "Could not pair " + BluetoothService.name(device)
                       + " — put it in pairing mode and try again";
        root.pendingDevice = null;
        root.pendingAction = "";
        return;
      }

      // Pairing only bonds; whether it also opens a profile is the device's
      // choice, and a JBL headset here does not -- it paired, said nothing, and
      // needed the row clicked a second time before any audio sink appeared.
      // So carry straight on into the connect, and stay pending so a failure
      // still reaches the banner.
      //
      // Trusting it is what lets it reconnect on its own afterwards: BlueZ will
      // not accept an incoming connection from an untrusted device without an
      // agent to ask, which is why a headset paired here would otherwise go
      // quiet again every time it was powered off. `bluetoothctl pair` leaves
      // this unset, which is the source of that whole class of "it paired but
      // never comes back" complaints.
      if (!device.trusted) device.trusted = true;

      if (device.connected) {
        root.pendingDevice = null;
        root.pendingAction = "";
        return;
      }

      root.pendingAction = "connect";
      device.connect();
    }

    function onStateChanged() {
      const device = root.pendingDevice;
      if (root.pendingAction !== "connect" || !device) return;
      if (device.state === BluetoothDeviceState.Connecting) return;

      if (device.state === BluetoothDeviceState.Disconnected)
        root.errorText = "Could not connect to " + BluetoothService.name(device);
      root.pendingDevice = null;
      root.pendingAction = "";
    }
  }

  IpcHandler {
    target: "bluetooth"
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
    WlrLayershell.namespace: "quickshell-bluetooth"

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
            name: BluetoothService.icon
            color: !BluetoothService.enabled ? root.theme.textMuted
                 : BluetoothService.connectedDevices.length > 0 ? root.theme.accentGreen
                 : root.theme.accentPrimary
            size: 18
          }

          ColumnLayout {
            spacing: 0
            Text {
              text: "Bluetooth"
              color: root.theme.textPrimary
              font { pixelSize: 13; bold: true; family: root.font }
            }
            Text {
              text: {
                if (!BluetoothService.available) return "No adapter found";
                if (BluetoothService.blocked)    return "Blocked in rfkill";
                if (!BluetoothService.enabled)   return "Powered off";
                return BluetoothService.label;
              }
              color: BluetoothService.blocked ? root.theme.accentOrange : root.theme.textMuted
              font { pixelSize: 11; family: root.font }
              elide: Text.ElideRight
              Layout.maximumWidth: 250
            }
          }

          Item { Layout.fillWidth: true }

          // Power toggle. Left enabled while blocked so the click still reaches
          // BlueZ -- it is rfkill that will refuse, and saying so in the
          // subtitle beats a dead-looking button.
          Rectangle {
            visible: BluetoothService.available
            implicitWidth: 30
            implicitHeight: 24
            radius: 8
            color: powerHover.containsMouse ? root.theme.bgHover : root.theme.bgSurface

            Accessible.role: Accessible.Button
            Accessible.name: BluetoothService.enabled
                             ? "Turn Bluetooth off" : "Turn Bluetooth on"

            Icon {
              anchors.centerIn: parent
              name: "power"
              color: BluetoothService.enabled ? root.theme.accentGreen : root.theme.textMuted
              size: 13
            }

            MouseArea {
              id: powerHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.errorText = "";
                BluetoothService.setEnabled(!BluetoothService.enabled);
              }
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

        // Controller picker. Only on a machine with more than one, where it
        // stops being an implementation detail: two controllers are not
        // interchangeable -- one here is an old CSR dongle and the other a
        // MediaTek -- and the panel used to pick for you, silently, by hciN.
        // The choice is remembered, so it survives a reload and a reboot.
        ColumnLayout {
          Layout.fillWidth: true
          visible: BluetoothService.hasChoice
          spacing: 4

          Text {
            text: "Controller"
            color: root.theme.textMuted
            font { pixelSize: 10; family: root.font }
          }

          Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
              model: BluetoothService.adaptersInOrder

              Rectangle {
                id: adapterChip
                required property var modelData

                readonly property bool active:
                  BluetoothService.adapter === adapterChip.modelData

                implicitWidth: chipText.implicitWidth + 20
                implicitHeight: 26
                radius: 8
                color: adapterChip.active ? root.theme.bgSelected
                     : chipHover.containsMouse ? root.theme.bgHover
                     : root.theme.bgSurface
                border.width: adapterChip.active ? 1 : 0
                border.color: root.theme.accentPrimary

                Accessible.role: Accessible.RadioButton
                Accessible.name: BluetoothService.adapterLabel(adapterChip.modelData)
                                 + (adapterChip.active ? ", selected" : "")

                Row {
                  id: chipText
                  anchors.centerIn: parent
                  spacing: 6

                  Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    // Powered state per controller, not just the selected one:
                    // picking a controller that is off is a normal thing to do
                    // and the toggle above then turns *it* on.
                    name: adapterChip.modelData.enabled ? "bluetooth" : "bluetooth-off"
                    color: adapterChip.modelData.enabled ? root.theme.accentPrimary
                                                         : root.theme.textMuted
                    size: 12
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: BluetoothService.adapterLabel(adapterChip.modelData)
                    color: adapterChip.active ? root.theme.textPrimary
                                              : root.theme.textSecondary
                    font { pixelSize: 11; family: root.font }
                  }
                }

                MouseArea {
                  id: chipHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.errorText = "";
                    BluetoothService.selectAdapter(adapterChip.modelData);
                  }
                }
              }
            }
          }
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
          text: {
            if (!BluetoothService.available) return "Nothing to show";
            if (!BluetoothService.enabled)   return "Turn Bluetooth on to see devices";
            return BluetoothService.devices.length > 0 ? "Devices" : "Scanning…";
          }
          color: root.theme.textMuted
          font { pixelSize: 10; family: root.font }
        }

        // Device list
        ListView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: 4
          model: BluetoothService.devices

          delegate: Rectangle {
            id: deviceRow
            required property var modelData

            // A click on a row has always connected, disconnected or paired it,
            // depending on where the row stood -- but nothing on screen ever
            // said so, which left disconnecting a device looking like something
            // the panel could not do. Shown on hover only: at rest the row
            // should read as status, not as instructions.
            readonly property string hint: {
              if (!rowHover.containsMouse) return "";
              if (BluetoothService.isPending(modelData)) return "click to cancel";
              if (modelData.connected) return "click to disconnect";
              return modelData.paired ? "click to connect" : "click to pair";
            }

            readonly property string subtitle: {
              const bits = [];
              const state = BluetoothService.stateLabel(modelData);
              if (BluetoothService.isPending(modelData)) {
                // Mid-attempt the state is the news, so the hint goes after it
                // rather than over it: "pairing…  ·  click to cancel".
                if (state) bits.push(state);
                if (deviceRow.hint) bits.push(deviceRow.hint);
              } else {
                const lead = deviceRow.hint || state;
                if (lead) bits.push(lead);
              }
              const battery = BluetoothService.batteryLabel(modelData);
              if (battery) bits.push(battery + " battery");
              return bits.join("  ·  ");
            }

            width: ListView.view.width
            height: 44
            radius: 8
            color: modelData.connected ? root.theme.bgSelected
                 : rowHover.containsMouse ? root.theme.bgHover
                 : root.theme.bgSurface

            // Declared before the row content so it sits *under* the forget
            // button, which takes its own clicks. Same arrangement as the mute
            // button in the audio panel's device rows: hit testing walks
            // siblings back to front, so a full-size MouseArea declared last
            // would swallow every click meant for the controls inside.
            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activate(deviceRow.modelData)
            }

            RowLayout {
              anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
              spacing: 10

              Icon {
                name: BluetoothService.deviceIcon(deviceRow.modelData)
                color: deviceRow.modelData.connected ? root.theme.accentGreen
                     : deviceRow.modelData.paired    ? root.theme.textSecondary
                     : root.theme.textMuted
                size: 15
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                  Layout.fillWidth: true
                  text: BluetoothService.name(deviceRow.modelData)
                  color: root.theme.textPrimary
                  font {
                    pixelSize: 12
                    bold: deviceRow.modelData.connected
                    family: root.font
                  }
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  visible: deviceRow.subtitle !== ""
                  text: deviceRow.subtitle
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                  elide: Text.ElideRight
                }
              }

              // Forget — only meaningful once a device is paired.
              Icon {
                visible: deviceRow.modelData.paired
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
                    BluetoothService.forget(deviceRow.modelData);
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
            text: {
              if (!BluetoothService.available) return "No adapter";
              const adapter = BluetoothService.adapter.name || BluetoothService.adapter.adapterId;
              return adapter + "  ·  " + BluetoothService.devices.length + " found";
            }
            color: root.theme.textMuted
            font { pixelSize: 10; family: root.font }
            elide: Text.ElideRight
            Layout.maximumWidth: 300
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
