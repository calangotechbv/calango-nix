# Handover: the Applications panel launches nothing — suffer

2026-08-15

Diagnosis only. Nothing was changed; the bug is still live as this is written.
The fix at the bottom was verified by hand against the running session but is
not committed anywhere.

## The symptom

Open the Applications panel, pick an app, the panel closes and nothing opens.
No error dialog, no notification, nothing in the journal.

Some apps *do* still open — Chrome and 1Password among them. That split is the
whole diagnosis, and it is the fastest way to re-confirm the bug after any
change: **an entry opens if its `Exec` is an absolute path and does not if it
is a bare command name.**

## Root cause

`quickshell.service` runs with a curated `PATH` that contains no `/usr/bin`,
and that is the `PATH` that launched applications are resolved against.

Three facts compose into the failure. Each is independently true and each was
measured, not reasoned about:

1. **`home/quickshell.nix:157-158` sets `Environment = [ "PATH=${lib.makeBinPath
   runtimeDeps}" ]`.** `runtimeDeps` (`home/quickshell.nix:38`) is a deliberate
   closure: it was derived, as its own comment records at length, by grepping
   the `quickshell/` tree for every external command *the shell itself*
   invokes. It contains `gnugrep`, `gawk`, `nmcli`, `matugen`, `procps`. It
   contains no `/usr/bin`, no `~/.nix-profile/bin`, no `/opt`.

2. **`quickshell/common/AppLaunch.qml` launches apps with `systemd-run --user
   --scope -- <argv>`**, where `argv` comes straight from the desktop entry's
   `Exec`.

3. **`systemd-run` resolves the executable in its own process, against its own
   `PATH`**, before it creates the unit.

So an entry whose `Exec` is `foot` is handed to a `systemd-run` whose `PATH`
was assembled to satisfy `awk` and `nmcli`. It resolves nothing, creates no
unit, and exits.

It is silent because `AppLaunch.run()` passes `--quiet` and redirects the
launching shell to `>/dev/null 2>&1`. Nothing throws. The QML call succeeds.
There is no stderr collector on `launchProc`, so even if there were a message
it would go nowhere.

### The regression point

Commit `d63d9ab`, 2026-08-14 05:35, *"quickshell: the unit, wrapped in nixGL
and with an explicit PATH"*. That commit created the systemd unit and gave it
the explicit `PATH`. Before it, `home/quickshell.nix` had no unit at all and
quickshell inherited the full session environment, in which every desktop
entry resolved.

The commit is not wrong about what it set out to do. The gap is that
`runtimeDeps` answers the question "what does the shell run?" while the unit's
`PATH` also answers a second, unasked question: "what can the shell's users
run?" One list was made to serve both.

### This is not a stale-process problem

Worth stating because it is the first thing anyone will try. The `PATH` in
`~/.config/systemd/user/quickshell.service` line 5 is byte-identical to the
one in `/proc/<quickshell-pid>/environ`:

```
$ U=$(grep -oP '(?<=^Environment=PATH=).*' ~/.config/systemd/user/quickshell.service)
$ R=$(tr '\0' '\n' < /proc/3449/environ | grep -oP '(?<=^PATH=).*')
$ [ "$U" = "$R" ] && echo IDENTICAL
IDENTICAL
```

`systemctl --user restart quickshell` will not change anything. Neither will a
reboot.

It is also unrelated to the package removals and the uwsm migration that
happened on the same afternoon — `ydotool`, `libnotify-bin`, `inotify-tools`,
`fuzzel`, apt's `uwsm`. Those are adjacent in time and nothing more.

## The evidence

### Which binaries quickshell's PATH can see

`$QPATH` below is quickshell's `PATH`, read out of `/proc/<pid>/environ`.

```
$ for b in foot code firefox-esr thunar xterm emacs google-chrome-stable 1password; do
    printf "%-22s %s\n" "$b" "$(PATH="$QPATH" command -v "$b" 2>/dev/null || echo MISSING)"
  done
foot                   MISSING
code                   MISSING
firefox-esr            MISSING
thunar                 MISSING
xterm                  MISSING
emacs                  MISSING
google-chrome-stable   MISSING
1password              MISSING
```

Every one of them is present on the machine. None is reachable from the unit.

### What systemd-run does with an unresolvable name

The exact command `AppLaunch.run()` builds, run by hand with quickshell's
`PATH` and its stderr left visible:

```
$ env -i "PATH=$QPATH" XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HOME=/home/isutton \
    systemd-run --user --scope --unit=app-probe-missing-ddd444 -- foot
Failed to find executable foot: No such file or directory

$ systemctl --user list-units --all 'app-probe-missing*'
0 loaded units listed.
```

