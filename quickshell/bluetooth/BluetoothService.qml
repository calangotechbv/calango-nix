pragma Singleton

import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import QtQuick

// BlueZ state, via Quickshell's built-in Bluetooth module rather than driving
// bluetoothctl. Everything is event-driven over D-Bus, the same way
// NetworkService works, so nothing here polls.
Singleton {
  id: root

  // Load-bearing declarative binding, exactly as in NetworkService: the backend
  // models only populate once something observes them from a binding. Reading
  // Bluetooth.devices.values inside a function yields an empty list and the
  // backend never starts. Do not inline this into the functions below.
  readonly property var allDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var adapters:   Bluetooth.adapters ? Bluetooth.adapters.values : []

  // Stable order for everything that has to enumerate controllers: the picker
  // in the panel, and the automatic choice below.
  readonly property var adaptersInOrder: adapters.slice()
    .sort((a, b) => String(a.adapterId).localeCompare(String(b.adapterId)))

  // Whether the choice is worth putting on screen at all. One controller is the
  // normal case and needs no picker.
  readonly property bool hasChoice: adaptersInOrder.length > 1

  // Which controller everything here means. Read back from disk at startup; ""
  // until then, and "" forever on a machine where the user never chose.
  property string preferredAdapterId: ""

  // Not Bluetooth.defaultAdapter: that is whichever controller the process
  // enumerated first, and it is a race. This box has two, and two quickshell
  // processes reading it seconds apart disagreed -- hci0 in one, hci1 in the
  // other. Since the toggle, the footer and the scan must all mean the same
  // radio, and must keep meaning it across restarts, it cannot be inferred
  // per-process.
  //
  // The automatic fallback -- a powered controller, lowest hciN -- is only a
  // guess, and on this machine it guessed wrong: hci0 is an old CSR dongle and
  // hci1 a MediaTek, and they are not interchangeable. So a saved choice wins
  // outright, including over a powered-off controller: turning it on is a click
  // in the panel, and silently defecting to the other radio would undo the
  // choice exactly when it matters.
  readonly property var adapter: {
    const sorted = root.adaptersInOrder;
    const chosen = root.preferredAdapterId === "" ? null
      : sorted.find(a => String(a.adapterId) === root.preferredAdapterId);
    return chosen ?? sorted.find(a => a.enabled) ?? sorted[0] ?? null;
  }

  // A human-facing name for a controller. BlueZ's `name` is the hostname on
  // most machines -- identical across both here -- so the hciN is what actually
  // tells them apart and leads.
  function adapterLabel(a) {
    if (!a) return "";
    const id = String(a.adapterId);
    const name = a.name ? String(a.name) : "";
    return (name && name !== id) ? id + " · " + name : id;
  }

  function selectAdapter(a) {
    if (!a) return;
    root.preferredAdapterId = String(a.adapterId);
    saveProc.command = ["sh", "-c",
                        'printf "%s" "$1" > "$HOME/.config/quickshell/bluetooth-adapter.conf"',
                        "sh", root.preferredAdapterId];
    saveProc.running = true;
  }

  Process { id: saveProc; running: false }

  // Read once at startup. Not watchChanges: nothing else writes this, and a
  // reload picks it up anyway.
  FileView {
    id: adapterPref
    path: Quickshell.env("HOME") + "/.config/quickshell/bluetooth-adapter.conf"
    onTextChanged: root.preferredAdapterId = adapterPref.text().trim()
  }

  readonly property bool available: adapter !== null
  readonly property bool enabled:   adapter !== null && adapter.enabled

  // rfkill'd rather than merely powered down, which is worth saying out loud:
  // the toggle in the panel cannot clear it.
  readonly property bool blocked:
    adapter !== null && adapter.state === BluetoothAdapterState.Blocked

  // Only the selected controller's devices. A device object belongs to the
  // adapter that found it -- pairing, connecting and forgetting all happen
  // there -- so listing the other controller's devices would offer rows whose
  // buttons do not mean what the header says. (This was deliberately unfiltered
  // while the adapter was picked automatically, on the grounds that two
  // controllers see much the same room. Once the choice is the user's, showing
  // them the room through the radio they did not pick is just wrong.)
  readonly property var ownDevices: {
    if (!root.adapter) return root.allDevices;
    const id = String(root.adapter.adapterId);
    return root.allDevices.filter(d =>
      d && d.adapter && String(d.adapter.adapterId) === id);
  }

  readonly property var connectedDevices: ownDevices.filter(d => d && d.connected)
  readonly property var pairedDevices:    ownDevices.filter(d => d && d.paired)

  // Panel order: connected, then paired, then whatever the scan turned up.
  // Alphabetical inside each group -- BlueZ exposes no signal strength here, and
  // anything time-based would make rows swap places while you aim at one.
  readonly property var devices: {
    const list = ownDevices.slice();
    list.sort((a, b) =>
      (b.connected - a.connected)
      || (b.paired - a.paired)
      || root.name(a).localeCompare(root.name(b)));
    return list;
  }

  // `name` is the user-assigned alias and falls back to the advertised name;
  // an address is all that is left for a device that has announced neither.
  // BlueZ hands those back dash-separated, out of the D-Bus object path --
  // rewritten to colons, which is how a MAC is written everywhere else.
  function name(device) {
    if (!device) return "";
    const label = device.name || device.deviceName || device.address;
    if (!label) return "Unknown device";
    return /^[0-9a-f]{2}(-[0-9a-f]{2}){5}$/i.test(label) ? label.replace(/-/g, ":") : label;
  }

  // BlueZ classifies devices with freedesktop icon names. Mapped to our own
  // icon names rather than looked up as themed icons so the rows match the
  // rest of the panel, which is common/Icon.qml throughout.
  function deviceIcon(device) {
    switch (device ? String(device.icon) : "") {
      case "audio-headset":     return "headset";
      case "audio-headphones":  return "headphones";
      case "audio-card":
      case "audio-speakers":
      case "multimedia-player": return "speaker";
      case "input-mouse":       return "mouse";
      case "input-keyboard":    return "keyboard";
      case "input-gaming":      return "gamepad-variant";
      case "input-tablet":      return "tablet";
      case "phone":             return "cellphone";
      case "computer":          return "laptop";
      case "printer":
      case "scanner":           return "printer";
      case "camera-photo":      return "camera";
      case "camera-video":
      case "video-display":     return "television";
      default:                  return "bluetooth";
    }
  }

  function stateLabel(device) {
    if (!device) return "";
    if (device.pairing) return "pairing…";
    switch (device.state) {
      case BluetoothDeviceState.Connecting:    return "connecting…";
      case BluetoothDeviceState.Disconnecting: return "disconnecting…";
      case BluetoothDeviceState.Connected:     return "connected";
      default: return device.paired ? "paired" : "";
    }
  }

  // Only meaningful while connected, and only for devices that report it at all
  // -- most mice do, most speakers do not.
  function batteryLabel(device) {
    if (!device || !device.batteryAvailable) return "";
    return Math.round(device.battery * 100) + "%";
  }

  readonly property string label: {
    if (!available) return "No adapter";
    if (blocked)    return "Blocked";
    if (!enabled)   return "Off";
    if (connectedDevices.length === 1) return root.name(connectedDevices[0]);
    if (connectedDevices.length > 1)   return connectedDevices.length + " devices";
    return "Not connected";
  }

  // What the bar pill draws: one entry per connected device rather than a
  // count, because "3 devices" told you something was connected but never
  // what, and hid the battery readings -- which are the reason to look at the
  // pill at all. Taken from `devices` rather than `connectedDevices` so the
  // order is the panel's alphabetical one and the icons cannot swap places
  // when BlueZ reorders its list underneath.
  readonly property int pillLimit: 3
  readonly property var connectedInOrder: devices.filter(d => d && d.connected)
  readonly property var pillDevices: connectedInOrder.slice(0, pillLimit)
  readonly property int pillOverflow: Math.max(0, connectedInOrder.length - pillLimit)

  // The pill is icons, which read as nothing at all, so screen readers get
  // the names and batteries spelled out instead.
  readonly property string spokenLabel: {
    if (connectedInOrder.length === 0) return label;
    return connectedInOrder.map(d => {
      const battery = root.batteryLabel(d);
      return battery ? root.name(d) + " at " + battery : root.name(d);
    }).join(", ");
  }

  readonly property string icon: {
    if (!enabled) return "bluetooth-off";
    return connectedDevices.length > 0 ? "bluetooth-connect" : "bluetooth";
  }

  // Discovery is expensive and floods the list with passing phones, so it only
  // runs while the panel is on screen. The panel drives this.
  property bool scanning: false

  // Deliberately not a Binding, which is what this was first written as and
  // which leaks a discovery session. A Binding writes when its *value* changes,
  // and the value here starts false and stays false across a config reload --
  // so it never re-asserts against an adapter whose real state arrives later,
  // over D-Bus, as "still discovering". The QML tree is rebuilt by a reload but
  // the process, and therefore BlueZ's per-client discovery session, is not:
  // measured on this machine, a reload with the panel open left the controller
  // scanning indefinitely, with no panel to show for it.
  //
  // Reconciling against the adapter's actual state instead converges from any
  // starting point, including that one. Writing the value it already holds is
  // skipped, so this cannot recurse through discoveringChanged.
  // The controller this last started a scan on, so switching controllers can
  // hand the session over. Reconciling only the current adapter would leave the
  // one just switched away from scanning with no panel pointed at it -- the
  // same leak the Binding version had, reintroduced through the picker.
  property var scanningAdapter: null

  function applyScanning() {
    const wanted = root.scanning && root.enabled;

    if (root.scanningAdapter && root.scanningAdapter !== root.adapter) {
      if (root.scanningAdapter.discovering) root.scanningAdapter.discovering = false;
      root.scanningAdapter = null;
    }

    if (root.adapter && root.adapter.discovering !== wanted)
      root.adapter.discovering = wanted;
    root.scanningAdapter = wanted ? root.adapter : null;
  }

  onScanningChanged: root.applyScanning()
  onAdapterChanged:  root.applyScanning()
  onEnabledChanged:  root.applyScanning()

  Connections {
    target: root.adapter
    ignoreUnknownSignals: true
    // Covers the startup case: the adapter appears before its properties have
    // been fetched, so the first reconcile runs against a default of false.
    function onDiscoveringChanged() { root.applyScanning(); }
  }

  // Belt and braces for the reload above: stop before the tree goes away, so
  // the next one does not have to clean up after this one.
  Component.onDestruction: {
    if (root.adapter && root.adapter.discovering) root.adapter.discovering = false;
    if (root.scanningAdapter && root.scanningAdapter.discovering)
      root.scanningAdapter.discovering = false;
  }

  function setEnabled(on) { if (adapter) adapter.enabled = on; }

  // True while an attempt is in flight, which is the same as saying there is
  // something to cancel.
  function isPending(device) {
    return !!device
        && (device.pairing || device.state === BluetoothDeviceState.Connecting);
  }

  // BlueZ has a CancelPairing but no cancel-connect: a connection still being
  // set up is aborted by disconnecting it.
  function cancel(device) {
    if (!device) return;
    if (device.pairing) device.cancelPair();
    else if (device.state === BluetoothDeviceState.Connecting) device.disconnect();
  }

  // One click, whatever state the row is in: cancel what is in flight,
  // disconnect what is connected, connect what is bonded, pair the rest. The
  // pair-then-connect step is BluetoothPanel's, because only it can see the
  // pairing finish.
  function activate(device) {
    if (!device) return;
    if (root.isPending(device)) {
      root.cancel(device);
    } else if (device.connected) {
      device.disconnect();
    } else if (device.paired) {
      // Trust on the way in, which covers devices bonded before the panel
      // started doing this at pair time -- and anything paired with
      // `bluetoothctl`, which never sets it. See BluetoothPanel's
      // onPairingChanged for why an untrusted device cannot reconnect by
      // itself.
      if (!device.trusted) device.trusted = true;
      device.connect();
    } else {
      device.pair();
    }
  }

  function forget(device) { if (device) device.forget(); }
}
