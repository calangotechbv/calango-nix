pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
  id: root

  property string cpuUsage: "0%"
  property real cpuUsageRaw: 0
  property string memoryUsage: "0%"
  property int memoryUsageRaw: 0
  property string memoryUsedGb: "0.0G"
  property string memoryTotalGb: "0.0G"
  property string networkInfo: "Disconnected"
  property string networkType: "disconnected"
  // Hardware facts, probed once at startup rather than on every tick.
  property bool hasBattery: false
  property bool isLaptop: false

  property int batteryLevelRaw: 0
  property string batteryLevel: "0%"
  property string batteryIcon: "battery-outline"
  property bool batteryCharging: false
  property string temperature: "0°C"
  property int temperatureRaw: 0

  // CPU Usage
  Process {
    id: cpuProc
    command: ["sh", "-c", "top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1\"%\"}'"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        root.cpuUsage = text.trim()
        root.cpuUsageRaw = parseFloat(text) || 0
      }
    }
  }

  // Memory Usage, read straight from /proc/meminfo rather than parsed out of
  // free(1): no dependency on free's column layout or locale, and MemAvailable
  // is the kernel's own estimate of what a new allocation could actually claim.
  // free's "used" column instead reports total-free-buff/cache, which counts
  // reclaimable page cache as unavailable and so overstates pressure on a box
  // that has simply been up a while.
  // Emits three fields: percent, used GiB, total GiB.
  Process {
    id: memProc
    command: ["sh", "-c", "awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0)printf \"%d %.1f %.1f\", (t-a)*100/t, (t-a)/1048576, t/1048576}' /proc/meminfo"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        const parts = text.trim().split(" ")
        if (parts.length < 3) return

        root.memoryUsageRaw = parseInt(parts[0]) || 0
        root.memoryUsage = root.memoryUsageRaw + "%"
        root.memoryUsedGb = parts[1] + "G"
        root.memoryTotalGb = parts[2] + "G"
      }
    }
  }

  // Network Info (ethernet takes priority over wifi)
  Process {
    id: netProc
    command: ["sh", "-c", "eth=$(nmcli -t -f type,state dev 2>/dev/null | grep '^ethernet:connected'); if [ -n \"$eth\" ]; then echo 'ethernet:Ethernet'; else wifi=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2); if [ -n \"$wifi\" ]; then echo \"wifi:$wifi\"; else echo 'disconnected:'; fi; fi"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        const result = text.trim()
        const colonIdx = result.indexOf(':')
        const type = result.substring(0, colonIdx)
        const info = result.substring(colonIdx + 1)
        root.networkType = type
        root.networkInfo = info || "Disconnected"
      }
    }
  }

  // Hardware detection, run once. Two independent questions:
  //
  //   hasBattery -- is there a system battery to report on? This is what gates
  //     the bar indicator, because it answers exactly what the widget needs.
  //     Chassis type alone would be wrong for a laptop running with the battery
  //     removed, or on a desktop with a UPS.
  //   isLaptop -- SMBIOS chassis type, kept separate because it is the right
  //     signal for things like whether a lid or internal panel backlight exists.
  //
  // The battery scan skips scope=Device supplies: wireless mice and headsets
  // register as power supplies too, and reporting a mouse as "the battery"
  // would be worse than showing nothing.
  //
  // When /sys/class/power_supply is empty the glob stays literal, so the -e
  // test fails and the loop correctly falls through with b=0.
  Process {
    id: detectProc
    command: ["sh", "-c", "b=0; for p in /sys/class/power_supply/*; do [ -e \"$p/type\" ] || continue; [ \"$(cat $p/type)\" = Battery ] || continue; [ \"$(cat $p/scope 2>/dev/null)\" = Device ] && continue; b=1; break; done; printf '%s %s' \"$b\" \"$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 2)\""]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        const parts = text.trim().split(" ")
        root.hasBattery = parts[0] === "1"

        // 8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 14 Sub Notebook,
        // 30 Tablet, 31 Convertible, 32 Detachable.
        const chassis = parseInt(parts[1]) || 2
        root.isLaptop = [8, 9, 10, 11, 14, 30, 31, 32].indexOf(chassis) !== -1

        // Take the first reading immediately instead of waiting out a tick.
        if (root.hasBattery) batteryProc.running = true
      }
    }
  }

  // Battery. Only ever started when detectProc found one, so there is no
  // fabricated fallback here -- the previous version substituted a hardcoded
  // "99" / "Discharging" whenever the read failed, which is why a machine with
  // no battery at all still showed a confident 99% in the bar.
  Process {
    id: batteryProc
    command: ["sh", "-c", "printf '%s\\n%s' \"$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null)\" \"$(cat /sys/class/power_supply/BAT*/status 2>/dev/null)\""]
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.trim().split("\n")
        const level = parseInt(lines[0])
        if (isNaN(level)) return

        const status = (lines[1] || "Unknown").trim()

        root.batteryLevelRaw = level
        root.batteryLevel = level + "%"
        root.batteryCharging = status === "Charging"

        // Icon names for common/Icon.qml. Each bucket rounds up to the next
        // notch, as it always has: 85% draws battery-90, 15% draws battery-20.
        if (root.batteryCharging) root.batteryIcon = "battery-charging"
        else if (level >= 90) root.batteryIcon = "battery"
        else if (level >= 80) root.batteryIcon = "battery-90"
        else if (level >= 70) root.batteryIcon = "battery-80"
        else if (level >= 60) root.batteryIcon = "battery-70"
        else if (level >= 50) root.batteryIcon = "battery-60"
        else if (level >= 40) root.batteryIcon = "battery-50"
        else if (level >= 30) root.batteryIcon = "battery-40"
        else if (level >= 20) root.batteryIcon = "battery-30"
        else if (level >= 10) root.batteryIcon = "battery-20"
        else root.batteryIcon = "battery-10"
      }
    }
  }

  // Temperature, read from hwmon rather than shelling out to sensors(1).
  // lm_sensors is not installed here, so the old pipeline produced nothing and
  // the bar showed a permanent "N/A" -- and it failed silently, because the
  // `|| echo N/A` could never fire: sed exits 0 on empty input, so the pipeline
  // always "succeeded" with an empty result.
  //
  // Picks the CPU package sensor by label (Tctl on AMD k10temp, Package id 0 on
  // Intel coretemp), which skips the NVMe and GPU sensors that also live under
  // hwmon. Falls back to the first available sensor if no CPU label matches.
  // Values are millidegrees; +500 before integer truncation rounds to nearest.
  Process {
    id: tempProc
    command: ["sh", "-c", "f=$(grep -lE '^(Tctl|Tdie|Package id 0)$' /sys/class/hwmon/hwmon*/temp*_label 2>/dev/null | head -1); if [ -n \"$f\" ]; then f=${f%_label}_input; else f=$(ls /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -1); fi; [ -n \"$f\" ] && awk '{printf \"%d\", ($1+500)/1000}' $f"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (isNaN(v)) {
          root.temperature = "N/A"
          root.temperatureRaw = 0
          return
        }
        root.temperatureRaw = v
        root.temperature = v + "°C"
      }
    }
  }

  // Update timer
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      cpuProc.running = true
      memProc.running = true
      netProc.running = true
      if (root.hasBattery) batteryProc.running = true
      tempProc.running = true
    }
  }
}
