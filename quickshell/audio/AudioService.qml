pragma Singleton

import Quickshell
import Quickshell.Services.Pipewire
import QtQuick

// Audio devices via Quickshell's built-in PipeWire binding -- no shelling out to
// pactl or wpctl. Selecting a device is a plain property assignment:
// Pipewire.preferredDefaultAudioSink/Source are writable and set the persistent
// PipeWire default, so this moves the default rather than routing one stream.
Singleton {
  id: root

  readonly property bool ready: Pipewire.ready

  // Same shape as NetworkService.devices: this has to stay a declarative binding.
  // Reading Pipewire.nodes.values from imperative JS gives an empty list.
  readonly property var allNodes: Pipewire.nodes ? Pipewire.nodes.values : []

  // Same rule as allNodes above, and for the same reason: links has to be
  // reached through a declarative binding, not read from imperative JS.
  readonly property var allLinks: Pipewire.links ? Pipewire.links.values : []

  // Devices, not per-application streams. Chrome appears in nodes twice (a
  // playback stream and a capture stream) and must not show up in a device
  // picker -- isStream is what separates them.
  readonly property var deviceNodes: allNodes.filter(n => n && !n.isStream)

  // description/nickname/audio are only populated while a PwObjectTracker holds
  // the node. Untracked, every row renders blank with no volume, which looks
  // like the module is broken rather than like a missing tracker. OSD.qml tracks
  // only the active sink, so tracking the full device list here is additive.
  PwObjectTracker { objects: root.deviceNodes }

  // .audio is null on video nodes (the webcam), and that is the reliable
  // discriminator: PwNodeType is a flags enum whose qmltypes ship no enumerator
  // names, so comparing against a constant would be guesswork.
  readonly property var sinks:   deviceNodes.filter(n => n.isSink  && n.audio)

  // The noise-canceling filter, found by the calango.role property that
  // pipewire/50-noise-canceling-source.conf declares on both of its nodes --
  // not by node.name, so that renaming a node cannot silently change what this
  // panel shows. home/audio.nix's guard asserts both declarations exist.
  function roleOf(node) {
    const p = (node && node.properties) ? node.properties : ({});
    return p["calango.role"] ? String(p["calango.role"]) : "";
  }

  // The filtered microphone. It is a real device and keeps its own volume, but
  // it is deliberately NOT offered in `sources` below.
  readonly property var noiseCancelSource:
    deviceNodes.find(n => n.audio && roleOf(n) === "noise-cancel-source") ?? null

  // The filter's capture side. This is plumbing, not an application: it holds
  // the microphone for as long as the filter runs, so left in `recordStreams`
  // it renders as a "Recording" row that never goes away.
  readonly property var noiseCancelCapture:
    streamNodes.find(n => roleOf(n) === "noise-cancel-capture") ?? null

  // Input devices, minus the filtered source.
  //
  // Excluded because the filter FOLLOWS the default input: making it the
  // default leaves WirePlumber deciding which microphone feeds it rather than
  // the person looking at this panel. Keeping it out of this list means the
  // list IS the choice of what gets noise-cancelled, and PipeWire persists that
  // choice by itself -- `default.configured.audio.source`, which survives a
  // reboot with a ranked fallback list. The filter appears in its own section
  // instead, where its input is shown rather than guessed at.
  readonly property var sources:
    deviceNodes.filter(n => !n.isSink && n.audio && roleOf(n) !== "noise-cancel-source")

  // The other half of the node list: one stream per application that currently
  // holds the audio device. These come and go as apps start and stop playing.
  readonly property var streamNodes: allNodes.filter(n => n && n.isStream)

  // Tracked for the same reason as the devices, and equally not optional: an
  // untracked stream has no properties map, so it renders as a nameless row.
  // Filtering on .audio to build this list would deadlock -- .audio is one of
  // the things tracking populates -- which is why the split below comes after.
  PwObjectTracker { objects: root.streamNodes }

  // isSink on a *stream* reads the other way round than it does on a device: it
  // is true when the stream feeds a sink, i.e. when the app is playing rather
  // than recording (verified: paplay -> isSink true, pw-record -> false). Video
  // streams -- a screen share carrying no audio -- have no .audio and fall out.
  readonly property var playbackStreams: streamNodes.filter(n => n.isSink  && n.audio)

  // Recording applications, minus the noise-canceling filter's own capture
  // side. Every other row in this section is an application that started
  // recording and will stop; the filter's capture stream is held for the whole
  // life of filter-chain.service, so it read as an app that never let go of the
  // microphone. It is plumbing and belongs in the filter's own section.
  readonly property var recordStreams:
    streamNodes.filter(n => !n.isSink && n.audio && roleOf(n) !== "noise-cancel-capture")

  // Which microphone is feeding the filter right now, read from the live graph
  // rather than assumed from the default input -- the two can differ, and when
  // they do this is the one that is true.
  //
  // Read-only by necessity, not by choice: Quickshell exposes PwLink.source and
  // .target as PwNode pointers but both are isReadonly and PwLink is
  // isCreatable: false, so the binding can see a link and cannot move one.
  // Changing it means writing a pw-metadata pin, which was measured NOT to
  // survive a filter-chain restart -- and X-Restart-Triggers restarts that unit
  // on every switch that touches the audio config. So this reports, and the
  // Input list above is what actually decides.
  readonly property var noiseCancelFrom: {
    const cap = noiseCancelCapture;
    if (!cap) return null;
    const link = allLinks.find(l => l && l.target && l.target.id === cap.id);
    return link ? link.source : null;
  }

  // The label for that microphone, or an honest statement of what is going on
  // when there is nothing to name. A filter with no input link is not an error
  // -- a suspended node has no links at all -- so this does not shout.
  readonly property string noiseCancelFromLabel:
    noiseCancelFrom ? shortLabel(noiseCancelFrom) : "not connected"

  // True when someone has made the filter the default input from outside this
  // panel -- pactl, or a leftover setting. The panel cannot offer that choice
  // any more, but it can still be IN that state, and then the Input list above
  // shows no active row at all, which reads as a bug rather than as a setting.
  readonly property bool noiseCancelIsDefault:
    !!(noiseCancelSource && defaultSource && noiseCancelSource.id === defaultSource.id)

  // A stream's identity lives in its properties map, not in the name/description
  // fields the devices use -- PipeWire leaves description and nickname empty on
  // every stream node.
  function streamProps(node) { return (node && node.properties) ? node.properties : ({}); }

  // application.name is what toolkits set and what pavucontrol shows; node.name
  // is PipeWire's own fallback, filled in from the client.
  function streamApp(node) {
    const p = streamProps(node);
    const name = p["application.name"] || p["node.nick"] || p["node.name"]
              || (node ? node.name : "");
    return name ? String(name) : "Unknown app";
  }

  // The track, tab or file being played. Dropped when it only repeats the app
  // name, which is where a client that sets no media.name of its own ends up.
  function streamTitle(node) {
    const title = streamProps(node)["media.name"];
    if (!title) return "";
    return String(title) === streamApp(node) ? "" : String(title);
  }

  // Apps that set application.icon-name (Firefox does) are exact. The rest go
  // through the same heuristic lookup the window switcher uses on window
  // classes, which resolves most of the remainder and returns "" otherwise --
  // the row falls back to an icon.
  function streamIcon(node) {
    const p = streamProps(node);
    if (p["application.icon-name"])
      return Quickshell.iconPath(String(p["application.icon-name"]), true);

    const app = String(p["application.name"] || p["application.process.binary"] || "");
    if (app === "") return "";
    try {
      const entry = DesktopEntries.heuristicLookup(app);
      if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true);
    } catch (e) {}
    return Quickshell.iconPath(app.toLowerCase(), true);
  }

  readonly property var defaultSink:   Pipewire.defaultAudioSink   ?? null
  readonly property var defaultSource: Pipewire.defaultAudioSource ?? null

  // Compare by id: the default properties hand back a node interface that is not
  // necessarily the same JS wrapper object as the one in the list.
  function isDefaultSink(node)   { return !!(node && defaultSink   && node.id === defaultSink.id); }
  function isDefaultSource(node) { return !!(node && defaultSource && node.id === defaultSource.id); }

  function selectSink(node)   { if (node) Pipewire.preferredDefaultAudioSink   = node; }
  function selectSource(node) { if (node) Pipewire.preferredDefaultAudioSource = node; }

  function label(node) {
    if (!node) return "";
    return node.description || node.nickname || node.name || "Unknown device";
  }

  // Strip the vendor noise PipeWire puts in descriptions so rows stay readable.
  function shortLabel(node) {
    return label(node)
      .replace(/ Analog Stereo$/, "")
      .replace(/ Digital Stereo \(HDMI\)$/, " (HDMI)")
      // Unanchored: the HDMI rule above leaves "(HDMI)" trailing, so an
      // end-anchored " Controller$" would stop matching precisely on the one
      // device whose name is long enough to need shortening.
      .replace(/ Controller\b/, "");
  }

  function volumeOf(node) { return (node && node.audio) ? node.audio.volume : 0; }
  function mutedOf(node)  { return !!(node && node.audio && node.audio.muted); }

  // PipeWire allows boosting past 1.0; the panel's slider is 0..1, so clamp here
  // rather than letting a stray drag set 300% output.
  function setVolume(node, v) {
    if (node && node.audio) node.audio.volume = Math.max(0, Math.min(1, v));
  }

  function toggleMute(node) {
    if (node && node.audio) node.audio.muted = !node.audio.muted;
  }

  // Summary of the active devices, for the bar or the OSD.
  readonly property real   volume: volumeOf(defaultSink)
  readonly property bool   muted:  mutedOf(defaultSink)
  readonly property string outputLabel: defaultSink   ? shortLabel(defaultSink)   : "No output"
  readonly property string inputLabel:  defaultSource ? shortLabel(defaultSource) : "No input"

  // Icon names for common/Icon.qml, not glyphs: the volume ramp is the most
  // frequently swapped icon in the bar, and glyph advance widths differ enough
  // between these four to shove every pill to their right.
  readonly property string outputIcon: {
    if (muted || volume <= 0) return "volume-off";
    if (volume < 0.33) return "volume-low";
    if (volume < 0.66) return "volume-medium";
    return "volume-high";
  }

  readonly property string inputIcon:
    mutedOf(defaultSource) ? "microphone-off" : "microphone"
}
