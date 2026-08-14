pragma Singleton

import Quickshell
import Quickshell.Services.UPower
import QtQuick

// Power profiles via Quickshell's native UPower binding -- no shelling out.
//
// The powerprofilesctl CLI is not installed on this machine; what backs this is
// tuned-ppd, which publishes the same net.hadess.PowerProfiles D-Bus interface
// that power-profiles-daemon does. Quickshell talks to that interface directly,
// so the binding works regardless of which daemon is providing it.
//
// Switching is allowed for the active local session without authentication
// (allow_active=yes in the polkit policy), so clicking never raises a prompt --
// which matters, because there is no polkit agent wired up under Hyprland here.
Singleton {
  id: root

  readonly property int profile: PowerProfiles.profile

  // Performance is not offered on every machine, so it must not be assumed to
  // exist when cycling -- otherwise one step of the cycle silently does nothing.
  readonly property var order: PowerProfiles.hasPerformanceProfile
    ? [PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance]
    : [PowerProfile.PowerSaver, PowerProfile.Balanced]

  readonly property string label: {
    switch (profile) {
      case PowerProfile.PowerSaver:  return "Power Saver";
      case PowerProfile.Performance: return "Performance";
      default:                       return "Balanced";
    }
  }

  // Leaf / gauge / speedometer, as icon names for common/Icon.qml.
  readonly property string icon: {
    switch (profile) {
      case PowerProfile.PowerSaver:  return "leaf";
      case PowerProfile.Performance: return "speedometer";
      default:                       return "gauge";
    }
  }

  // The firmware can throttle back regardless of the requested profile. Surface
  // that rather than showing "Performance" while the hardware ignores it.
  readonly property bool degraded:
    PowerProfiles.degradationReason !== PerformanceDegradationReason.None

  readonly property string degradationText: {
    switch (PowerProfiles.degradationReason) {
      case PerformanceDegradationReason.LapDetected:     return "lap detected";
      case PerformanceDegradationReason.HighTemperature: return "high temperature";
      default:                                           return "";
    }
  }

  // step of +1/-1; wraps in both directions.
  function cycle(step) {
    const list = root.order;
    const n = list.length;
    if (n === 0) return;

    let i = list.indexOf(root.profile);
    if (i < 0) i = 0;

    PowerProfiles.profile = list[((i + step) % n + n) % n];
  }

}
