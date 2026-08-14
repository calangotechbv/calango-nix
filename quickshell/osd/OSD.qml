pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import QtQuick
import "../audio"
import "../brightness"

Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property bool showVolume: false
  property bool showMic: false
  property bool showBrightness: false
  property real volumeValue: 0
  property bool volumeMuted: false
  property real micValue: 0
  property bool micMuted: false
  property real brightnessValue: 0

  // PipeWire tracking
  PwObjectTracker {
    objects: [Pipewire.defaultAudioSink]
  }

  Connections {
    target: Pipewire.defaultAudioSink?.audio ?? null

    function onVolumeChanged() {
      root.volumeValue = Pipewire.defaultAudioSink.audio.volume;
      root.showVolume = true;
      volumeHideTimer.restart();
    }

    function onMutedChanged() {
      root.volumeMuted = Pipewire.defaultAudioSink.audio.muted;
      root.showVolume = true;
      volumeHideTimer.restart();
    }
  }

  Timer {
    id: volumeHideTimer
    interval: 1500
    onTriggered: root.showVolume = false
  }

  // The microphone, on the same footing as the sink. Its bar pill shows a fill
  // rather than a figure, and nothing else reports the input level, so without
  // this there is no number anywhere when you change it.
  Connections {
    target: AudioService.defaultSource?.audio ?? null

    function onVolumeChanged() {
      root.micValue = AudioService.defaultSource.audio.volume;
      root.showMic = true;
      micHideTimer.restart();
    }

    function onMutedChanged() {
      root.micMuted = AudioService.defaultSource.audio.muted;
      root.showMic = true;
      micHideTimer.restart();
    }
  }

  Timer {
    id: micHideTimer
    interval: 1500
    onTriggered: root.showMic = false
  }

  // Brightness. The discovery and the read used to live here as well as in
  // bar/Bar.qml, two copies of the same sysfs-only code; both now read
  // BrightnessService, which also knows about DDC/CI monitors.
  Connections {
    target: BrightnessService

    // userChanged rather than percentChanged: the latter also fires for the
    // reading taken at startup, which would pop the OSD up on login.
    function onUserChanged() {
      root.brightnessValue = BrightnessService.percent / 100;
      root.showBrightness = true;
      brightnessHideTimer.restart();
    }
  }

  Timer {
    id: brightnessHideTimer
    interval: 1500
    onTriggered: root.showBrightness = false
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData

      visible: root.showVolume || root.showMic || root.showBrightness
      focusable: false
      color: "transparent"

      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "quickshell-osd"

      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      anchors {
        right: true
        top: true
        bottom: true
      }

      implicitWidth: 70

      Column {
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 12

        OsdMeter {
          theme: root.theme
          font: root.font
          shown: root.showVolume
          value: root.volumeMuted ? 0 : root.volumeValue
          caption: root.volumeMuted ? "Mute" : Math.round(root.volumeValue * 100) + "%"
          accent: root.volumeMuted ? root.theme.textMuted : root.theme.accentPrimary
          accessibleName: root.volumeMuted
                          ? "Volume: muted"
                          : "Volume: " + Math.round(root.volumeValue * 100) + "%"
          icon: {
            if (root.volumeMuted || root.volumeValue <= 0) return "volume-off";
            if (root.volumeValue < 0.33) return "volume-low";
            if (root.volumeValue < 0.66) return "volume-medium";
            return "volume-high";
          }
        }

        OsdMeter {
          theme: root.theme
          font: root.font
          shown: root.showMic
          value: root.micMuted ? 0 : root.micValue
          caption: root.micMuted ? "Mute" : Math.round(root.micValue * 100) + "%"
          accent: root.micMuted ? root.theme.textMuted : root.theme.accentPrimary
          accessibleName: root.micMuted
                          ? "Microphone: muted"
                          : "Microphone: " + Math.round(root.micValue * 100) + "%"
          // microphone / microphone-off, the same pair the bar pill and the audio panel use.
          icon: AudioService.inputIcon
        }

        OsdMeter {
          theme: root.theme
          font: root.font
          shown: root.showBrightness
          value: root.brightnessValue
          caption: Math.round(root.brightnessValue * 100) + "%"
          accent: root.theme.accentOrange
          accessibleName: "Brightness: " + Math.round(root.brightnessValue * 100) + "%"
          icon: "brightness-7"
        }
      }
    }
  }
}
