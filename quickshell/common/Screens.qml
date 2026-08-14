pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick
import "."

// Which display counts as "the main one".
//
// Several surfaces are machine-wide rather than per-screen -- the bar's status
// pills and system tray, the notification popups -- and showing the same thing
// on every monitor is noise, not redundancy. They all resolve the target here so
// the name is written once; change primaryName and everything moves together.
Singleton {
  id: root

  // The default until something is chosen. Read back from disk at startup, and
  // rewritten by the monitor manager's "Main display" picker.
  property string primaryName: "HDMI-A-1"

  // Resolved rather than assumed. If primaryName is unplugged the role hands off
  // to the first connected screen, because the alternative is that pulling one
  // cable takes the tray and every notification with it.
  //
  // Written as a loop over the list rather than Quickshell.screens.find(...):
  // reading the list and each .name inside the binding is what registers the
  // dependencies, so this re-evaluates when a monitor comes or goes.
  readonly property var primary: {
    const list = Quickshell.screens;
    if (list.length === 0) return null;
    for (let i = 0; i < list.length; i++)
      if (list[i].name === root.primaryName) return list[i];
    return list[0];
  }

  // Whether the configured display is actually connected, as opposed to the
  // fallback above standing in for it.
  readonly property bool primaryPresent: {
    const list = Quickshell.screens;
    for (let i = 0; i < list.length; i++)
      if (list[i].name === root.primaryName) return true;
    return false;
  }

  // Worth offering a choice at all only where there is one to make.
  readonly property bool hasChoice: Quickshell.screens.length > 1

  function select(name) {
    if (!name || name === root.primaryName) return;
    root.primaryName = String(name);
    saveProc.command = ["sh", "-c",
                        'printf "%s" "$1" > "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/main-monitor.conf"',
                        "sh", root.primaryName];
    saveProc.running = true;
  }

  Process { id: saveProc; running: false }

  // Read once at startup. Nothing else writes this, and a reload picks it up
  // anyway. An empty or missing file leaves the default above in place -- which
  // is the state on every machine that has never chosen.
  FileView {
    id: pref
    path: Paths.stateDir + "/main-monitor.conf"
    printErrors: false
    onTextChanged: {
      const saved = pref.text().trim();
      if (saved !== "") root.primaryName = saved;
    }
  }
}
