pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

Singleton {
  id: root

  property list<string> wallpapers: []
  property string currentWallpaper: ""
  // Resolved by the detector below. "" while detecting, "none" if no backend is
  // installed. swww wins when present because it animates transitions itself;
  // swaybg is the fallback, and the one that is actually packaged everywhere --
  // Fedora has both, Debian only swaybg (swww is a cargo install there), which
  // is exactly why this is detected at runtime rather than named in a config.
  property string backend: ""
  // swaybg scaling mode: stretch | fill | fit | center | tile | solid_color
  property string mode: "fill"

  // Guards the one-shot restore of the saved wallpaper at startup.
  property bool restored: false

  // swaybg has no IPC, so changing wallpaper means "start the new one, then kill
  // the old". Starting first lets the new layer surface draw before the old one
  // goes away, which avoids a flash of empty background. setsid detaches it so it
  // outlives this sh.
  //
  // It does NOT, on its own, outlive a quickshell restart: setsid changes the
  // session and process group but not the cgroup, so swaybg stays inside
  // quickshell.service and the default KillMode=control-group takes it down with
  // the shell. That is why restoreSaved() has to respawn it at startup. A
  // KillMode=process drop-in under ~/.config/systemd/user/quickshell.service.d/
  // keeps it alive across restarts -- see ROADMAP.md.
  //   $1 = mode, $2 = path, $3 = "1" to no-op when swaybg is already running
  readonly property string swaybgScript: 'if [ "$3" = "1" ] && pgrep -x swaybg >/dev/null 2>&1; then exit 0; fi
old=$(pgrep -x swaybg || true)
setsid swaybg -m "$1" -i "$2" >/dev/null 2>&1 &
sleep 0.7
[ -n "$old" ] && kill $old 2>/dev/null
exit 0'

  // swww needs its daemon up before img does anything; start it on demand.
  //   $1 = path
  readonly property string swwwScript: 'swww query >/dev/null 2>&1 || { setsid swww-daemon >/dev/null 2>&1 & sleep 0.5; }
exec swww img "$1" --transition-type grow --transition-pos center --transition-duration 1'

  // Scan wallpaper directories
  Process {
    id: scanner
    command: ["sh", "-c",
      "find ~/Pictures/Wallpapers ~/Pictures -maxdepth 2 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) 2>/dev/null | sort -u | head -200"
    ]
    running: false
    stdout: SplitParser {
      onRead: data => {
        const path = data.trim();
        if (path !== "") {
          root.wallpapers = [...root.wallpapers, path];
        }
      }
    }
  }

  // Pick a backend at startup rather than hardcoding one.
  Process {
    id: detector
    command: ["sh", "-c",
      "for b in swww swaybg; do command -v $b >/dev/null 2>&1 && { echo $b; exit 0; }; done; echo none"
    ]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.backend = text.trim() || "none";
        if (root.backend === "none")
          console.warn("WallpaperService: no wallpaper backend found (tried swww, swaybg)");
        root.restoreSaved();
      }
    }
  }

  // Load saved wallpaper path
  FileView {
    id: configFile
    path: Paths.stateDir + "/wallpaper.conf"
    onTextChanged: {
      const saved = configFile.text().trim();
      if (saved !== "") root.currentWallpaper = saved;
      root.restoreSaved();
    }
  }

  Component.onCompleted: {
    scanner.running = true;
    detector.running = true;
  }

  function rescan() {
    wallpapers = [];
    scanner.running = true;
  }

  // Re-apply the saved wallpaper once, after both the backend and the config have
  // resolved. Nothing else starts swaybg at login, so without this the desktop
  // comes up bare.
  function restoreSaved() {
    if (restored || backend === "" || backend === "none" || currentWallpaper === "")
      return;
    restored = true;
    restoreProcess.command = applyCommand(currentWallpaper, true);
    restoreProcess.running = true;
  }

  // ifRunning: for swaybg, leave an already-running instance alone (a quickshell
  // reload shouldn't make the wallpaper blink).
  function applyCommand(path, skipIfRunning) {
    if (backend === "swww")
      return ["sh", "-c", swwwScript, "sh", path];
    return ["sh", "-c", swaybgScript, "sh", mode, path, skipIfRunning ? "1" : "0"];
  }

  function setWallpaper(path) {
    currentWallpaper = path;
    restored = true;  // an explicit pick supersedes the startup restore

    if (backend === "" || backend === "none") {
      console.warn("WallpaperService: no backend available, not applying", path);
    } else {
      setProcess.command = applyCommand(path, false);
      setProcess.running = true;
    }

    // Save to config
    saveProcess.command = ["sh", "-c", 'printf "%s" "$1" > "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/wallpaper.conf"', "sh", path];
    saveProcess.running = true;
  }

  Process {
    id: setProcess
    command: []
    running: false
  }

  Process {
    id: restoreProcess
    command: []
    running: false
  }

  Process {
    id: saveProcess
    command: []
    running: false
  }
}