No unit is created. With `--quiet` and `2>&1 >/dev/null` in place, that message
does not exist either.

The same command with an absolute path, or with a bare name that happens to be
in the closure, works fine:

```
$ ... sh -c 'setsid systemd-run --user --scope --quiet "$@" >/dev/null 2>&1 & exit 0' \
      sh --unit=app-probe-abs-aaa111 -- /usr/bin/sleep 20
$ ... --unit=app-probe-bare-bbb222 -- sleep 20
$ systemctl --user list-units --all 'app-probe-*'
  app-probe-abs-aaa111.scope  loaded active running [systemd-run] /usr/bin/sleep 20
  app-probe-bare-bbb222.scope loaded active running [systemd-run] /nix/store/...-coreutils-9.11/bin/sleep 20
```

Note the second line: bare `sleep` resolved, but to Nix's coreutils, because
that is what the closure has. It is not that bare names fail — it is that they
resolve against the wrong list.

### How much of the panel is affected

Measured by loading the real config in a second, windowless quickshell against
the session's real `XDG_DATA_DIRS`:

```
PROBE canScope=true total=214 absolute=122 bare=92 noCommand=0
```

**214 entries: 122 launch, 92 do not.** Chrome (`/usr/bin/google-chrome-stable`)
and 1Password (`/opt/1Password/1password`) are in the working half, which is
why the panel looks half-alive rather than dead. The broken half includes
`foot`, `libreoffice`, `gimp-3.0`, `pcmanfm-qt`, `syncthing`, `deskflow`,
`kmail`, and the whole `lxqt-config-*` and `displaycal-*` families.

*(An earlier count of 216/123/93 was taken with two probe `.desktop` files
still on `XDG_DATA_DIRS`. 214/122/92 is the real one.)*

### The `entry.execute()` fallback fails identically

`AppLauncher.launchApp()` falls back to `entry.execute()` when `AppLaunch.run()`
returns false. That fallback is not a safety net here — it is bound by the same
`PATH`. A synthetic entry with `Exec=perl -e sleep(40)` (`perl` is in
`/usr/bin` and not in the closure), launched through the real `execute()`:

```
PROBE cmd=["perl","-e","sleep(40)"] canScope=true
PROBE execute() ->
$ pgrep -af "perl -e"
(no output)
```

No process. `execute()` returned normally and threw nothing.

### The journal, and why it is empty

```
$ journalctl --user --since "-2 hours" | grep -E "app-.*\.scope"
(nothing since 17:59)

$ journalctl --user -u quickshell --since "18:00" | wc -l
4
```

Those four lines are `StatusNotifierItem` property warnings from 18:01. In two
hours of a live session, a launcher that is being used and failing produced
exactly zero log lines. That is the strongest single argument for changing the
error handling alongside the `PATH`.

## A trap for whoever picks this up

`AppLaunch.canScope` reads **false** if you observe it naively, and that will
send you down the wrong path — it did here for a while.

`AppLaunch` is a QML singleton, so it is instantiated lazily, on first use. The
`Process` that probes for `systemd-run` starts at that moment and resolves a
few milliseconds later. Any code that touches `AppLaunch.canScope` as its
*first* contact with the singleton reads the initial `false`.

To measure it truthfully, force instantiation early and read it later:

```qml
property var warmLaunch: AppLaunch.canScope   // instantiate now
Timer { interval: 6000; running: true; onTriggered:
  console.log("canScope=" + AppLaunch.canScope) }   // read later
```

That reports `canScope=true`. The detection itself is fine — `command -v
systemd-run` returns `yes`, exit 0, in quickshell's own environment.

`DesktopEntries.applications` has the same shape: read it cold and you get
`values.length === 0` while the scan you just triggered runs. Warm it in a
property, read it on a timer.

`quickshell/browser/BrowserService.qml:159-165` already documents the
`canScope` race in prose. It is a known thing in this tree, just easy to
re-discover the hard way.

## The fix, and one that looks right but is not

### `--setenv=PATH=...` does not work

The obvious move fails. `--setenv` sets the environment of the *unit*;
`systemd-run` has already resolved the executable, in its own process, using
its own `PATH`, before that matters:

```
$ env -i "PATH=$QPATH" ... systemd-run --user --scope \
    --setenv=PATH="/usr/local/bin:/usr/bin:/bin" \
    --unit=app-probe-fix-eee555 -- perl -e 'sleep(15)'
$ systemctl --user list-units --all 'app-probe-fix*'
0 loaded units listed.
```

### Widening the launching shell's PATH does work

Verified against the live session:

