pragma Singleton

import Quickshell
import Quickshell.Io

// Launching an app into a transient scope of its own, rather than as a child of
// the shell.
//
// Lifted out of AppLauncher when the browser picker needed the same thing: the
// launcher hands over a DesktopEntry's command, the picker hands over that same
// command plus --profile-directory=..., and neither of them is a DesktopEntry
// by the time it matters. So this takes an argv.
//
// Why a scope at all: DesktopEntry.execute() reparents the app to systemd but
// leaves it inside quickshell.service's cgroup, so the shell and everything it
// ever launched share one -- no per-app accounting, and a `systemctl --user
// restart quickshell` would take the lot down with it (that part is currently
// held off by a KillMode=process drop-in, which this makes unnecessary for
// apps). GIO already does this for other launchers on this machine;
// app-code-*.scope and friends are the same mechanism.
Singleton {
  id: root

  // Resolved once at startup. Callers check it before relying on run().
  property bool canScope: false

  Process {
    command: ["sh", "-c", "command -v systemd-run >/dev/null 2>&1 && echo yes || echo no"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.canScope = text.trim() === "yes"
    }
  }

  Process { id: launchProc; running: false }

  // Desktop-entry field codes -- %f, %U, %i and friends. Quickshell strips most
  // of them when it parses Exec into `command`, but not reliably: a bare %F
  // survives on at least one entry here, and passing it through hands the app a
  // literal "%F" as an argument.
  function stripFieldCodes(argv) {
    return argv.filter(a => !/^%[a-zA-Z]$/.test(a));
  }

  // systemd refuses a duplicate unit name and launching the same app twice is
  // ordinary, so the name carries a random tail rather than a counter, which
  // would reset on every config reload and start colliding again.
  function unitName(base) {
    const safe = (base || "app").replace(/[^a-zA-Z0-9_.\-]/g, "-").slice(0, 48);
    return "app-" + safe + "-" + Math.random().toString(36).slice(2, 8);
  }

  // Returns false when there was nothing runnable or no systemd to run it
  // under, so the caller can fall back rather than silently doing nothing.
  function run(argv, unitBase, workingDirectory) {
    if (!argv || argv.length === 0 || !root.canScope) return false;

    let args = ["--unit=" + root.unitName(unitBase)];
    if (workingDirectory) args.push("--working-directory=" + workingDirectory);
    args.push("--");

    // The shell backgrounds and exits immediately so quickshell is left holding
    // nothing: systemd-run execs into the app, which is reparented to the systemd
    // user manager inside its own scope. Arguments go through "$@" so no part of
    // an Exec line is interpolated into shell quoting.
    launchProc.command = ["sh", "-c",
      'setsid systemd-run --user --scope --quiet "$@" >/dev/null 2>&1 & exit 0',
      "sh"].concat(args, argv);
    launchProc.running = true;
    return true;
  }
}
