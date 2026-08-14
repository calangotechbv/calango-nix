pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

// Display brightness, over whichever mechanism the machine actually has.
//
// Two backends, because they are not alternatives so much as different
// hardware. A laptop panel has a kernel backlight device under
// /sys/class/backlight and is written through brightnessctl. An external
// monitor has none: brightness lives in the monitor's own firmware and is
// reached over DDC/CI, the I2C side-channel in the display cable, which is what
// ddcutil speaks. This box is the second kind -- two AOC U27B3A panels, no
// backlight device at all -- and the bar pill and OSD both keyed off sysfs, so
// both quietly hid themselves and there was no way to set brightness from the
// shell.
//
// sysfs wins when both are possible: it is a file write rather than a bus
// transaction, and the kernel tells us when something else changes it.
Singleton {
  id: root

  // "" until discovery finishes, and on a machine with neither backend. The
  // pill keys off `available` rather than probing anything itself.
  property string mode: ""
  readonly property bool available: root.mode !== ""

  // 0-100, shared across every display. Set optimistically, before the write
  // lands, so the readout tracks the scroll wheel instead of the bus.
  property int percent: 0

  // Fired only for changes this service was asked to make. The OSD shows itself
  // on this rather than on percentChanged, which would also fire for the
  // initial read at startup.
  signal userChanged()

  // --- sysfs backend -------------------------------------------------------

  // The device *name*, not the path: `brightnessctl` without -d defaults to
  // class "backlight" and, when that class is empty, falls through to the first
  // device of any class it can find -- which on this machine is
  // `input1::numlock`. A brightness key press turned the numlock LED on. Naming
  // the device means that can never happen, whatever the machine has.
  property string sysfsDevice: ""
  property int sysfsMax: 1

  // --- DDC backend ---------------------------------------------------------

  // I2C bus numbers that answered a brightness read. Kept as numbers, since
  // every ddcutil call addresses `--bus N`.
  property var busses: []

  // Measured on this machine: `--display N` costs 490-910ms because ddcutil
  // re-enumerates every display first, while `--bus N` is 70-90ms to read and
  // 130-180ms to write. Ten times faster, and the difference between a pill
  // that tracks the wheel and one that lurches. Lowering --sleep-multiplier
  // made it slower, not faster (retries), so the timing defaults stay.

  function set(value) {
    const clamped = Math.max(0, Math.min(100, Math.round(value)));
    if (!root.available) return;
    root.percent = clamped;
    root.userChanged();
    writeDebounce.restart();
  }

  function step(delta) { root.set(root.percent + delta); }

  function _writeCommand() {
    if (root.mode === "backlight")
      return ["brightnessctl", "-d", root.sysfsDevice, "-n1", "set", root.percent + "%"];

    // One shell over every bus rather than a process each: writes to the same
    // bus must not overlap, and sequencing them here keeps that true without a
    // queue. --noverify skips the read-back ddcutil does by default, which is a
    // second bus round trip for a value we are about to overwrite anyway.
    return ["sh", "-c",
            'v=$1; shift; for b in "$@"; do ddcutil --bus "$b" --noverify setvcp 10 "$v" >/dev/null 2>&1 || exit 1; done',
            "sh", String(root.percent)].concat(root.busses.map(String));
  }

  // Coalesces a burst of wheel events into one bus transaction. 120ms is under
  // the 130-180ms a DDC write takes, so a steady scroll stays saturated rather
  // than gapped, and a flick still only writes once.
  Timer {
    id: writeDebounce
    interval: root.mode === "ddc" ? 120 : 0
    repeat: false
    onTriggered: {
      // A write already in flight: come back rather than starting a second one
      // on the same bus.
      if (writeProc.running) { writeDebounce.restart(); return; }
      writeProc.command = root._writeCommand();
      writeProc.running = true;
    }
  }

  Process {
    id: writeProc
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim() !== "") console.warn("BrightnessService write:", text.trim());
      }
    }
  }

  // One discovery pass covering both backends, so the shell only pays for the
  // one it has. Measured at 0.86s here, which is why it is async and why
  // nothing else waits on it: the pill is simply absent until it answers.
  Process {
    id: discovery
    running: true
    command: ["sh", "-c", `
      p=$(ls -d /sys/class/backlight/*/brightness 2>/dev/null | head -1)
      if [ -n "$p" ]; then
        d=\${p%/brightness}
        printf 'backlight %s %s %s\\n' "\${d##*/}" "$(cat "$d/max_brightness")" "$(cat "$p")"
        exit 0
      fi
      command -v ddcutil >/dev/null 2>&1 || exit 0
      # detect lists only displays that answered, so an i2c bus belonging to
      # something else never reaches the loop. The getvcp is still worth doing:
      # a monitor can be present and report no brightness control.
      ddcutil detect --brief 2>/dev/null | sed -n 's|^ *I2C bus: */dev/i2c-||p' | while read -r b; do
        v=$(ddcutil --bus "$b" getvcp 10 --brief 2>/dev/null) || continue
        case "$v" in
          "VCP 10 C "*) set -- $v; printf 'ddc %s %s %s\\n' "$b" "$4" "$5" ;;
        esac
      done
    `]
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.trim().split("\n").filter(l => l.trim() !== "");
        if (lines.length === 0) return; // no backlight, no DDC monitor, or no ddcutil

        const ddc = [];
        let readings = [];

        for (const line of lines) {
          const parts = line.trim().split(/\s+/);
          if (parts[0] === "backlight" && parts.length >= 4) {
            const max = parseInt(parts[2]);
            const cur = parseInt(parts[3]);
            if (isNaN(max) || max <= 0 || isNaN(cur)) continue;
            root.sysfsDevice = parts[1];
            root.sysfsMax = max;
            root.percent = Math.round(cur / max * 100);
            root.mode = "backlight";
            return;
          }
          if (parts[0] === "ddc" && parts.length >= 4) {
            const bus = parseInt(parts[1]);
            const cur = parseInt(parts[2]);
            const max = parseInt(parts[3]);
            if (isNaN(bus) || isNaN(cur) || isNaN(max) || max <= 0) continue;
            ddc.push(bus);
            readings.push(cur / max * 100);
          }
        }

        if (ddc.length === 0) return;
        root.busses = ddc;
        // Monitors set independently start at different levels -- 74 and 58
        // here. There is one shared value from now on, so the average is the
        // least surprising place to start: the first adjustment collapses them
        // either way, and starting from one panel's value would jump the other.
        root.percent = Math.round(readings.reduce((a, b) => a + b, 0) / readings.length);
        root.mode = "ddc";
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim() !== "") console.warn("BrightnessService discovery:", text.trim());
      }
    }
  }

  // Only the sysfs backend can be changed behind our back -- by another
  // brightnessctl, or by the firmware on a laptop lid key. DDC has no such
  // channel: nothing reports a monitor's OSD buttons, so `percent` is only ever
  // what this service last wrote.
  FileView {
    id: sysfsWatch
    path: root.mode === "backlight"
          ? "/sys/class/backlight/" + root.sysfsDevice + "/brightness" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: sysfsRead.running = true
  }

  Process {
    id: sysfsRead
    running: false
    command: ["brightnessctl", "-d", root.sysfsDevice, "get"]
    stdout: StdioCollector {
      onStreamFinished: {
        const val = parseInt(text.trim());
        if (!isNaN(val) && root.sysfsMax > 0)
          root.percent = Math.round(val / root.sysfsMax * 100);
      }
    }
  }

  IpcHandler {
    target: "brightness"

    // What the XF86MonBrightness keys are bound to. Five points a press, which
    // is what the bar pill's wheel uses.
    function up(): void   { root.step(5); }
    function down(): void { root.step(-5); }

    function set(percent: int): void { root.set(percent); }

    function status(): string {
      if (!root.available) return "no brightness control found";
      return root.percent + "%, over "
        + (root.mode === "ddc" ? "DDC/CI on " + root.busses.length + " display(s)"
                               : "the " + root.sysfsDevice + " backlight");
    }
  }
}
