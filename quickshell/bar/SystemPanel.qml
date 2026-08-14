pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// The detail behind the three read-only pills. All three open this one panel
// rather than one panel each: the numbers are read together -- a hot package is
// explained by the core grid above it, and a machine that is swapping is the
// reason the cores are busy -- and three panels would be three files saying
// what one column already fits.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false

  function toggle() { isOpen ? close() : open(); }
  function open()   { isOpen = true; }
  function close()  { isOpen = false; }

  // Everything on screen, filled by one pass of `sampler`.
  property real cpuBusy: 0
  property var cores: []
  property string loadAvg: ""
  property string tasks: ""
  property string cpuModel: ""
  property var mem: ({})
  property var sensors: []
  property var topCpu: []
  property var topMem: []

  function gb(kb) { return (kb / 1048576).toFixed(1) + "G"; }

  // Same band thresholds as the temperature pill, for the same reason: k10temp
  // here exposes neither _max nor _crit, so there is no ceiling to draw a scale
  // against and only "normal / warm / hot" can honestly be said.
  function tempColor(c) {
    return c >= 80 ? root.theme.accentRed
         : c >= 65 ? root.theme.accentOrange
         : root.theme.textSecondary;
  }

  IpcHandler {
    target: "system"
    function toggle(): void { root.toggle(); }
    function open(): void   { root.open(); }
    function close(): void  { root.close(); }
  }

  // One pass, one process. It forks ps twice and sleeps 400ms between two
  // /proc/stat reads, which is exactly the kind of work the always-on
  // SystemInfo singleton must never carry -- hence the timer below, which only
  // runs while the panel is on screen.
  //
  // The per-core delta is taken inside the script rather than against counters
  // kept in QML: two reads 400ms apart are a window you can name, where a
  // difference against whatever was last sampled would silently become "average
  // since the panel was last open" the moment it is reopened.
  //
  // ps %cpu is the process's average over its whole lifetime, not this window;
  // the caption on that list says so. That is also why both lists deselect this
  // shell's own children: a `ps` a few milliseconds old had spent all of it on
  // the CPU and led its own list at 500%.
  Process {
    id: sampler
    command: ["sh", "-c", `
      a=$(grep '^cpu' /proc/stat)
      sleep 0.4
      b=$(grep '^cpu' /proc/stat)
      printf '%s\\n=\\n%s\\n' "$a" "$b" | awk '
        /^=/ { s=1; next }
        !s   { i[$1]=$5+$6; for(k=2;k<=NF;k++) t[$1]+=$k; next }
             { ti=$5+$6; tt=0; for(k=2;k<=NF;k++) tt+=$k; d=tt-t[$1];
               printf "C %s %.1f\\n", $1, (d>0 ? 100*(1-(ti-i[$1])/d) : 0) }'
      awk '{ print "L", $1, $2, $3, $4 }' /proc/loadavg
      awk -F: '/^model name/ { gsub(/^ +| +$/, "", $2); print "N", $2; exit }' /proc/cpuinfo
      awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):/ { sub(/:/, "", $1); print "M", $1, $2 }' /proc/meminfo
      for f in /sys/class/hwmon/hwmon*/temp*_input; do
        [ -e "$f" ] || continue
        l=$(cat "$(echo "$f" | sed s/_input/_label/)" 2>/dev/null) || l=$(basename "$f" _input)
        printf 'T %s %s %s\\n' "$(cat "$(dirname "$f")/name" 2>/dev/null || echo hwmon)" "$(cat "$f")" "$l"
      done
      ps --ppid $$ --deselect -o pcpu,comm --no-headers --sort=-pcpu | head -3 | awk '{ $1=$1; print "P", $0 }'
      ps --ppid $$ --deselect -o rss,comm --no-headers --sort=-rss | head -3 | awk '{ $1=$1; print "R", $0 }'
    `]

    stdout: StdioCollector {
      onStreamFinished: {
        const cores = [], sensors = [], topCpu = [], topMem = [], mem = {};

        for (const line of text.trim().split("\n")) {
          const f = line.split(" ");
          switch (f[0]) {
            // "cpu" is the aggregate line, "cpuN" the individual threads, in
            // /proc/stat order -- printed as they are read, so the row of bars
            // below is in core order and does not reshuffle on every tick.
            case "C": if (f[1] === "cpu") root.cpuBusy = parseFloat(f[2]);
                      else cores.push(parseFloat(f[2]));
                      break;
            case "L": root.loadAvg = f[1] + "  ·  " + f[2] + "  ·  " + f[3];
                      root.tasks = f[4];
                      break;
            case "N": root.cpuModel = f.slice(1).join(" "); break;
            case "M": mem[f[1]] = parseInt(f[2]); break;
            case "T": sensors.push({ chip: f[1],
                                     celsius: Math.round(parseInt(f[2]) / 1000),
                                     label: f.slice(3).join(" ") });
                      break;
            case "P": topCpu.push({ name: f.slice(2).join(" "), value: f[1] + "%" }); break;
            case "R": topMem.push({ name: f.slice(2).join(" "), value: root.gb(parseInt(f[1])) }); break;
          }
        }

        root.cores = cores;
        root.sensors = sensors;
        root.topCpu = topCpu;
        root.topMem = topMem;
        root.mem = mem;
      }
    }
  }

  Timer {
    running: root.isOpen
    interval: 2000
    repeat: true
    triggeredOnStart: true
    onTriggered: sampler.running = true
  }

  Scrim { active: overlay.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: overlay
    visible: root.isOpen
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-system"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      width: 460
      // Taller than the other panels, which are all 560: three sections of
      // readouts is more than a list, and the point of the sensors section is
      // seeing every sensor at once rather than scrolling to it. Still short of
      // any laptop panel's height, and the Flickable below handles a machine
      // with more sensors than this one.
      height: 720
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
            name: "cpu-64-bit"
            color: root.theme.accentOrange
            size: 18
          }

          ColumnLayout {
            spacing: 0
            Text {
              text: "System"
              color: root.theme.textPrimary
              font { pixelSize: 13; bold: true; family: root.font }
            }
            Text {
              text: root.cpuModel === ""
                    ? "Sampling…"
                    : root.cpuModel + "  ·  " + root.cores.length + " threads"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
              elide: Text.ElideRight
              Layout.maximumWidth: 330
            }
          }

          Item { Layout.fillWidth: true }

          CloseButton {
            theme: root.theme
            font: root.font
            onClicked: root.close()
          }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.theme.bgBorder }

        Flickable {
          id: scroller
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: sections.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: sections
            // Bound to the Flickable rather than to `parent`, as in the audio
            // panel: a Flickable reparents its children into contentItem, whose
            // width stays 0.
            width: scroller.width
            // Tight, because most children here are single rows of a list. The
            // gap between sections is put back by the topMargin on each rule.
            spacing: 6

            Text {
              text: "CPU"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 12

              Accessible.role: Accessible.StaticText
              Accessible.name: "CPU " + Math.round(root.cpuBusy) + " percent, load average "
                               + root.loadAvg.replace(/·/g, "and") + ", " + root.tasks + " tasks"

              Text {
                text: Math.round(root.cpuBusy) + "%"
                color: root.theme.accentOrange
                font { pixelSize: 22; family: root.font }
              }

              ColumnLayout {
                spacing: 0
                Text {
                  text: "load  " + root.loadAvg
                  color: root.theme.textSecondary
                  font { pixelSize: 11; family: root.font }
                }
                Text {
                  // 3/4730: runnable over total. The pair says whether a high
                  // load average is work queued up or just a lot of sleeping
                  // processes.
                  text: root.tasks === "" ? "" : root.tasks.replace("/", " running of ") + " tasks"
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                }
              }
            }

            // One fill per thread, in core order. A row of bars rather than a
            // list of percentages: what you look for here is whether the load
            // is on one core or spread over all of them, and that is a shape,
            // not sixteen numbers.
            Item {
              Layout.fillWidth: true
              implicitHeight: 36

              Accessible.role: Accessible.StaticText
              Accessible.name: root.cores.length === 0 ? "Per-core usage, sampling"
                               : "Per-core usage, " + root.cores.length + " threads, busiest "
                                 + Math.round(Math.max.apply(null, root.cores)) + " percent"

              Row {
                id: coreRow
                anchors.fill: parent
                spacing: 4

                Repeater {
                  model: root.cores

                  FillBar {
                    required property real modelData

                    width: (coreRow.width - coreRow.spacing * (root.cores.length - 1))
                           / root.cores.length
                    height: coreRow.height
                    color: root.theme.bgSurface
                    value: modelData / 100
                    fillColor: modelData >= 90 ? root.theme.accentRed : root.theme.accentOrange
                  }
                }
              }
            }

            Text {
              text: "busiest  ·  ps averages each process over its own lifetime"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            Repeater {
              model: root.topCpu

              RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8

                Text {
                  Layout.fillWidth: true
                  text: parent.modelData.name
                  color: root.theme.textPrimary
                  font { pixelSize: 11; family: root.font }
                  elide: Text.ElideRight
                }
                Text {
                  text: parent.modelData.value
                  color: root.theme.textSecondary
                  font { pixelSize: 11; family: root.font }
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.topMargin: 6
              Layout.bottomMargin: 6
              Layout.preferredHeight: 1
              color: root.theme.bgBorder
            }

            Text {
              text: "Memory"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              Accessible.role: Accessible.StaticText
              Accessible.name: "Memory " + memUsedText.text + ", " + memAvailText.text

              Text {
                id: memUsedText
                // used = total - available, the same definition the bar pill
                // uses, and for the reason written out in SystemInfo: free(1)'s
                // "used" counts reclaimable page cache as gone.
                text: root.mem.MemTotal
                      ? root.gb(root.mem.MemTotal - root.mem.MemAvailable)
                        + " of " + root.gb(root.mem.MemTotal)
                      : "—"
                color: root.theme.textPrimary
                font { pixelSize: 13; family: root.font }
              }

              Item { Layout.fillWidth: true }

              Text {
                id: memAvailText
                text: root.mem.MemAvailable ? root.gb(root.mem.MemAvailable) + " available" : ""
                color: root.theme.textMuted
                font { pixelSize: 11; family: root.font }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 8
              radius: 4
              color: root.theme.bgSurface

              Rectangle {
                height: parent.height
                radius: parent.radius
                color: root.theme.accentCyan
                width: root.mem.MemTotal
                       ? parent.width * (1 - root.mem.MemAvailable / root.mem.MemTotal)
                       : 0

                Behavior on width { NumberAnimation { duration: 150 } }
              }
            }

            Text {
              text: root.mem.Cached
                    ? "cached " + root.gb(root.mem.Cached)
                      + "  ·  buffers " + root.gb(root.mem.Buffers)
                      + "  ·  free " + root.gb(root.mem.MemFree)
                    : ""
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 8
              // A machine with swap turned off has nothing to say here.
              visible: root.mem.SwapTotal > 0

              Accessible.role: Accessible.StaticText
              Accessible.name: "Swap " + swapText.text

              Text {
                id: swapText
                text: root.mem.SwapTotal
                      ? "swap " + root.gb(root.mem.SwapTotal - root.mem.SwapFree)
                        + " of " + root.gb(root.mem.SwapTotal)
                      : ""
                color: root.theme.textSecondary
                font { pixelSize: 11; family: root.font }
              }

              Item { Layout.fillWidth: true }

              Rectangle {
                Layout.preferredWidth: 160
                Layout.preferredHeight: 6
                radius: 3
                color: root.theme.bgSurface

                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  color: root.theme.accentPrimary
                  width: root.mem.SwapTotal
                         ? parent.width * (1 - root.mem.SwapFree / root.mem.SwapTotal)
                         : 0

                  Behavior on width { NumberAnimation { duration: 150 } }
                }
              }
            }

            Text {
              text: "largest  ·  resident set"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            Repeater {
              model: root.topMem

              RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8

                Text {
                  Layout.fillWidth: true
                  text: parent.modelData.name
                  color: root.theme.textPrimary
                  font { pixelSize: 11; family: root.font }
                  elide: Text.ElideRight
                }
                Text {
                  text: parent.modelData.value
                  color: root.theme.textSecondary
                  font { pixelSize: 11; family: root.font }
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.topMargin: 6
              Layout.bottomMargin: 6
              Layout.preferredHeight: 1
              color: root.theme.bgBorder
            }

            Text {
              // Every hwmon sensor, not just the CPU package the pill picks:
              // the disk, the GPU and both radios all report here, and which of
              // them is the hot one is the whole question when the fan is loud.
              text: "Sensors"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            Repeater {
              model: root.sensors

              RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8

                Accessible.role: Accessible.StaticText
                Accessible.name: modelData.chip + " " + modelData.label + ", "
                                 + modelData.celsius + " degrees"

                Icon {
                  name: "thermometer"
                  color: root.tempColor(parent.modelData.celsius)
                  size: 13
                }
                Text {
                  text: parent.modelData.label
                  color: root.theme.textPrimary
                  font { pixelSize: 11; family: root.font }
                }
                Text {
                  Layout.fillWidth: true
                  text: parent.modelData.chip
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                  elide: Text.ElideRight
                }
                Text {
                  text: parent.modelData.celsius + "°C"
                  color: root.tempColor(parent.modelData.celsius)
                  font { pixelSize: 11; family: root.font }
                }
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true

          Text {
            text: "sampled every 2s while open"
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
