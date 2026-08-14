pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// Every icon the shell draws, in every state, before any of it is swapped in.
//
// The point of moving off Nerd Font glyphs is that a glyph brings its own
// advance width with it: bell and bell-off are not the same width, so toggling
// do-not-disturb shifted every pill to its right. The drift meter at the top
// of this panel is that bug, reproduced on demand -- watch the px readouts as
// the states cycle.
//
// Open with `qs ipc call icons toggle`. Throwaway once the sweep lands, but
// the glyph column doubles as the lookup table for doing the sweep.
Scope {
  id: root

  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool isOpen: false
  property int iconSize: 16
  property bool showGlyphs: true

  function open()   { root.isOpen = true; }
  function close()  { root.isOpen = false; }
  function toggle() { root.isOpen = !root.isOpen; }

  IpcHandler {
    target: "icons"

    function toggle(): void { root.toggle(); }
    function open(): void   { root.open(); }
    function close(): void  { root.close(); }
  }

  // The Nerd Font codepoint each icon replaces, as actually written in the
  // shell today. Kept as numbers because these live above the BMP, where a
  // four-digit \u escape cannot reach them.
  //
  // A 0 means the interface has no glyph for it today: google-chrome and
  // console are literal empty strings in NotificationPopup.qml, so those
  // notifications render a blank space right now.
  readonly property var glyphs: ({
    "volume-off": 0xF0581, "volume-low": 0xF057F, "volume-medium": 0xF0580,
    "volume-high": 0xF057E, "volume-mute": 0xF075F,
    "microphone": 0xF036C, "microphone-off": 0xF036D,
    "bell": 0xF009A, "bell-outline": 0xF009C, "bell-off": 0xF009B,
    "battery": 0xF0079, "battery-90": 0xF0082, "battery-80": 0xF0081,
    "battery-70": 0xF0080, "battery-60": 0xF007F, "battery-50": 0xF007E,
    "battery-40": 0xF007D, "battery-30": 0xF007C, "battery-20": 0xF007B,
    "battery-10": 0xF007A, "battery-outline": 0xF008E, "battery-charging": 0xF1E6,
    "ethernet": 0xF0200, "wifi-off": 0xF05AA, "wifi-strength-1": 0xF091F,
    "wifi-strength-2": 0xF0922, "wifi-strength-3": 0xF0925, "wifi-strength-4": 0xF0928,
    "bluetooth": 0xF00AF, "bluetooth-off": 0xF00B2, "bluetooth-connect": 0xF00B1,
    "headset": 0xF02CD, "headphones": 0xF02CB, "speaker": 0xF04C3,
    "mouse": 0xF037D, "keyboard": 0xF030C, "gamepad-variant": 0xF02A4,
    "tablet": 0xF04F7, "cellphone": 0xF011C, "laptop": 0xF0322,
    "printer": 0xF042A, "camera": 0xF0100, "television": 0xF0502,
    "leaf": 0xF032A, "speedometer": 0xF04C5, "gauge": 0xF029A,
    "play": 0xF040A, "pause": 0xF03E4, "music": 0xF075A,
    "cpu-64-bit": 0xF0EE0, "memory": 0xF035B, "thermometer": 0xF050F,
    "brightness-7": 0xF00E0,
    "coffee": 0xF0176, "coffee-off": 0xF0FAE,
    "delete": 0xF01B4, "close": 0xF0156, "refresh": 0xF0450, "check": 0xF012C,
    "checkbox-blank-circle-outline": 0xF0764, "power": 0xF0425, "cog": 0xF0493,
    "stop": 0xF04DB,
    "monitor": 0xF0379, "monitor-multiple": 0xF037A, "format-paint": 0xF027C,
    "rotate-left": 0xF0465, "rotate-right": 0xF0467, "screen-rotation": 0xF10E8,
    "image": 0xF02E9, "clipboard-text": 0xF014D, "wallpaper": 0xF0E09,
    "auto-fix": 0xF0068,
    "lock": 0xF033E, "sleep": 0xF04B2, "logout": 0xF0343, "restart": 0xF0709,
    "firefox": 0xF0239, "google-chrome": 0, "spotify": 0xF04C7, "console": 0,
    "alert": 0xF0026,
    "keyboard-return": 0x23CE, "arrow-up": 0x2191, "arrow-down": 0x2193,
    "arrow-left": 0x2190, "arrow-right": 0x2192, "arrow-left-right": 0x2194,
    "menu-up": 0x25B4, "menu-down": 0x25BE, "infinity": 0x221E
  })

  function glyphFor(name) {
    const cp = root.glyphs[name];
    return cp ? String.fromCodePoint(cp) : "";
  }

  // The state ramps, with the condition each step fires on, so the panel can
  // be read against the code rather than just admired. Conditions copied from
  // the expressions that pick them today.
  readonly property var ramps: [
    {
      title: "Volume",
      note: "same ramp written three times: AudioService, Bar, OSD",
      steps: [
        { n: "volume-off",    l: "muted or 0" },
        { n: "volume-low",    l: "< 33%" },
        { n: "volume-medium", l: "< 66%" },
        { n: "volume-high",   l: "≥ 66%" },
        { n: "volume-mute",   l: "per-device mute" }
      ]
    },
    {
      title: "Battery",
      note: "SystemInfo -- each bucket rounds up to the next notch: 85% draws battery-90, 15% draws battery-20",
      steps: [
        { n: "battery-charging", l: "charging" },
        { n: "battery",          l: "≥ 90%" },
        { n: "battery-90",       l: "≥ 80%" },
        { n: "battery-80",       l: "≥ 70%" },
        { n: "battery-70",       l: "≥ 60%" },
        { n: "battery-60",       l: "≥ 50%" },
        { n: "battery-50",       l: "≥ 40%" },
        { n: "battery-40",       l: "≥ 30%" },
        { n: "battery-30",       l: "≥ 20%" },
        { n: "battery-20",       l: "≥ 10%" },
        { n: "battery-10",       l: "< 10%" },
        { n: "battery-outline",  l: "unknown" }
      ]
    },
    {
      title: "Network",
      note: "NetworkService, and the same wifi ramp again in NetworkPanel rows",
      steps: [
        { n: "ethernet",        l: "wired" },
        { n: "wifi-off",        l: "off / not connected" },
        { n: "wifi-strength-1", l: "< 25%" },
        { n: "wifi-strength-2", l: "≥ 25%" },
        { n: "wifi-strength-3", l: "≥ 50%" },
        { n: "wifi-strength-4", l: "≥ 75%" }
      ]
    },
    {
      title: "Bluetooth",
      note: "BluetoothService.icon",
      steps: [
        { n: "bluetooth-off",     l: "adapter off" },
        { n: "bluetooth",         l: "on, idle" },
        { n: "bluetooth-connect", l: "device connected" }
      ]
    },
    {
      title: "Notifications",
      note: "the swap this panel exists for -- three widths, one pill",
      steps: [
        { n: "bell-outline", l: "idle" },
        { n: "bell",         l: "unread" },
        { n: "bell-off",     l: "do not disturb" }
      ]
    },
    {
      title: "Microphone",
      note: "AudioService.inputIcon",
      steps: [
        { n: "microphone",     l: "live" },
        { n: "microphone-off", l: "muted" }
      ]
    },
    {
      title: "Power profile",
      note: "PowerProfileService.icon",
      steps: [
        { n: "leaf",        l: "power-saver" },
        { n: "gauge",       l: "balanced" },
        { n: "speedometer", l: "performance" }
      ]
    },
    {
      title: "Idle inhibit",
      note: "IdleService.icon",
      steps: [
        { n: "coffee-off", l: "not inhibited" },
        { n: "coffee",     l: "inhibited" }
      ]
    },
    {
      title: "Monitor rotation",
      note: "MonitorPanel -- 180° had no honest glyph, screen-rotation is the nearest MDI has",
      steps: [
        { n: "monitor",         l: "0°" },
        { n: "rotate-right",    l: "90°" },
        { n: "screen-rotation", l: "180°" },
        { n: "rotate-left",     l: "270°" }
      ]
    }
  ]

  // Drives the drift meter. Cycles the bell and volume states the bar really
  // does toggle between.
  readonly property var driftStates: ["bell-outline", "bell", "bell-off",
                                      "volume-high", "volume-medium",
                                      "volume-low", "volume-off"]
  property int driftIndex: 0
  readonly property string driftName: root.driftStates[root.driftIndex]

  Timer {
    running: root.isOpen
    interval: 900
    repeat: true
    onTriggered: root.driftIndex = (root.driftIndex + 1) % root.driftStates.length
  }

  Scrim { active: overlay.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: overlay
    visible: root.isOpen
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-icon-gallery"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      // Tall enough to be worth scrolling, short enough to fit a laptop panel.
      width: Math.min(940, overlay.width - 80)
      height: Math.min(760, overlay.height - 80)
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

        // ---- Header ------------------------------------------------------
        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Icon {
            name: "auto-fix"
            color: root.theme.accentPrimary
            size: 18
          }

          ColumnLayout {
            spacing: 0
            Text {
              text: "Icon gallery"
              color: root.theme.textPrimary
              font { pixelSize: 13; bold: true; family: root.font }
            }
            Text {
              text: Object.keys(Icons.paths).length + " icons · "
                    + root.ramps.length + " state ramps"
              color: root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "size"
            color: root.theme.textMuted
            font { pixelSize: 10; family: root.font }
          }

          Repeater {
            model: [12, 14, 16, 18, 24, 32]

            Rectangle {
              id: sizeChip
              required property int modelData

              implicitWidth: 26
              implicitHeight: 22
              radius: 6
              color: root.iconSize === sizeChip.modelData ? root.theme.bgSelected
                   : sizeArea.containsMouse                ? root.theme.bgHover
                   : "transparent"

              Text {
                anchors.centerIn: parent
                text: sizeChip.modelData
                color: root.iconSize === sizeChip.modelData ? root.theme.textPrimary
                                                            : root.theme.textMuted
                font { pixelSize: 10; family: root.font }
              }

              MouseArea {
                id: sizeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.iconSize = sizeChip.modelData
              }
            }
          }

          Rectangle {
            implicitWidth: 92
            implicitHeight: 22
            radius: 6
            color: root.showGlyphs           ? root.theme.bgSelected
                 : glyphArea.containsMouse   ? root.theme.bgHover
                 : "transparent"

            Text {
              anchors.centerIn: parent
              text: "font glyphs"
              color: root.showGlyphs ? root.theme.textPrimary : root.theme.textMuted
              font { pixelSize: 10; family: root.font }
            }

            MouseArea {
              id: glyphArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showGlyphs = !root.showGlyphs
            }
          }

          CloseButton {
            theme: root.theme
            font: root.font
            onClicked: root.close()
          }
        }

        // ---- Drift meter -------------------------------------------------
        // Two mock bar pills, both hugging their content the way the real
        // pills do, both cycling the same states. The px readouts are the
        // whole argument: one number moves, the other does not.
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: driftCol.implicitHeight + 20
          radius: 10
          color: root.theme.bgSurface

          ColumnLayout {
            id: driftCol
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8

            Text {
              text: "Layout drift — same pill, same states, both cycling"
              color: root.theme.textSecondary
              font { pixelSize: 11; bold: true; family: root.font }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 20

              ColumnLayout {
                spacing: 4

                Rectangle {
                  id: glyphPill
                  implicitWidth: glyphRow.implicitWidth + 20
                  implicitHeight: 26
                  radius: 13
                  color: root.theme.bgBase
                  border.color: root.theme.bgBorder
                  border.width: 1

                  RowLayout {
                    id: glyphRow
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                      text: root.glyphFor(root.driftName)
                      color: root.theme.accentPrimary
                      font { pixelSize: 14; family: root.font }
                    }
                    Text {
                      text: "42%"
                      color: root.theme.textPrimary
                      font { pixelSize: 12; family: root.font }
                    }
                  }
                }

                Text {
                  text: "font glyph — " + glyphPill.width.toFixed(1) + "px"
                  color: root.theme.accentOrange
                  font { pixelSize: 10; family: root.font }
                }
              }

              ColumnLayout {
                spacing: 4

                Rectangle {
                  id: svgPill
                  implicitWidth: svgRow.implicitWidth + 20
                  implicitHeight: 26
                  radius: 13
                  color: root.theme.bgBase
                  border.color: root.theme.bgBorder
                  border.width: 1

                  RowLayout {
                    id: svgRow
                    anchors.centerIn: parent
                    spacing: 6

                    Icon {
                      name: root.driftName
                      color: root.theme.accentPrimary
                      size: 14
                    }
                    Text {
                      text: "42%"
                      color: root.theme.textPrimary
                      font { pixelSize: 12; family: root.font }
                    }
                  }
                }

                Text {
                  text: "svg — " + svgPill.width.toFixed(1) + "px"
                  color: root.theme.accentGreen
                  font { pixelSize: 10; family: root.font }
                }
              }

              Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: "now: " + root.driftName
                color: root.theme.textMuted
                font { pixelSize: 10; family: root.font }
              }
            }
          }
        }

        // ---- Scrolling body ----------------------------------------------
        Flickable {
          id: body
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: bodyCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: bodyCol
            // Bound to the Flickable, not to `parent`: a Flickable reparents
            // its children into contentItem, whose width is contentWidth and
            // so would feed straight back into this binding.
            width: body.width
            spacing: 14

            Text {
              text: "State ramps"
              color: root.theme.textPrimary
              font { pixelSize: 12; bold: true; family: root.font }
            }

            Repeater {
              model: root.ramps

              ColumnLayout {
                id: rampGroup
                required property var modelData

                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8

                  Text {
                    text: rampGroup.modelData.title
                    color: root.theme.accentCyan
                    font { pixelSize: 11; bold: true; family: root.font }
                  }
                  Text {
                    Layout.fillWidth: true
                    text: rampGroup.modelData.note
                    color: root.theme.textMuted
                    font { pixelSize: 9; family: root.font }
                    elide: Text.ElideRight
                  }
                }

                Flow {
                  Layout.fillWidth: true
                  spacing: 6

                  Repeater {
                    model: rampGroup.modelData.steps

                    Rectangle {
                      id: step
                      required property var modelData

                      width: stepCell.implicitWidth + 16
                      height: stepCell.implicitHeight + 12
                      radius: 8
                      color: root.theme.bgSurface

                      ColumnLayout {
                        id: stepCell
                        anchors.centerIn: parent
                        spacing: 3

                        RowLayout {
                          Layout.alignment: Qt.AlignHCenter
                          spacing: 8

                          Icon {
                            name: step.modelData.n
                            color: root.theme.textPrimary
                            size: root.iconSize
                          }

                          // Invisible items are skipped by RowLayout, so the
                          // cell tightens up when the glyph column is off.
                          Text {
                            visible: root.showGlyphs
                            text: root.glyphFor(step.modelData.n) || "—"
                            color: root.theme.textMuted
                            font { pixelSize: root.iconSize; family: root.font }
                          }
                        }

                        Text {
                          Layout.alignment: Qt.AlignHCenter
                          text: step.modelData.l
                          color: root.theme.textSecondary
                          font { pixelSize: 9; family: root.font }
                        }

                        // Red name means the ramp asks for an icon that is not
                        // in Icons.paths -- an unknown name draws nothing, so
                        // without this a typo just looks like an empty cell.
                        Text {
                          Layout.alignment: Qt.AlignHCenter
                          text: step.modelData.n
                          color: Icons.has(step.modelData.n) ? root.theme.textMuted
                                                             : root.theme.accentRed
                          font { pixelSize: 8; family: root.font }
                        }
                      }
                    }
                  }
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 1
              color: root.theme.bgBorder
            }

            Text {
              text: "Everything else, by group"
              color: root.theme.textPrimary
              font { pixelSize: 12; bold: true; family: root.font }
            }

            Repeater {
              model: Object.keys(Icons.groups)

              ColumnLayout {
                id: iconGroup
                required property string modelData

                Layout.fillWidth: true
                spacing: 6

                Text {
                  text: iconGroup.modelData
                  color: root.theme.accentCyan
                  font { pixelSize: 11; bold: true; family: root.font }
                }

                Flow {
                  Layout.fillWidth: true
                  spacing: 6

                  Repeater {
                    model: Icons.groups[iconGroup.modelData]

                    Rectangle {
                      id: iconCell
                      required property string modelData

                      width: gcell.implicitWidth + 16
                      height: gcell.implicitHeight + 12
                      radius: 8
                      color: root.theme.bgSurface

                      ColumnLayout {
                        id: gcell
                        anchors.centerIn: parent
                        spacing: 3

                        RowLayout {
                          Layout.alignment: Qt.AlignHCenter
                          spacing: 8

                          Icon {
                            name: iconCell.modelData
                            color: root.theme.textPrimary
                            size: root.iconSize
                          }

                          Text {
                            visible: root.showGlyphs
                            text: root.glyphFor(iconCell.modelData) || "—"
                            color: root.theme.textMuted
                            font { pixelSize: root.iconSize; family: root.font }
                          }
                        }

                        Text {
                          Layout.alignment: Qt.AlignHCenter
                          text: iconCell.modelData
                          color: root.theme.textMuted
                          font { pixelSize: 8; family: root.font }
                        }
                      }
                    }
                  }
                }
              }
            }

            Text {
              Layout.fillWidth: true
              text: "Not covered: discord and telegram — MDI 7 dropped both brand "
                  + "icons, so both notification fallbacks lean on the freedesktop "
                  + "icon lookup already in front of them and fall back to bell. "
                  + "google-chrome and console show no font glyph beside them "
                  + "because the Nerd Font had none: NotificationPopup returned an "
                  + "empty string for chrome and the terminals, so those drew "
                  + "nothing at all. They have real icons now."
              color: root.theme.textMuted
              font { pixelSize: 9; family: root.font }
              wrapMode: Text.WordWrap
              bottomPadding: 8
            }
          }
        }
      }
    }
  }
}
