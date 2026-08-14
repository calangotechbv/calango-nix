pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

// Holds off the idle lock. hypridle is configured to lock at five minutes flat
// (hypr/hypridle.conf), which is right for walking away from the machine and
// wrong for a call or a film -- and until now the only way to stop it was to
// kill the daemon.
//
// The mechanism is the wayland idle-inhibit protocol, not anything aimed at
// hypridle: the compositor stops reporting idle while an inhibitor is held, so
// hypridle's timers never start counting. That matters for what happens when
// things go wrong. The inhibitor belongs to a shell surface, so it dies with
// the shell -- if quickshell crashes mid-call the machine goes back to locking
// on its own. A killed hypridle has no such floor; it simply stays dead.
//
// This singleton only holds the state. The IdleInhibitor itself lives in
// bar/Bar.qml, because the protocol inhibits per surface and the bar is the
// only one always on screen.
Singleton {
  id: root

  // An inhibit that never lapses is a lock screen you have quietly turned off,
  // which is exactly what hypridle.conf exists to prevent. Two hours covers a
  // film or a long meeting; past that the safer default is for the machine to
  // start locking again without being asked to.
  readonly property int limitMinutes: 120

  property bool inhibited: false

  // Epoch ms. Read through `now` below rather than compared against Date.now()
  // in a binding, which would never re-evaluate. Zero while inhibiting means
  // indefinite -- held until something releases it.
  property double expiresAt: 0
  property double now: 0

  readonly property bool indefinite: inhibited && expiresAt === 0

  // The duration originally asked for, in minutes (0 = indefinite, -1 = not
  // holding). Remaining time cannot be run backwards into it: an hour in,
  // "2h" and "4h" look alike. The picker needs it to mark what is held.
  property int requestedMinutes: -1

  readonly property int remainingSeconds:
    (inhibited && expiresAt > 0) ? Math.max(0, Math.round((expiresAt - now) / 1000)) : 0

  // Coarse on purpose: the pill is a reminder that something is held, not a
  // stopwatch, and a seconds counter in the bar is movement for its own sake.
  readonly property string remainingLabel: {
    if (!inhibited) return "";
    if (indefinite) return "\u221e";
    const mins = Math.ceil(remainingSeconds / 60);
    if (mins >= 60) return Math.floor(mins / 60) + "h" + String(mins % 60).padStart(2, "0");
    return mins + "m";
  }

  readonly property string icon: inhibited ? "coffee" : "coffee-off"

  readonly property string label:
    !inhibited ? "Idle lock active"
    : indefinite ? "Staying awake until stopped"
    : "Staying awake for " + remainingLabel

  // Whether the duration picker is on screen. Held here rather than in the
  // picker so the one IPC target covers the whole module.
  property bool pickerOpen: false

  function openPicker()   { root.pickerOpen = true; }
  function closePicker()  { root.pickerOpen = false; }
  function togglePicker() { root.pickerOpen = !root.pickerOpen; }

  // Runs only while something can expire. Five seconds is well inside the
  // one-minute resolution of the label and cheap enough not to matter.
  Timer {
    running: root.inhibited && root.expiresAt > 0
    interval: 5000
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.now = Date.now();
      if (root.now >= root.expiresAt) root.release();
    }
  }

  // Minutes of it. Anything <= 0 is indefinite, which the picker offers
  // deliberately: the two-hour default is a safe default, not a rule, and
  // someone watching a long film should not have to re-arm it halfway.
  function inhibit(minutes) {
    root.now = Date.now();
    root.expiresAt = minutes > 0 ? root.now + minutes * 60000 : 0;
    root.requestedMinutes = minutes > 0 ? minutes : 0;
    root.inhibited = true;
  }

  function release() {
    root.inhibited = false;
    root.expiresAt = 0;
    root.requestedMinutes = -1;
  }

  function toggle() { root.inhibited ? root.release() : root.inhibit(root.limitMinutes); }

  IpcHandler {
    target: "idle"

    // Straight to the default limit and back, for a bind or a script that
    // wants no picker in the way.
    function toggle(): void { root.toggle(); }
    function release(): void { root.release(); }

    // Minutes; zero or less holds it indefinitely.
    function inhibit(minutes: int): void { root.inhibit(minutes); }

    // The duration picker.
    function menu(): void  { root.togglePicker(); }
    function open(): void  { root.openPicker(); }
    function close(): void { root.closePicker(); }

    function status(): string {
      if (!root.inhibited) return "idle lock active";
      return root.indefinite ? "inhibited, indefinitely"
                             : "inhibited, " + root.remainingLabel + " left";
    }
  }
}
