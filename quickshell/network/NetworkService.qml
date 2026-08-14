pragma Singleton

import Quickshell
import Quickshell.Networking
import QtQuick

// NetworkManager state, via Quickshell's built-in Networking module rather than
// polling `nmcli`. Everything here is event-driven -- NM pushes changes over
// D-Bus, so there is no refresh timer.
Singleton {
  id: root

  // The Networking backend only spins up once its models are observed by a
  // declarative binding. Reading Networking.devices.values from imperative JS
  // (inside a function or Component.onCompleted) yields an empty list and the
  // backend never initialises. This binding is load-bearing -- do not inline it
  // into the functions below.
  readonly property var devices: Networking.devices ? Networking.devices.values : []

  readonly property bool available: Networking.backend === NetworkBackendType.NetworkManager
  readonly property bool wifiEnabled: Networking.wifiEnabled
  readonly property bool wifiHardwareEnabled: Networking.wifiHardwareEnabled
  readonly property int  connectivity: Networking.connectivity

  readonly property var wiredDevice: devices.find(d => d.type === DeviceType.Wired) ?? null

  // Prefer a connected wifi radio; fall back to the first one so the panel still
  // lists networks while disconnected. This box has one, wlo1 -- the find/??
  // pair is for machines that have more, not for this one.
  readonly property var wifiDevice: {
    const wifis = devices.filter(d => d.type === DeviceType.Wifi);
    return wifis.find(d => d.connected) ?? wifis[0] ?? null;
  }

  readonly property bool wiredConnected: wiredDevice !== null && wiredDevice.connected
  readonly property bool wifiConnected:  wifiDevice  !== null && wifiDevice.connected

  readonly property var activeNetwork: {
    if (!wifiDevice || !wifiDevice.networks) return null;
    return wifiDevice.networks.values.find(n => n.connected) ?? null;
  }

  // Visible networks, best first: connected, then saved, then by signal.
  readonly property var wifiNetworks: {
    if (!wifiDevice || !wifiDevice.networks) return [];
    const list = wifiDevice.networks.values.slice();
    list.sort((a, b) =>
      (b.connected - a.connected)
      || (b.known - a.known)
      || (b.signalStrength - a.signalStrength));
    return list;
  }

  // ethernet wins over wifi, matching how the bar has always reported it
  readonly property string kind:
    wiredConnected ? "ethernet" : (wifiConnected ? "wifi" : "disconnected")

  readonly property string label: {
    if (wiredConnected) return "Ethernet";
    if (wifiConnected)  return activeNetwork ? activeNetwork.name : "Wi-Fi";
    return "Disconnected";
  }

  readonly property real signalStrength:
    (wifiConnected && activeNetwork) ? activeNetwork.signalStrength : 0

  // Icon names for common/Icon.qml, not glyphs.
  readonly property string icon: {
    if (wiredConnected) return "ethernet";
    if (!wifiEnabled)   return "wifi-off";
    if (!wifiConnected) return "wifi-off";
    return NetworkService.strengthIcon(signalStrength);
  }

  // Shared with NetworkPanel's scan-result rows, which drew the same four-step
  // ramp from its own copy of these thresholds.
  function strengthIcon(strength) {
    if (strength >= 0.75) return "wifi-strength-4";
    if (strength >= 0.50) return "wifi-strength-3";
    if (strength >= 0.25) return "wifi-strength-2";
    return "wifi-strength-1";
  }

  // A captive portal or a link with no route still reads as "connected" on the
  // device, so surface it separately rather than lying in the bar.
  readonly property bool limited:
    (wiredConnected || wifiConnected)
    && connectivity !== NetworkConnectivity.Full
    && connectivity !== NetworkConnectivity.Unknown

  function securityLabel(net) {
    if (!net) return "";
    switch (net.security) {
      case WifiSecurityType.Open:          return "Open";
      case WifiSecurityType.Owe:           return "Enhanced Open";
      case WifiSecurityType.Sae:           return "WPA3";
      case WifiSecurityType.Wpa3SuiteB192: return "WPA3 Enterprise";
      case WifiSecurityType.Wpa2Psk:       return "WPA2";
      case WifiSecurityType.WpaPsk:        return "WPA";
      case WifiSecurityType.Wpa2Eap:
      case WifiSecurityType.WpaEap:        return "Enterprise";
      case WifiSecurityType.StaticWep:
      case WifiSecurityType.DynamicWep:    return "WEP";
      case WifiSecurityType.Leap:          return "LEAP";
      default:                             return "";
    }
  }

  function isOpen(net) {
    return net && (net.security === WifiSecurityType.Open
                || net.security === WifiSecurityType.Owe);
  }

  // A saved network reconnects without asking; an unsaved secured one needs a key.
  function needsPassword(net) {
    return net !== null && !net.known && !isOpen(net);
  }

  // Scanning costs power, so it is only on while something is looking at the
  // list. The panel drives this.
  property bool scanning: false

  Binding {
    target:   root.wifiDevice
    property: "scannerEnabled"
    value:    root.scanning
    when:     root.wifiDevice !== null
  }

  function connectTo(net, psk) {
    if (!net) return;
    if (psk !== undefined && psk !== "") net.connectWithPsk(psk);
    else net.connect();
  }

  function disconnectFrom(net) {
    if (net) net.disconnect();
    else if (wifiDevice) wifiDevice.disconnect();
  }

  function forget(net) {
    if (net) net.forget();
  }
}
