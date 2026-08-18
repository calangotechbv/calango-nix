pragma ComponentBehavior: Bound
import Quickshell
import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Wayland
import "../network"
import "../bluetooth"
import "../idle"
import "../night-light"
import "../notifications"
import "../common"
import "../audio"
import "../brightness"
import "../calendar"

Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  // Which display carries the status pills and the system tray lives in
  // common/Screens.qml -- the notification popups pick the same one, and the
  // name is only worth writing once. Every other bar still gets its workspaces,
  // window title, clock and media controls; only the machine-wide readouts,
  // which say the same thing on every screen, are confined to one.

  // Raised when the network pill is clicked; shell.qml opens the panel.
  signal networkClicked()

  // Same, for the bluetooth pill.
  signal bluetoothClicked()

  // Same, for the volume pill. Mute moved to the middle button to make room,
  // so a stray click on the pill no longer silences the machine.
  signal audioClicked()

  // Raised when the bell pill is clicked; shell.qml opens the notification centre.
  signal notificationsClicked()

  // The cpu, memory and temperature pills all raise this: one panel carries the
  // detail for all three.
  signal systemClicked()

  // Which special workspace, if any, is on screen per monitor -- keyed by
  // monitor name, since SUPER+S slides the scratchpad over one display at a
  // time.
  //
  // It has to be tracked by hand because hyprland does not mark a special
  // workspace as active or focused while it is showing: probed with
  // special:magic on screen, quickshell reported active=false, focused=false
  // and the underlying numbered workspace still holding both. So the only
  // signal is the compositor's own activespecial event, which carries
  // "<workspace name>,<monitor name>" and an empty workspace name when the
  // scratchpad is dismissed.
  property var openSpecial: ({})

  Connections {
    target: Hyprland

    function onRawEvent(event: HyprlandEvent): void {
      if (event.name !== "activespecial") return;
      const parts = event.data.split(",");
      // Replaced rather than mutated: assigning into the existing object is not
      // a property write, so nothing bound to it would re-evaluate.
      const next = Object.assign({}, root.openSpecial);
      next[parts[1]] = parts[0];
      root.openSpecial = next;
    }
  }

  // activespecial only fires on a change, so a shell restarted while the
  // scratchpad is open would draw it shut until the next toggle -- and this
  // config restarts the shell for every change it makes. The monitor's own ipc
  // object carries the answer, but not yet at Component.onCompleted: measured,
  // Hyprland.monitors is empty there and holds both displays a second later.
  // Hence polling for the list rather than reading it once.
  Timer {
    id: seedSpecial
    running: true
    interval: 200
    repeat: true

    onTriggered: {
      // An event that already landed knows better than a snapshot.
      if (Object.keys(root.openSpecial).length > 0) { seedSpecial.running = false; return; }
      if (Hyprland.monitors.values.length === 0) return;

      const seed = {};
      for (const m of Hyprland.monitors.values) {
        const special = m.lastIpcObject ? m.lastIpcObject.specialWorkspace : null;
        if (special && special.name) seed[m.name] = special.name;
      }
      root.openSpecial = seed;
      seedSpecial.running = false;
    }
  }

  // MPRIS active player
  property var activePlayer: {
    const players = Mpris.players.values;
    if (!players || players.length === 0) return null;
    for (const p of players) {
      if (p.playbackState === MprisPlaybackState.Playing) return p;
    }
    return players[0];
  }

  // Every pill background goes through here, so one setting reaches all of
  // them at once -- including the fill-bar troughs, which would otherwise be
  // the only opaque thing left inside a translucent pill. Only backgrounds:
  // icons, text and the fills themselves stay at full strength, because the
  // point of a translucent pill is to see the wallpaper, not to lose the
  // readout. Accent-filled states -- the focused workspace, an urgent one, the
  // held idle inhibitor -- stay solid for the same reason: their text is drawn
  // in the background colour and is only legible against the fill.
  //
  // Reading BarSettings.pillOpacity inside the function is what registers the
  // binding dependency, so every caller re-evaluates when it changes.
  function tint(c) {
    return Qt.rgba(c.r, c.g, c.b, BarSettings.pillOpacity);
  }

  // Visibility and the strip's alpha live in BarSettings, so the settings
  // panel can drive them without a handle on this Scope.
  IpcHandler {
    target: "bar"
    function toggle(): void { BarSettings.barVisible = !BarSettings.barVisible; }
  }

  PwObjectTracker {
    objects: [Pipewire.defaultAudioSink]
  }

  // Brightness lives in BrightnessService, which the OSD reads too. It used to
  // be discovered and written here, in a copy of the same code the OSD carried
  // -- and both copies only knew about /sys/class/backlight, so on a desktop
  // with external monitors they found nothing and the pill hid itself.

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: barWindow
      required property var modelData
      screen: modelData
      visible: BarSettings.barVisible

      // Does this bar carry the machine-wide readouts?
      readonly property bool isPrimary: Screens.primary
                                        && modelData.name === Screens.primary.name

      // The wayland idle inhibitor, held while IdleService says to. It hangs
      // off this surface because the protocol inhibits per surface, and the bar
      // is the only one always on screen -- so hiding the bar
      // (`qs ipc call bar toggle`) drops the inhibit with it. One is enough, so
      // only the primary bar carries it.
      IdleInhibitor {
        window: barWindow
        enabled: barWindow.isPrimary && IdleService.inhibited
      }

      anchors {
        top: true
        left: true
        right: true
      }

      implicitHeight: 32

      // The strip behind the pills. At 0 there is no strip at all and the bar
      // is just its pills over the wallpaper. Blur is hyprland's
      // `blur-quickshell` layer rule; without it a low alpha is a clear window
      // onto whatever is behind the bar rather than a frosted one.
      color: Qt.rgba(root.theme.bgBase.r, root.theme.bgBase.g,
                     root.theme.bgBase.b, BarSettings.barOpacity)

      Item {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10

        // Left section: Time + Workspaces + Now Playing
        Row {
          id: leftSection
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8

          // Time. The pill is the calendar's anchor -- hence the id.
          Rectangle {
            id: timePill
            height: 24
            width: timeDate.width + 16
            radius: 12
            color: root.tint(root.theme.bgSurface)

            Row {
              id: timeDate
              anchors.centerIn: parent
              spacing: 8

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: root.theme.accentPrimary
                font.pixelSize: 14
                font.family: root.font
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Time.timeString
                color: root.theme.textPrimary
                font.pixelSize: 12
                font.family: root.font
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Time.dateString
                color: root.theme.textSecondary
                font.pixelSize: 12
                font.family: root.font
              }
            }

            // Declared after the Row, so it takes the whole pill: hit testing
            // walks siblings back to front, and nothing inside the Row wants a
            // click of its own.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: calendar.toggle()
            }
          }

          // Workspaces
          Row {
            spacing: 4

            Repeater {
              // Only this monitor's workspaces. barWindow.modelData is the
              // ShellScreen; inside the delegate below, modelData is a workspace,
              // hence the explicit id rather than relying on scope.
              //
              // Filtered on ws.monitor.name rather than Hyprland.monitorFor():
              // a method call registers no binding dependency, so the list would
              // not re-evaluate when a workspace moves between monitors.
              model: Hyprland.workspaces.values.filter(
                       ws => ws.monitor && ws.monitor.name === barWindow.modelData.name)

              Rectangle {
                id: wsPill
                required property var modelData
                property bool urgentBlink: false

                // `focused` is global -- exactly one workspace across all monitors
                // has input focus -- while `active` is per monitor. Styling only on
                // `focused` left the unfocused monitor's bar with nothing
                // highlighted at all, even though that monitor is sitting on a
                // workspace.
                readonly property bool isFocused: modelData.focused
                readonly property bool isActive: modelData.active

                // Special workspaces carry a name and an id that is an
                // implementation detail -- "special:magic" is workspace -98, and
                // that number is not even stable across a session, so a pill
                // reading "-98" is both meaningless and liable to change.
                readonly property bool isSpecial: modelData.name.startsWith("special:")
                readonly property string specialName: isSpecial ? modelData.name.slice(8) : ""

                // A wand, because the workspace is called magic and one icon
                // sits in the same round pill the numbers do, where the word had
                // to stretch it. Swap "auto-fix" for "creation" if you would
                // rather have sparkles. The name is not lost -- it is what
                // Accessible.name reads out, which is the only place it was ever
                // doing work.
                //
                // Only the special workspace is an icon; the rest are digits, so
                // the pill carries both and shows whichever applies.
                readonly property string label: isSpecial ? "" : modelData.id

                // Showing on this display right now. Never `focused` -- the
                // scratchpad slides over the workspace underneath and leaves
                // input focus where it was -- so without its own fill the pill
                // looks the same open as shut, which is the one thing you want
                // to know about a workspace you cannot see from the windows.
                readonly property bool isSpecialShown:
                  isSpecial && root.openSpecial[barWindow.modelData.name] === modelData.name

                Accessible.role: Accessible.Button
                Accessible.name: "Workspace " + (isSpecial ? specialName : modelData.id)
                                 + (isSpecialShown ? ", showing"
                                    : isFocused ? ", focused"
                                    : isActive ? ", active on this display" : "")
                                 + (modelData.urgent ? ", urgent" : "")

                width: (isFocused || isActive) ? 32 : 24
                height: 24
                radius: 12
                // Cyan rather than the focused pill's accentPrimary: both are on
                // screen at once whenever the scratchpad is open -- it does not
                // take focus from the workspace under it -- so they have to be
                // told apart at a glance rather than merely be bright.
                color: isSpecialShown ? root.theme.accentCyan :
                       isFocused ? root.theme.accentPrimary :
                       modelData.urgent && urgentBlink ? root.theme.accentRed :
                       isActive ? root.tint(root.theme.bgSelected)
                                : root.tint(root.theme.bgSurface)

                // Outline marks "current here, but this display does not have
                // input focus" without competing with the solid focused fill.
                border.width: (isActive && !isFocused) ? 1 : 0
                border.color: root.theme.accentPrimary

                Behavior on color {
                  ColorAnimation { duration: 150 }
                }

                SequentialAnimation {
                  loops: Animation.Infinite
                  running: wsPill.modelData.urgent && !wsPill.modelData.focused

                  PropertyAction { target: wsPill; property: "urgentBlink"; value: true }
                  PauseAnimation { duration: 500 }
                  PropertyAction { target: wsPill; property: "urgentBlink"; value: false }
                  PauseAnimation { duration: 500 }

                  onStopped: wsPill.urgentBlink = false
                }

                readonly property color labelColor:
                    (isSpecialShown || isFocused) ? root.theme.bgBase
                  : isActive                      ? root.theme.accentPrimary
                  : root.theme.textPrimary

                Icon {
                  visible: wsPill.isSpecial
                  anchors.centerIn: parent
                  name: "auto-fix"
                  color: wsPill.labelColor
                  size: 14
                }

                Text {
                  visible: !wsPill.isSpecial
                  anchors.centerIn: parent
                  text: wsPill.label
                  color: wsPill.labelColor
                  // A digit at 14 would tower over its neighbours.
                  font.pixelSize: 11
                  font.family: root.font
                  font.bold: wsPill.isSpecialShown || wsPill.isFocused || wsPill.isActive
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: wsPill.modelData.activate()
                }

                Behavior on width {
                  NumberAnimation { duration: 150 }
                }
              }
            }
          }

          // Now Playing
          Rectangle {
            height: 24
            width: nowPlayingContent.width + 16
            radius: 12
            color: mediaArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

            Behavior on color { ColorAnimation { duration: 120 } }
            visible: root.activePlayer !== null

            Accessible.role: Accessible.Button
            Accessible.name: {
              if (!root.activePlayer) return "No media";
              const artist = root.activePlayer.trackArtist || "";
              const title = root.activePlayer.trackTitle || "";
              return "Now playing: " + (artist ? artist + " - " : "") + title;
            }

            Row {
              id: nowPlayingContent
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: 8
              spacing: 6

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.activePlayer && root.activePlayer.isPlaying ? "play" : "pause"
                color: root.theme.accentPrimary
                size: 14
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                  if (!root.activePlayer) return "";
                  const artist = root.activePlayer.trackArtist || "";
                  const title = root.activePlayer.trackTitle || "";
                  return artist ? artist + " - " + title : title;
                }
                color: root.theme.textPrimary
                font.pixelSize: 11
                font.family: root.font
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 200)
              }
            }

            MouseArea {
              id: mediaArea
              hoverEnabled: true
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activePlayer.togglePlaying()
            }
          }
        }

        // Center section: Window Title. Centred on the bar while it fits
        // there, and centred in the real gap between the two sections once it
        // does not -- see TitleSlot.qml, which owns that arithmetic and is
        // tested on it. The two section widths go in as numbers so the
        // component knows nothing about this file.
        TitleSlot {
          anchors.fill: parent
          leftWidth: leftSection.width
          rightWidth: rightSection.visible ? rightSection.width : 0
          title: Hyprland.activeToplevel ? Hyprland.activeToplevel.title : ""
          pillColor: root.tint(root.theme.bgSurface)
          textColor: root.theme.textPrimary
          fontFamily: root.font
        }

        // Right section: System Info + System Tray
        Row {
          id: rightSection
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: barWindow.isPrimary
          // 16 between groups against 6 inside one: the grouping is carried
          // by the gap alone, no dividers, in a bar that is otherwise all
          // rounded pills.
          spacing: 16

          // Screen capture, and it leads the section for a layout reason
          // rather than an editorial one: this row is anchored to the right,
          // so it grows and shrinks at its left edge. A pill that comes and
          // goes anywhere else shoves everything to its left along with it,
          // which is what it did from the head of the alerts group -- the
          // whole run of controls and readouts slid sideways whenever a share
          // started. Here there is nothing to its left to move.
          //
          // Its own group rather than the head of the controls: it is not
          // something you act on, and the 16px gap says so.
          //
          // Red icon on the ordinary pill, the same way the microphone goes
          // red while something is listening -- the two answer the same
          // question and should look like a pair. Nothing to click: hyprland
          // has no command to revoke a capture, and a button that only looks
          // like one is worse than none.
          Rectangle {
            visible: ScreencastService.recording
            anchors.verticalCenter: parent.verticalCenter
            height: 24
            width: castContent.width + 12
            radius: 12
            color: root.tint(root.theme.bgSurface)

            Accessible.role: Accessible.StaticText
            Accessible.name: "Screen capture in progress: " + ScreencastService.label

            Row {
              id: castContent
              anchors.centerIn: parent
              spacing: 6

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "record"
                color: root.theme.accentRed
                size: 14
              }

              // Whether it is a whole display or one window is the thing
              // people get wrong on a call, and it is the one state the red
              // dot cannot carry on its own. Muted rather than red: the dot
              // is the alarm, this only says what it is pointed at.
              //
              // The words it replaced made the pill three different widths.
              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: ScreencastService.kindIcon
                color: root.theme.textSecondary
                size: 14
              }
            }
          }

          // Everything you act on, in one run: sound, screen, the two
          // radios, the idle hold, and the power profile -- which sits last
          // because it borders the battery and temperature readings it
          // affects.
          Row {
            id: controls
            spacing: 6

            // Volume
            Rectangle {
              height: 24
              width: volContent.width + 12
              radius: 12
              color: volArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }

              Accessible.role: Accessible.StaticText
              Accessible.name: {
                const sink = Pipewire.defaultAudioSink;
                const hint = ", click for the audio panel, middle-click to mute";
                if (!sink || !sink.audio) return "Volume" + hint;
                if (sink.audio.muted) return "Volume: muted" + hint;
                return "Volume: " + Math.round(sink.audio.volume * 100) + "%" + hint;
              }

              Row {
                id: volContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: {
                    const sink = Pipewire.defaultAudioSink;
                    if (!sink || !sink.audio || sink.audio.muted || sink.audio.volume <= 0) return "volume-off";
                    if (sink.audio.volume < 0.33) return "volume-low";
                    if (sink.audio.volume < 0.66) return "volume-medium";
                    return "volume-high";
                  }
                  color: {
                    const sink = Pipewire.defaultAudioSink;
                    if (!sink || !sink.audio || sink.audio.muted) return root.theme.textMuted;
                    return root.theme.accentPrimary;
                  }
                  size: 14
                }

                FillBar {
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.tint(root.theme.bgBase)
                  // Muted reads as empty, matching the OSD meter. The icon
                  // beside it is the struck-through one, so the state is not
                  // carried by the bar alone.
                  value: {
                    const sink = Pipewire.defaultAudioSink;
                    if (!sink || !sink.audio || sink.audio.muted) return 0;
                    return sink.audio.volume;
                  }
                  fillColor: {
                    const sink = Pipewire.defaultAudioSink;
                    if (!sink || !sink.audio || sink.audio.muted) return root.theme.textMuted;
                    return root.theme.accentPrimary;
                  }
                }
              }

              MouseArea {
                id: volArea
                hoverEnabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                // Right button is deliberately not accepted: it falls through
                // rather than doing something surprising next to the pills that
                // do use it.
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onClicked: mouse => {
                  if (mouse.button === Qt.MiddleButton) {
                    const sink = Pipewire.defaultAudioSink;
                    if (sink && sink.audio) sink.audio.muted = !sink.audio.muted;
                    return;
                  }
                  root.audioClicked();
                }
                onWheel: (wheel) => {
                  const sink = Pipewire.defaultAudioSink;
                  if (!sink || !sink.audio) return;
                  const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                  sink.audio.volume = Math.max(0, Math.min(1.5, sink.audio.volume + delta));
                }
              }
            }

            // Microphone. Its own pill rather than a second half of the volume
            // one: that pill's MouseArea fills it and is declared after its
            // content, so anything nested inside would sit *under* it and never
            // see a click -- the same back-to-front hit test that swallowed the
            // network panel's forget button.
            Rectangle {
              id: micPill
              // Hidden outright on a machine with no capture device, rather than
              // drawn showing a dash. Nothing here can create one.
              visible: AudioService.defaultSource !== null
              height: 24
              width: micContent.width + 12
              radius: 12
              color: micArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }

              // Only true when an application is actually holding the mic open.
              // AudioService already separates capture streams from playback ones,
              // and from video streams that carry no audio at all.
              readonly property bool capturing: AudioService.recordStreams.length > 0
              readonly property bool micMuted: {
                const src = AudioService.defaultSource;
                return !src || !src.audio || src.audio.muted;
              }

              Accessible.role: Accessible.StaticText
              Accessible.name: {
                const src = AudioService.defaultSource;
                const hint = ", click for the audio panel, middle-click to mute";
                const busy = capturing ? ", in use" : "";
                if (!src || !src.audio) return "Microphone" + busy + hint;
                if (src.audio.muted) return "Microphone: muted" + busy + hint;
                return "Microphone: " + Math.round(src.audio.volume * 100) + "%" + busy + hint;
              }

              Row {
                id: micContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  // microphone / microphone-off -- AudioService picks the struck-through one when
                  // muted, which is the same pair the audio panel uses.
                  name: AudioService.inputIcon
                  // Red only while something is recording, and only when the mic
                  // can actually hear it: a muted mic is not a privacy question,
                  // so it stays grey however many apps have it open.
                  color: micPill.micMuted ? root.theme.textMuted
                       : micPill.capturing ? root.theme.accentRed
                       : root.theme.accentPrimary
                  size: 14
                }

                FillBar {
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.tint(root.theme.bgBase)
                  value: {
                    const src = AudioService.defaultSource;
                    if (!src || !src.audio || src.audio.muted) return 0;
                    return src.audio.volume;
                  }
                  fillColor: micPill.micMuted ? root.theme.textMuted
                           : micPill.capturing ? root.theme.accentRed
                           : root.theme.accentPrimary
                }
              }

              MouseArea {
                id: micArea
                hoverEnabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                // Same three-button contract as the volume pill, so the two read
                // as a pair: click opens the panel, middle mutes, right falls
                // through.
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onClicked: mouse => {
                  if (mouse.button === Qt.MiddleButton) {
                    const src = AudioService.defaultSource;
                    if (src && src.audio) src.audio.muted = !src.audio.muted;
                    return;
                  }
                  root.audioClicked();
                }
                onWheel: wheel => {
                  const src = AudioService.defaultSource;
                  if (!src || !src.audio) return;
                  const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                  // Capped at 1.0, unlike the output pill's 1.5. Amplifying a
                  // microphone past unity in PipeWire raises the noise floor with
                  // the signal; the gain worth having is on the device, not here.
                  src.audio.volume = Math.max(0, Math.min(1, src.audio.volume + delta));
                }
              }
            }

            // Brightness
            Rectangle {
              height: 24
              width: brightContent.width + 12
              radius: 12
              color: brightArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }
              visible: BrightnessService.available

              Accessible.role: Accessible.StaticText
              Accessible.name: "Brightness: " + BrightnessService.percent
                               + "%, scroll to change"

              Row {
                id: brightContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: "brightness-7"
                  color: root.theme.accentOrange
                  size: 14
                }

                FillBar {
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.tint(root.theme.bgBase)
                  value: BrightnessService.percent / 100
                  fillColor: root.theme.accentOrange
                }
              }

              MouseArea {
                id: brightArea
                hoverEnabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                // Every display moves together, so the pill reads the same on
                // both bars and there is nothing to disambiguate.
                onWheel: wheel => BrightnessService.step(wheel.angleDelta.y > 0 ? 5 : -5)
              }
            }

            // Network
            Rectangle {
              height: 24
              width: netContent.width + 12
              radius: 12
              color: netArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }
              Accessible.role: Accessible.Button
              Accessible.name: "Network: " + NetworkService.label
                               + (NetworkService.limited ? ", no internet" : "")

              Row {
                id: netContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: NetworkService.icon
                  color: NetworkService.kind === "disconnected" ? root.theme.textMuted
                       : NetworkService.limited                 ? root.theme.accentOrange
                       : root.theme.accentGreen
                  size: 14
                }
                // No SSID beside the icon. The icon already carries every
                // state worth acting on -- wired, wifi off, and four signal
                // steps -- and colour carries the rest: grey disconnected,
                // orange for a link with no route. The name is one click away
                // in the panel, and at up to 140px it was the widest thing in
                // the bar.
              }

              MouseArea {
                id: netArea
                hoverEnabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.networkClicked()
              }
            }

            // Bluetooth. Hidden on machines with no adapter, the same way the
            // battery pill is.
            Rectangle {
              visible: BluetoothService.available
              height: 24
              width: btContent.width + 12
              radius: 12
              color: btArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }
              Accessible.role: Accessible.Button
              Accessible.name: "Bluetooth: " + BluetoothService.spokenLabel
                             + ", click for the bluetooth panel"
                             + (BluetoothService.blocked ? "" : ", middle-click to turn it "
                                                               + (BluetoothService.enabled ? "off" : "on"))

              Row {
                id: btContent
                anchors.centerIn: parent
                spacing: 6

                // Idle, off or blocked: the adapter icon alone. "Not
                // connected" spelled out would be a permanent fixture in the
                // bar saying nothing.
                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: BluetoothService.pillDevices.length === 0
                  name: BluetoothService.icon
                  color: BluetoothService.enabled ? root.theme.accentPrimary
                                                  : root.theme.textMuted
                  size: 14
                }

                // Connected: the devices themselves, each with its battery
                // where it reports one. Capped at BluetoothService.pillLimit
                // so a busy adapter cannot push the tray off the bar -- the
                // panel carries the full list.
                Repeater {
                  model: BluetoothService.pillDevices

                  Row {
                    required property var modelData
                    spacing: 4

                    Icon {
                      anchors.verticalCenter: parent.verticalCenter
                      name: BluetoothService.deviceIcon(parent.modelData)
                      color: root.theme.accentGreen
                      size: 14
                    }

                    // Named only while it is the one connection. Past that the
                    // icons have to carry it: three names would cost more bar
                    // than the tray has left.
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: BluetoothService.pillDevices.length === 1
                      text: BluetoothService.name(parent.modelData)
                      color: root.theme.textPrimary
                      font.pixelSize: 11
                      font.family: root.font
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, 140)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: text !== ""
                      text: BluetoothService.batteryLabel(parent.modelData)
                      color: root.theme.textMuted
                      font.pixelSize: 11
                      font.family: root.font
                    }
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: BluetoothService.pillOverflow > 0
                  text: "+" + BluetoothService.pillOverflow
                  color: root.theme.textMuted
                  font.pixelSize: 11
                  font.family: root.font
                }
              }

              MouseArea {
                id: btArea
                hoverEnabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                // As on the volume pill: click opens the panel, the middle
                // button carries the on/off, and the right button is not
                // accepted at all so it falls through.
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onClicked: mouse => {
                  if (mouse.button !== Qt.MiddleButton) {
                    root.bluetoothClicked();
                    return;
                  }
                  // rfkill can only be cleared outside the shell, so a middle
                  // click on a blocked adapter would look like a dead button.
                  // Send those to the panel, which says so in words.
                  if (BluetoothService.blocked) root.bluetoothClicked();
                  else BluetoothService.setEnabled(!BluetoothService.enabled);
                }
              }
            }

            // Idle inhibitor. Always present rather than only while held: a
            // control you cannot find is one you do not use, and the whole
            // point is reaching it before the call starts. Left click picks a
            // duration; right click is the default straight away, for when the
            // call is already ringing.
            Rectangle {
              height: 24
              width: idleContent.width + 12
              radius: 12
              // Inhibited already sits on bgSelected, so its hover has to go a
              // step past that rather than land on the resting colour of the
              // state next to it.
              color: IdleService.inhibited
                     ? (idleArea.containsMouse ? root.tint(Qt.lighter(root.theme.bgSelected, 1.25))
                                               : root.tint(root.theme.bgSelected))
                     : (idleArea.containsMouse ? root.tint(root.theme.bgSelected)
                                               : root.tint(root.theme.bgSurface))

              Accessible.role: Accessible.Button
              Accessible.name: IdleService.label + ", click to choose how long"

              Behavior on color { ColorAnimation { duration: 120 } }

              Row {
                id: idleContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: IdleService.icon
                  color: IdleService.inhibited ? root.theme.accentOrange : root.theme.textMuted
                  size: 14
                }

                // The countdown is the only thing that says this lapses on its
                // own, so it is worth the width while it is held.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: IdleService.inhibited
                  text: IdleService.remainingLabel
                  color: root.theme.textPrimary
                  font.pixelSize: 11
                  font.family: root.font
                }
              }

              MouseArea {
                id: idleArea
                hoverEnabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: event => {
                  if (event.button === Qt.RightButton) IdleService.toggle();
                  else IdleService.togglePicker();
                }
              }
            }

            // Power profile. Click cycles forward, scroll steps either way.
            Rectangle {
              height: 24
              width: powerContent.width + 12
              radius: 12
              color: powerArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)
              Accessible.role: Accessible.Button
              Accessible.name: "Power profile: " + PowerProfileService.label
                               + (PowerProfileService.degraded
                                  ? ", degraded: " + PowerProfileService.degradationText
                                  : "")

              Behavior on color { ColorAnimation { duration: 120 } }

              Row {
                id: powerContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: PowerProfileService.icon
                  color: PowerProfileService.degraded ? root.theme.accentRed
                       : PowerProfileService.profile === PowerProfile.PowerSaver  ? root.theme.accentGreen
                       : PowerProfileService.profile === PowerProfile.Performance ? root.theme.accentOrange
                       : root.theme.accentPrimary
                  size: 14
                }
                // Leaf, gauge or speedometer says which profile without the
                // word, and red says the firmware is throttling regardless.
              }

              MouseArea {
                id: powerArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: PowerProfileService.cycle(1)
                onWheel: wheel => PowerProfileService.cycle(wheel.angleDelta.y > 0 ? 1 : -1)
              }
            }

            // Night light. Click cycles on -> auto -> off, scroll steps either
            // way -- the same interaction as the power profile beside it,
            // because it is the same kind of control: a small set of states
            // where the glyph and its colour carry all of it.
            Rectangle {
              height: 24
              width: nightContent.width + 12
              radius: 12
              color: nightArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Accessible.role: Accessible.Button
              Accessible.name: NightLightService.label

              Behavior on color { ColorAnimation { duration: 120 } }

              Row {
                id: nightContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: NightLightService.icon
                  // Intensity carries the state: warm for on, normal text for
                  // auto with a fix, and muted for off and for the one state
                  // that can be chosen and still do nothing -- auto before the
                  // first fix. Those two look alike because they are alike:
                  // nothing is running.
                  color: NightLightService.idle            ? root.theme.textMuted
                       : NightLightService.mode === "on"   ? root.theme.accentOrange
                       : NightLightService.mode === "auto" ? root.theme.textPrimary
                                                           : root.theme.textMuted
                  size: 14
                }
              }

              MouseArea {
                id: nightArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: NightLightService.cycle(1)
                onWheel: wheel => NightLightService.cycle(wheel.angleDelta.y > 0 ? 1 : -1)
              }
            }
          }

          // Everything you only read. These used to be split either side of
          // the controls, two pills here and two there, which is what made
          // the row look shuffled.
          Row {
            id: monitors
            spacing: 6

            readonly property color batteryColor: {
              if (SystemInfo.batteryCharging) return root.theme.accentGreen;
              if (SystemInfo.batteryLevelRaw > 20) return root.theme.batteryGood;
              if (SystemInfo.batteryLevelRaw > 10) return root.theme.batteryWarning;
              return root.theme.batteryCritical;
            }

            // Nothing in this group is a figure any more, so nothing in it can
            // reflow: cpu and memory are fills, temperature is a coloured icon.
            // The first three are readouts in the bar but not dead: each opens
            // the system panel, which is where the numbers behind them live.
            // CPU
            Rectangle {
              height: 24
              width: cpuContent.width + 12
              radius: 12
              color: cpuArea.containsMouse ? root.tint(root.theme.bgSelected)
                                           : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }
              Accessible.role: Accessible.Button
              Accessible.name: "CPU: " + SystemInfo.cpuUsage
                               + ", click for the system panel"

              Row {
                id: cpuContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: "cpu-64-bit"
                  color: root.theme.accentOrange
                  size: 14
                }
                FillBar {
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.tint(root.theme.bgBase)
                  value: SystemInfo.cpuUsageRaw / 100
                  fillColor: root.theme.accentOrange
                }
              }

              MouseArea {
                id: cpuArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.systemClicked()
              }
            }

            // Memory
            Rectangle {
              height: 24
              width: memContent.width + 12
              radius: 12
              color: memArea.containsMouse ? root.tint(root.theme.bgSelected)
                                           : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }
              Accessible.role: Accessible.Button
              Accessible.name: "Memory: " + SystemInfo.memoryUsage + ", "
                               + SystemInfo.memoryUsedGb + " of "
                               + SystemInfo.memoryTotalGb + " used"
                               + ", click for the system panel"

              Row {
                id: memContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: "memory"
                  color: root.theme.accentCyan
                  size: 14
                }
                FillBar {
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.tint(root.theme.bgBase)
                  value: SystemInfo.memoryUsageRaw / 100
                  fillColor: root.theme.accentCyan
                }
              }

              MouseArea {
                id: memArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.systemClicked()
              }
            }

            // Temperature
            Rectangle {
              height: 24
              width: tempContent.width + 12
              radius: 12
              color: tempArea.containsMouse ? root.tint(root.theme.bgSelected)
                                            : root.tint(root.theme.bgSurface)

              Behavior on color { ColorAnimation { duration: 120 } }
              Accessible.role: Accessible.Button
              Accessible.name: "Temperature: " + SystemInfo.temperature
                               + ", click for every sensor"

              Row {
                id: tempContent
                anchors.centerIn: parent
                spacing: 6

                // No figure, and no fill bar either: a bar needs a ceiling and
                // this machine does not supply one. k10temp exposes only
                // temp1_input and temp1_label -- no _max, no _crit -- and the
                // one trip point on the box belongs to acpitz, a zone that
                // reads 20°C. Anything to fill against would have been a
                // constant invented here and wrong on the next machine.
                //
                // Bands are thresholds rather than a scale, so they need no such
                // number. Muted is "normal, ignore me"; the other two are the
                // only states worth interrupting for. The reading itself stays
                // in Accessible.name.
                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: "thermometer"
                  color: SystemInfo.temperatureRaw >= 80 ? root.theme.accentRed
                       : SystemInfo.temperatureRaw >= 65 ? root.theme.accentOrange
                       : root.theme.textMuted
                  size: 14

                  Behavior on color { ColorAnimation { duration: 250 } }
                }
              }

              MouseArea {
                id: tempArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.systemClicked()
              }
            }

            // Battery. Hidden outright on machines with no battery -- a Row
            // skips invisible children, so this leaves no gap.
            Rectangle {
              visible: SystemInfo.hasBattery
              height: 24
              width: battContent.width + 12
              radius: 12
              color: root.tint(root.theme.bgSurface)
              Accessible.role: Accessible.StaticText
              Accessible.name: "Battery: " + SystemInfo.batteryLevel

              Row {
                id: battContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: SystemInfo.batteryIcon
                  color: monitors.batteryColor
                  size: 14
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: SystemInfo.batteryLevel
                  color: root.theme.textPrimary
                  font.pixelSize: 11
                  font.family: root.font
                }
              }
            }
          }

          // Things that appear rather than things that are always there.
          Row {
            id: alerts
            spacing: 6

            // Notifications. Left click opens the centre, right click toggles
            // DND -- the state of which has to be visible somewhere, or you can
            // silence yourself in the morning and not find out until lunch.
            Rectangle {
              height: 24
              width: notifContent.width + 12
              radius: 12
              color: notifArea.containsMouse ? root.tint(root.theme.bgSelected) : root.tint(root.theme.bgSurface)

              Accessible.role: Accessible.Button
              Accessible.name: NotificationService.doNotDisturb
                               ? "Notifications, do not disturb on, "
                                 + NotificationService.unreadCount + " unread"
                               : "Notifications, " + NotificationService.unreadCount + " unread"

              Behavior on color { ColorAnimation { duration: 120 } }

              Row {
                id: notifContent
                anchors.centerIn: parent
                spacing: 6

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: NotificationService.doNotDisturb   ? "bell-off"
                      : NotificationService.unreadCount > 0 ? "bell"
                      : "bell-outline"
                  color: NotificationService.doNotDisturb   ? root.theme.accentOrange
                       : NotificationService.unreadCount > 0 ? root.theme.accentPrimary
                       : root.theme.textMuted
                  size: 14
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: NotificationService.unreadCount > 0
                  text: NotificationService.unreadCount > 99
                        ? "99+" : NotificationService.unreadCount
                  color: root.theme.textPrimary
                  font.pixelSize: 11
                  font.family: root.font
                }
              }

              MouseArea {
                id: notifArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                  if (mouse.button === Qt.RightButton)
                    NotificationService.doNotDisturb = !NotificationService.doNotDisturb;
                  else
                    root.notificationsClicked();
                }
              }
            }

            // System Tray
            // There's an issue that some tray not display correctly.
            // https://github.com/quickshell-mirror/quickshell/issues/26
            // https://github.com/quickshell-mirror/quickshell/pull/777
            Rectangle {
              implicitHeight: 24
              implicitWidth: trayIcons.implicitWidth + 4
              radius: 12
              color: root.tint(root.theme.bgSurface)

              RowLayout {
                id: trayIcons
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                  model: SystemTray.items

                  MouseArea {
                    id: trayDelegate
                    required property SystemTrayItem modelData

                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.tooltipTitle || modelData.title || "System tray item"

                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24

                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

                    onClicked: (mouse) => {
                      if (mouse.button === Qt.LeftButton) {
                        modelData.activate()
                      } else if (mouse.button === Qt.RightButton) {
                        if (modelData.hasMenu) {
                          menuAnchor.open()
                        }
                      } else if (mouse.button === Qt.MiddleButton) {
                        modelData.secondaryActivate()
                      }
                    }

                    IconImage {
                      anchors.centerIn: parent
                      source: trayDelegate.modelData.icon
                      implicitSize: 16
                    }

                    QsMenuAnchor {
                      id: menuAnchor
                      menu: trayDelegate.modelData.menu

                      anchor.window: trayDelegate.QsWindow.window
                      anchor.adjustment: PopupAdjustment.Flip
                      anchor.onAnchoring: {
                        const window = trayDelegate.QsWindow.window;
                        const widgetRect = window.contentItem.mapFromItem(
                          trayDelegate, 0, trayDelegate.height,
                          trayDelegate.width, trayDelegate.height);
                        menuAnchor.anchor.rect = widgetRect;
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      // One per bar, anchored to this screen's own clock pill, so the dropdown
      // lands under the pill actually clicked and no monitor coordinates are
      // ever computed. SlideX keeps it on screen when the bar is the rightmost
      // display's.
      CalendarPopup {
        id: calendar
        theme: root.theme
        font: root.font
        barVisible: barWindow.visible
        todayStamp: Time.dayStamp
        anchor.item: timePill
        anchor.edges: Edges.Bottom
        anchor.gravity: Edges.Bottom
        anchor.adjustment: PopupAdjustment.SlideX
      }
    }
  }
}
