pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick
import "../common"

// The night light's mode, and nothing else. gammastep itself is held by
// hypr/systemd/night-light.service; this writes the conf that unit reads and
// restarts it. See docs/superpowers/specs/2026-08-13-night-light-design.md.
//
// Deliberately not a Process here. The shell is restarted often enough --
// newly installed fonts alone require it -- that shell-owned gamma would flash
// the screen cold and back every time.
Singleton {
  id: root

  // Cycle order, and the order the glyph steps through.
  readonly property var modes: ["on", "auto", "off"]

  property string mode: "auto"
  property int temp: 3000

  // Empty until locate.sh has succeeded once. Strings rather than reals: they
  // are handed straight back to gammastep as `-l lat:lon`, and round-tripping
  // them through a double only invents digits.
  property string lat: ""
  property string lon: ""

  readonly property bool located: root.lat !== "" && root.lon !== ""

  // The one state that can be selected and still do nothing. The glyph draws
  // it muted and says why.
  readonly property bool idle: root.mode === "auto" && !root.located

  readonly property string icon:
      root.mode === "on"   ? "weather-night"
    : root.mode === "auto" ? "theme-light-dark"
                           : "white-balance-sunny"

  readonly property string label:
      root.mode === "on"  ? "Night light on, " + root.temp + "K"
    : root.mode === "off" ? "Night light off"
    : root.located        ? "Night light follows the sun, " + root.temp + "K at night"
                          : "Night light on a schedule, but there is no location yet"

  readonly property string home: Quickshell.env("HOME")
  readonly property string confPath: Paths.stateDir + "/night-light.conf"

  function setMode(m) {
    if (root.modes.indexOf(m) < 0) return;
    // FileView.setText() no-ops when the text is unchanged, so save() would
    // write nothing and onSaved -- which is what triggers apply() -- would
    // never fire. Re-selecting the current mode is exactly how someone
    // recovers a unit that was stopped or killed underneath the shell, so it
    // has to still restart something.
    if (m === root.mode) { root.apply(); return; }
    root.mode = m;
    root.save();
  }

  // step of +1/-1; wraps in both directions, like PowerProfileService.cycle.
  function cycle(step) {
    const n = root.modes.length;
    let i = root.modes.indexOf(root.mode);
    if (i < 0) i = 0;
    root.setMode(root.modes[((i + step) % n + n) % n]);
  }

  // mode= and temp=, one per line -- the exact shape run.sh's conf_get()
  // parses. The restart itself does not happen here: it hangs off conf's
  // onSaved below, so it fires only once the write has actually landed,
  // rather than racing beside it.
  function save() {
    // Remember the exact bytes, so the reload the watcher fires for this write
    // can be recognised as ours and ignored. A "this one is mine" boolean was
    // the obvious alternative and it cannot survive a wheel burst: several
    // writes and several watcher events, with no guaranteed pairing between
    // them. Comparing content needs no pairing.
    conf.lastWritten = "mode=" + root.mode + "\ntemp=" + root.temp + "\n";
    conf.setText(conf.lastWritten);
  }

  function locate() { locateProc.running = true; }

  // Debounced: a wheel gesture over the glyph fires cycle() once per wheel
  // event, and each one used to mean a restart. Six of those inside a minute
  // used to hit systemd's start-rate limit -- see night-light.service -- so
  // this collapses a burst into one restart, applying whatever state is
  // current when the timer finally fires rather than whichever one queued it.
  function apply() { applyTimer.restart(); }

  Timer {
    id: applyTimer
    interval: 200
    repeat: false
    onTriggered: applyProc.running = true
  }

  Process {
    id: applyProc
    running: false
    command: ["systemctl", "--user", "restart", "night-light.service"]
  }

  Process {
    id: locateProc
    running: false
    command: [Paths.sourceDir + "/night-light/locate.sh"]
  }

  // mode and temp. Two writers, and that is the documented design: this
  // FileView's own setText() call in save() above, and a person with an
  // editor -- README.md names `temp` as the one hand-editable knob, on the
  // grounds that a settings panel for it is not worth building. watchChanges
  // is what makes a hand edit visible to this singleton at all; without it
  // the shell's stale in-memory temp would win the next mode change and
  // silently overwrite the edit. onTextChanged already re-parses idempotently,
  // so the only cost of watching our own writes too is one harmless reload
  // each time we save. Deliberately not calling apply() from here: our own
  // writes already restart the unit via onSaved below, and doing it again
  // here would double the restart on every mode change.
  FileView {
    id: conf
    path: root.confPath
    printErrors: false
    watchChanges: true
    // watchChanges only fires fileChanged; it does not re-read on its own --
    // reload() is what actually re-runs onTextChanged below, same as
    // location's FileView further down.
    onFileChanged: reload()

    // The bytes save() last wrote. Empty at startup, so the first read of an
    // existing conf is never mistaken for an echo of our own write.
    property string lastWritten: ""

    onTextChanged: {
      const text = conf.text();

      // Our own write, arriving back through the watcher. Ignoring it is what
      // keeps a wheel burst monotonic. The writes are asynchronous, so the
      // reload for an earlier one can land after cycle() has already advanced
      // past it; assigning that stale mode here would drag root.mode -- and so
      // the glyph -- backwards mid-gesture, and the next cycle() would then
      // step from the wrong place. Nothing is lost by skipping it: what this
      // would parse is exactly what we already hold in memory.
      if (text === conf.lastWritten) return;

      // Anything else is a hand edit, which is a documented way to change the
      // warm temperature -- see README's configuration table.
      const m = /^mode=(.*)$/m.exec(text);
      const t = /^temp=(\d+)$/m.exec(text);
      if (m && root.modes.indexOf(m[1].trim()) >= 0) root.mode = m[1].trim();
      if (t) root.temp = parseInt(t[1], 10);
    }
    // Only once the write has actually landed does the unit get told to
    // re-read it.
    onSaved: root.apply()
    onSaveFailed: error => console.warn("NightLightService: failed to write night-light.conf:", error)
  }

  // Written by locate.sh and never by the shell, so the write IS the
  // notification: a new fix lands here, this fires, and the unit picks it up.
  FileView {
    id: location
    path: Paths.stateDir + "/night-light-location.conf"
    printErrors: false
    watchChanges: true

    // True only for a live, on-disk rewrite -- not the initial load at
    // startup. Keyed off the watch signal itself rather than off "have we
    // ever seen text", the same shape wallpaperThemeFile uses in Theme.qml,
    // and for the same reason: on a fresh install this file does not exist
    // yet, so the initial load fires loadFailed rather than textChanged, and
    // a seen-flag would misread the fix that the startup locate() writes a
    // moment later as the initial load rather than as the live write it is.
    // The unit already started from this same file moments ago, so a
    // restart for the load that brought it up would be a second gamma fade
    // for nothing -- only a write after that counts.
    property bool liveChange: false
    onFileChanged: { liveChange = true; reload(); }

    onTextChanged: {
      const wasLive = location.liveChange;
      location.liveChange = false;

      const parts = location.text().trim().split(/\s+/);
      if (parts.length !== 2 || parts[0] === "") return;

      const changed = parts[0] !== root.lat || parts[1] !== root.lon;
      root.lat = parts[0];
      root.lon = parts[1];

      if (wasLive && changed && root.mode === "auto") root.apply();
    }

    // The file went away, so forget where we were. Without this the shell
    // keeps the last coordinates forever -- a deletion emits loadFailed, not
    // textChanged -- and two things go wrong at once: the glyph keeps claiming
    // a fix it no longer has, and putting the SAME file back reads as "no
    // change", so nothing restarts the unit. The unit meanwhile exited 0 with
    // "auto, but no location yet", which leaves a selected auto, a valid file
    // on disk, and nothing running. Observed, not theorised.
    //
    // Restarting on the way out too, rather than leaving the running gammastep
    // to carry on: run.sh is the decider here, and its answer without a
    // location is "nothing runs". A shell that quietly preserved a process
    // whose justification had vanished would be the same divergence between
    // conf and screen this whole design exists to avoid.
    //
    // Guarded on `located` so this is inert on a fresh machine, where the
    // absent file is simply the starting state and there is nothing to forget.
    onLoadFailed: {
      if (!root.located) return;
      root.lat = "";
      root.lon = "";
      if (root.mode === "auto") root.apply();
    }
  }

  // Once per session, per the design: a desktop resolves and never moves, a
  // laptop that has moved gets the right answer at its next login, and
  // `locate` covers the case of moving without logging out.
  Component.onCompleted: root.locate()

  IpcHandler {
    target: "nightlight"

    function cycle(): void { root.cycle(1); }
    function set(mode: string): void { root.setMode(mode); }
    function locate(): void { root.locate(); }

    function status(): string {
      if (root.mode === "off") return "off";
      if (root.mode === "on") return "on, " + root.temp + "K";
      return root.located
        ? "auto, " + root.lat + ":" + root.lon + ", " + root.temp + "K at night"
        : "auto, but no location yet -- try `qs ipc call nightlight locate`";
    }
  }
}