```
$ APPPATH="/home/isutton/.local/bin:/home/isutton/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:/usr/games"
$ env -i "PATH=$QPATH" ... sh -c 'PATH="'"$APPPATH"':$PATH" setsid systemd-run \
    --user --scope --quiet "$@" >/dev/null 2>&1 & exit 0' \
    sh --unit=app-probe-fix2-fff666 -- perl -e 'sleep(15)'
$ systemctl --user list-units --all 'app-probe-fix2*'
  app-probe-fix2-fff666.scope loaded active running [systemd-run] /usr/bin/perl -e "sleep(15)"

$ ... sh -c 'PATH="'"$APPPATH"':$PATH" exec systemd-run --user --scope \
    --unit=app-probe-fix3-ggg777 -- foot --version'
Running as unit: app-probe-fix3-ggg777.scope; ...
foot version: 1.27.0 +pgo +ime +graphemes +toplevel-tag +blur -assertions
```

In `quickshell/common/AppLaunch.qml`, that is a change to the `sh -c` string
inside `run()`:

```qml
launchProc.command = ["sh", "-c",
  'PATH="$APP_PATH:$PATH" setsid systemd-run --user --scope --quiet "$@" >/dev/null 2>&1 & exit 0',
  "sh"].concat(args, argv);
```

with `APP_PATH` supplied from Nix rather than written into the QML by hand —
`~/.local/bin`, `~/.nix-profile/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`,
`/usr/games` is what was tested.

The reason to widen *here* and not to widen `runtimeDeps` is that the unit's
`PATH` is also what quickshell's own `command -v` probes see. Two of those are
load-bearing and documented as such in `home/quickshell.nix`: the `ddcutil`
probe in `brightness/BrightnessService.qml` and the `swww` probe in
`wallpaper/WallpaperService.qml` both fail *deliberately*, and both would start
finding Debian's copies if `/usr/bin` joined the unit's `PATH`. Whether that is
actually harmful was not established — but it is a behaviour change nobody
asked for, and the narrow fix avoids the question entirely.

### Two things to fold in at the same time

**The `execute()` fallback needs the same treatment or it stays a dead end.**
Fixing only `run()` leaves `AppLauncher.launchApp()` line 87 and
`BrowserService.qml:188` (`Quickshell.execDetached`) resolving against the
narrow `PATH`. They are reached whenever `canScope` is false, which is a real
window on every quickshell start, not a theoretical one.

**Drop `--quiet`, or collect stderr.** This failed silently for a full day
across a live session. `systemd-run` said exactly what was wrong — `Failed to
find executable foot: No such file or directory` — and the redirect threw it
away. A `StdioCollector` on `launchProc` that logs non-empty stderr would have
turned this into a one-minute diagnosis.

## What is not established

**Whether `uwsm app` is the better mechanism.** uwsm is already in
`runtimeDeps`, already owns the session's autostart scopes (`app-1password-
3397.scope` and friends at session start came from it), and resolves desktop
entries itself. It may make `AppLaunch`'s hand-rolled `systemd-run` redundant.
It was not tested — in particular, whether `uwsm app` invoked *from*
quickshell's environment resolves entries against the session environment or
against the caller's `PATH`. That is the question to answer first.

**Whether any of the 92 broken entries are ones the user actually wants.** The
list is dominated by `lxqt-config-*`, `displaycal-*`, and KDE leftovers. `foot`,
`libreoffice`, `gimp-3.0` and `syncthing` are the plausible ones. If the answer
is "only a handful", a narrower fix is defensible; the count above is not an
argument about severity on its own.

**Whether `runtimeDeps` is still accurate for its actual purpose.** This
handover did not re-derive it. The bug is not that the list is wrong — it is
that the list is doing two jobs.

## Reproducing from cold

1. `tr '\0' '\n' < /proc/$(pgrep -x quickshell)/environ | grep ^PATH=` — the
   curated closure.
2. `PATH="$QPATH" command -v foot` — `MISSING`.
3. `env -i "PATH=$QPATH" XDG_RUNTIME_DIR=/run/user/1000
   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HOME=$HOME
   systemd-run --user --scope --unit=probe-$RANDOM -- foot` — `Failed to find
   executable`, no unit.
4. Open the panel, pick Chrome: works. Pick foot: nothing.

Steps 1-3 are read-only. Step 4 is the user-visible statement of the same fact.

## Files

- `home/quickshell.nix:38` — `runtimeDeps`, the closure and its derivation comment
- `home/quickshell.nix:157-158` — `Environment = [ "PATH=..." ]`, the line that made this
- `quickshell/common/AppLaunch.qml` — `run()`, the `sh -c` string to change
- `quickshell/app-launcher/AppLauncher.qml:78-88` — `launchApp()` and the `execute()` fallback
- `quickshell/browser/BrowserService.qml:159-188` — the same fallback, and the `canScope` race written down
- commit `d63d9ab` — where the unit's `PATH` came from
