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

  // The PATH applications are resolved against, substituted from Nix by
  // home/quickshell.nix. It is NOT this unit's own PATH, and the difference is
  // the whole point of this file's existence -- see appPath's comment there.
  //
  // Written as a placeholder rather than a literal so the list has exactly one
  // definition. A hand-copied list here would drift from the Nix one silently,
  // and the failure mode of that drift is an application that does not launch
  // and says nothing.
  readonly property string appPath: "@appPath@"

  // stderr is collected rather than discarded, and this is not cosmetic.
  //
  // Before this, run()'s shell ended in `>/dev/null 2>&1`, and systemd-run's
  // `Failed to find executable foot: No such file or directory` went into it.
  // The panel failed for a full day across a live session and produced exactly
  // zero log lines -- 214 entries, 92 of which could not launch, and nothing
  // anywhere said so. A launcher that cannot say why it failed costs more than
  // the failure.
  Process {
    id: launchProc
    running: false
    stderr: StdioCollector {
      onStreamFinished: if (text.trim().length > 0) console.warn("AppLaunch:", text.trim())
    }
  }

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
    //
    // PATH is prefixed here, in the launching shell, and that is the only place
    // it works. systemd-run resolves the executable in its OWN process, before
    // it creates the unit, so --setenv=PATH=... is too late and was measured to
    // do nothing. Prefixed rather than replaced so the unit's own closure stays
    // reachable; appended would let Debian's copy of a Nix tool win.
    launchProc.command = ["sh", "-c",
      'PATH="' + root.appPath + ':$PATH" setsid systemd-run --user --scope "$@" >/dev/null & exit 0',
      "sh"].concat(args, argv);
    launchProc.running = true;
    return true;
  }

  // The fallback launch, for when there is no systemd-run or nothing runnable
  // came out of the entry.
  //
  // This exists because DesktopEntry.execute() and Quickshell.execDetached()
  // both inherit quickshell.service's own PATH, which has no /usr/bin. Fixing
  // only run() would leave every fallback resolving against the narrow list --
  // and the fallback is reached on every quickshell start, during the window
  // before the canScope probe resolves, not just in theory.
  //
  // `exec` rather than `& exit 0`: there is no scope to create here, so the
  // shell has nothing to do after the application starts and should not stay
  // in the process tree as its parent.
  function exec(argv) {
    if (!argv || argv.length === 0) return false;
    launchProc.command = ["sh", "-c",
      'export PATH="' + root.appPath + ':$PATH"; exec setsid "$@" >/dev/null',
      "sh"].concat(argv);
    launchProc.running = true;
    return true;
  }
}
