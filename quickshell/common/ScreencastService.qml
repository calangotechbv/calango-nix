pragma Singleton

import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import QtQuick

// Is anything sharing the screen right now?
//
// The obvious source is hyprland's `screencast` event, and it is the wrong
// one. That event tracks individual frame captures rather than sessions:
// measured across 115 seconds of a Chrome screen share, xdg-desktop-portal-
// hyprland tore the capture down and rebuilt it 82 times, leaving holes of a
// median 10ms and up to 690ms between captures that were themselves a median
// 0.53s long. A pill driven off it either flickers -- which is exactly what it
// did -- or needs two competing delays fighting each other to hide the churn.
//
// The portal's own PipeWire node is the session. Over the same 115 seconds it
// sat there untouched, and over a later three-minute share it never changed
// once. It is also what keeps screenshots out of the bar for nothing: grim
// drives wlr-screencopy directly and creates no node at all, where the raw
// event could only tell a screenshot from a share by how long it lasted.
//
// ponytail: portal sessions only. A recorder that drives wlr-screencopy itself
// instead of going through the portal -- wf-recorder, say -- shows nothing.
// Union the hyprland event back in if one ever gets installed, but note it
// cannot be told apart from a screenshot except by duration, which is the
// guesswork this rewrite removed.
Singleton {
  id: root

  // Declarative, and never read from imperative JS: Pipewire.nodes.values
  // hands back an empty list outside a binding. Same trap AudioService
  // documents, and it fails silently -- the filter below just matches nothing.
  readonly property var allNodes: Pipewire.nodes ? Pipewire.nodes.values : []

  // One node per portal screencast session. Matched on the node name rather
  // than the media class, because the webcam is a Video/Source too and the
  // portal is the only one of the two that means something is watching the
  // screen. Any backend qualifies, not just hyprland's.
  //
  // No PwObjectTracker: unlike volume, description and .audio, a node's name
  // is populated while untracked, so there is nothing to hold open here.
  readonly property var sessions: allNodes.filter(
    n => n && n.name && n.name.startsWith("xdg-desktop-portal"))

  // Bound rather than readonly so dev-screencast-check.qml can drive it
  // without a live share to point at.
  property int count: sessions.length

  // How long the pill outlives the last session. The node was steady for three
  // minutes straight when measured, but it did drop for about a second once
  // while a share was being reconnected, and a privacy indicator that blinks is
  // the bug this whole service was rewritten to stop.
  property int lingerMs: 1500

  // Appearing is immediate: a portal session *is* a share, and there is no
  // screenshot to mistake it for. Only leaving is delayed.
  property bool recording: false

  Timer {
    id: linger
    interval: root.lingerMs
    onTriggered: root.recording = root.count > 0
  }

  onCountChanged: {
    if (count > 0) {
      linger.stop();
      recording = true;
    } else {
      linger.restart();
    }
  }

  // The portal's node says a session exists but not what it is pointed at, so
  // the kind still comes from hyprland -- unreliable about *whether* a capture
  // is live, perfectly reliable about *what* it is.
  //
  // Latched rather than read live, because that same stream of start/stops
  // leaves the current value empty for milliseconds at a time, which would
  // blank the pill's text and reflow the row it sits in.
  property string lastKind: ""

  // Words, for the screen reader. The bar draws kindIcon instead -- an icon
  // cannot say "2 sources", and this is the one place the count still has to
  // be spoken.
  readonly property string label: {
    if (!recording) return "";
    if (count > 1) return count + " sources";
    // Anything that is not explicitly a window is a whole display, including
    // the case where no event has been seen yet.
    return lastKind === "window" ? "window" : "screen";
  }

  // The same three states as a glyph. Every one renders into the same 14px
  // box, so unlike the words they replaced the pill keeps one width whatever
  // is being shared -- which is the reason the rest of this bar is icons.
  readonly property string kindIcon: {
    if (count > 1) return "monitor-multiple";
    return lastKind === "window" ? "application-outline" : "monitor";
  }

  Connections {
    target: Hyprland

    function onRawEvent(event: HyprlandEvent): void {
      // v2 rather than the older `screencast`, which stops at the kind. Only
      // starts carry a kind worth keeping; a stop says nothing new.
      if (event.name !== "screencastv2") return;
      const parts = event.data.split(",");
      if (parts[0] === "1") root.lastKind = parts[1];
    }
  }
}
