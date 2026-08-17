# Results: the Applications panel launch path — suffer

2026-08-17. Spec 11. Branch `panel-launch-path`.

The diagnosis this fix rests on is
`docs/2026-08-15-handover-suffer-applications-panel-launch.md`, carried onto the
mainline as this branch's first commit. It was written two days earlier and every
claim in it that this work depended on still held: the `sh -c` string was
unchanged at `quickshell/common/AppLaunch.qml:66-67`, both fallback sites were
live, and `foot` was still `MISSING` on quickshell's own `PATH` read from
`/proc/<pid>/environ`.

Three commits, and only the first was the fix anyone set out to write. The other
two exist because the first one did not work and then worked wrongly.

---

## The defect

`quickshell.service` runs with a curated `PATH` built to satisfy the commands the
shell itself invokes — `awk`, `nmcli`, `matugen`. `systemd-run` resolves the
executable **in its own process, against its own `PATH`, before it creates the
unit**, so an entry whose `Exec` is a bare `foot` was handed a list assembled for
something else entirely. It resolved nothing, created no scope, and exited.

Measured on the live session before the fix, with `$QPATH` read from the running
process's `environ`:

```
$ PATH="$QPATH" command -v foot
MISSING
```

## The population, re-measured

The handover reported 214 entries with 122 launching and 92 not, measured on
2026-08-15 by loading the real config in a second windowless quickshell. Today's
population is smaller and was measured differently — by walking
`~/.local/share` plus the unit's own `XDG_DATA_DIRS`, deduplicating by desktop id
with first occurrence winning, and taking the first token of each `Exec=`. **The
two numbers are not comparable and the difference is not explained here**, since
nothing was measured that would explain it; several specs removed desktop
packages between the two dates.

```
directories searched, and .desktop files in each
  ~/.local/share                                    3
  <quickshell store>/share                          1
  ~/.nix-profile/share                              9
  ~/.local/share/flatpak/exports/share              (no applications/)
  /var/lib/flatpak/exports/share                    2
  /usr/local/share                                  (no applications/)
  /usr/share                                       68

83 files, 81 unique desktop ids
  absolute Exec    20
  bare-name Exec   59
  no Exec at all    2
```

Resolution of the 59 bare-name entries, against the unit's `PATH` and against
the new `appPath`:

| resolves on | count |
|---|---|
| the unit's `PATH` (before) | 2 |
| `appPath` (after) | 56 |
| neither | 3 |

The three that resolve on neither were each checked rather than assumed:

- `claude-code-url-handler.desktop` — `Exec="/home/isutton/.local/bin/claude" --handle-uri %u`.
  An absolute path inside double quotes, which this measurement's `awk` binned as
  bare because the first character is `"`. **An artifact of the measurement, not
  a defect**: the target exists, and quickshell's own `Exec` parser strips the
  quotes before `AppLaunch` ever sees it.
- `emacs-mail.desktop` — `Exec=emacs`, owned by `emacs-common`, and `emacs` is
  absent from the session `PATH` entirely. Genuinely dead, and it is residue of
  spec 10: `emacs-lucid` was removed while `emacs-common` stayed installed and
  kept shipping this entry.
- `vim.desktop` — `Exec=vim`, owned by `vim-common`, and `vim` is likewise
  absent. Genuinely dead and pre-existing.

So the fix moves bare-name resolution from 2 of 59 to 56 of 59, and the three
remainders are one measurement artifact and two entries whose binaries are not
on this machine at all.

## `uwsm app` was tested first, and is not an alternative

The handover named this as the question to answer before writing anything:
`uwsm` already owns the session's app scopes and resolves desktop entries itself,
so it might have made the hand-rolled `systemd-run` redundant.

It has the same defect. Run from quickshell's real `PATH` and real
`XDG_DATA_DIRS`:

```
$ uwsm app -- foot.desktop
<3>Entry /home/isutton/.nix-profile/share/applications/foot.desktop points to missing executable foot
```

No scope was created. `uwsm app` finds the entry and then resolves its `Exec`
against the caller's `PATH`, exactly as `systemd-run` does. A change of mechanism
could not have fixed this, so the handover's verified shape was the right one.

One detail of `uwsm` is better and is worth remembering: its message names the
entry *and* the missing executable, where `systemd-run` names only the
executable.

An earlier attempt at this probe reported `Desktop entry not found: "foot.desktop"`
and that was **the probe's own fault** — `env -i` had stripped `XDG_DATA_DIRS`.
The result above is the one taken with the real values.

---

## The fix, in three parts

### 1. The `PATH` is widened in the launching shell

`home/quickshell.nix` gains `appPath`, one definition, substituted into
`AppLaunch.qml` through the same `@token@` mechanism the matugen config already
used. A hand-copied list in the QML would drift from the Nix one, and the symptom
of that drift is an application that does not launch and says nothing.

Widened **there** and not in the unit's own `PATH`, because two `command -v`
probes in the shell fail on purpose — `ddcutil` in `BrightnessService.qml` and
`swww` in `WallpaperService.qml`, both recorded in `runtimeDeps`' comment — and
would start finding Debian's copies if `/usr/bin` joined the unit's list.

`--setenv=PATH=...` was not used because it cannot work: it sets the *unit's*
environment, and `systemd-run` has already resolved the executable by then. The
handover measured that and this work did not re-litigate it.

The fallbacks were fixed in the same commit, and that matters more than it looks.
`DesktopEntry.execute()` and `Quickshell.execDetached()` both inherit the unit's
narrow `PATH`, so fixing only `run()` would have left a fallback that fails
identically to the path it catches for — and that fallback is reached in the
window before the `canScope` probe resolves, on every quickshell start. Both now
go through `AppLaunch.exec()`.

### 2. The unit is restarted when the QML changes

**The first commit was correct and inert.** After the switch that was supposed to
fix the panel, `foot` still did not start.

```
$ grep -n 'readonly property string appPath' ~/.config/quickshell/common/AppLaunch.qml
43:  readonly property string appPath: "/home/isutton/.local/bin:/home/isutton/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:/usr/games"

$ systemctl --user show quickshell.service -p NRestarts -p ActiveEnterTimestamp
NRestarts=0
ActiveEnterTimestamp=Mon 2026-08-17 06:11:42 -03
```

The new code was on disk and the process serving it had been running since
06:11:42 — hours earlier. sd-switch decides what to restart by diffing unit
*files*, and this unit's text mentioned nothing about `quickshellConfig`, so a
change confined to the QML left the unit byte-identical. sd-switch correctly did
nothing, while quickshell went on serving the previous generation's config from a
store path with no symlink left pointing at it.

This was never specific to this change. **Every quickshell change this flake has
ever made had the same property**, so any that appeared to take effect did so
because the session happened to be restarted for another reason.

The unit now carries `X-Restart-Triggers = [ "${quickshellConfig}" ]`. Naming the
store path is the mechanism: the path changes whenever the config's contents
change, so the unit's text changes with it. Proven by mutation rather than
assumed — one comment line added to a QML file moved the path, and reverting
restored it:

```
before: /nix/store/x9kylc08dkialgiijvz4kjnnyk50y85s-quickshell-config
after:  /nix/store/gbggpmklsz7nscwpnl0sw6s95gwxlaab-quickshell-config
```

A restart is cheap here and takes no applications down with it: `KillMode=process`
was already set, and every app launched through `AppLaunch.qml` lives in its own
scope rather than in this unit's cgroup.

Verified on the next switch, by the user:

```
$ systemctl --user show quickshell.service -p NRestarts -p ActiveEnterTimestamp
NRestarts=0
ActiveEnterTimestamp=Mon 2026-08-17 12:47:57 -03
```

`NRestarts=0` is correct rather than contradictory: sd-switch stops and starts the
unit, and a fresh start resets that counter instead of incrementing it. The
timestamp is the property that moved, and the unit's trigger and the resolved
config agreed afterwards — both `x9kylc08…-quickshell-config`.

`foot` then opened from the panel.

### 3. The launcher reports its own failures and nothing else

The second commit ended the silence by letting the launching shell's stderr
through. That was wrong, and the user's first successful launch is what showed
it:

```
AppLaunch: warn: wayland.c:1854: compositor does not implement the xdg-toplevel-icon protocol
```

That is foot's own harmless warning, attributed to the launcher. `systemd-run
--scope` **execs into the application**, so after a successful launch that same
file descriptor belongs to the app for as long as it runs. Every launched
application would have buffered its whole output inside quickshell's
`StdioCollector` and then reported it as a launch error — and only on exit, since
`onStreamFinished` fires on stream close. The message above arrived at 12:49:57,
which is when that foot instance closed, not when it opened.

So the shell resolves the target itself, before `systemd-run` sees it, and reports
only that. Application streams go back to `/dev/null`: quickshell is not their
logger, and systemd already gives each one a scope.

The target is passed as its own positional argument rather than parsed back out
of argv, because the token after `--` moves when a `--working-directory` precedes
it.

Verified both ways against quickshell's real narrow `PATH`:

```
resolvable bare name    -> ran; wrote its marker file; printed nothing at all
unresolvable name       -> AppLaunch: cannot resolve 'definitely-not-a-binary-xyz' on PATH
                           and no scope was created
```

---

## Two guards, and the first one was vacuous

`home/quickshell.nix`'s `quickshellConfig` gained two build-time guards. Both
were proven to fail by mutation, with the mutation confirmed by a count before
the build ran.

**The `appPath` content guard.** Its first version grepped `AppLaunch.qml` for
`/usr/bin`, and **it could never fail**: that file's own comments contain the
literal `/usr/bin` — one of them explains that the unit's `PATH` has none — so the
guard matched its own prose. Proven by deleting `/usr/bin` from the Nix list, at
which point the build went green:

```
$ grep -c '^    "/usr/bin"$' home/quickshell.nix     # after the mutation
0
$ nix build … .#…activationPackage
/nix/store/zmbgx53r88imi2rb801x7rngqh86qgrm-home-manager-generation     # PASSED
```

It now reads the property's value out of the substituted file and compares whole
colon-separated elements. With the same mutation it fails and names the value:

```
AppLaunch.qml's appPath does not contain /usr/bin.
  value: /home/isutton/.local/bin:/home/isutton/.nix-profile/bin:/usr/local/bin:/bin:/usr/games
```

Whole-element comparison and not a substring, deliberately: `/usr/bin` happens to
be a substring of nothing else in this list, but `/bin` is a substring of four of
the six, so a substring test would keep passing after the wrong deletion.

**This is the third check in this project to pass while the property it stood for
was false.** The only reason it was caught is that it was mutated before it was
trusted.

**The token guard.** No `@token@` may survive anywhere in the copied tree, the
same invariant `home/foot.nix` and `home/hyprland.nix` already assert, and
enumerated by syntax over the whole tree rather than by re-listing the files
known to carry tokens. Proven by planting one:

```
unsubstituted token left in the quickshell tree:
…-quickshell-config/common/AppLaunch.qml:2:// @strayToken@
```

## A Nix builder inverts one of this repo's own rules

The first version of the token guard was
`left="$(grep -rl '@[a-zA-Z]*@' "$out" | wc -l)"`, written that way **because
`CLAUDE.md` says to count explicitly rather than trust a pipeline that reports by
printing nothing**. Inside a builder that is exactly wrong, and it failed the
build with no diagnostic at all.

Measured, rather than inferred from the symptom:

```
$ nix build …runCommand "pipefail-probe" … "echo \$-; set -o | grep pipefail"
pipefail-probe> ehB
pipefail-probe> pipefail        on
```

`-e` and `pipefail` are both on, so `grep … | wc -l` aborts on grep's exit status
instead of yielding `0`, and a bare `n="$(grep -c …)"` aborts the assignment
before any message can print. A condition is exempt from `set -e`, which is why
`home/foot.nix`'s guard has always been written `if grep -q …; then`. Both guards
here now use that shape.

---

## Defects found

1. **The spec's own first guard was vacuous** — see above. Caught by mutation,
   not by review.
2. **The fix shipped inert.** The launcher change was correct and had no effect,
   because nothing restarted the unit that reads it. A change to a config
   directory is invisible to sd-switch. This had been true of every quickshell
   change in this flake and had never been noticed.
3. **The obvious way to end the silence adopted every application's stderr.**
   Fixed in the third commit. Found only because the user reported a successful
   launch and pasted the journal line, which named foot rather than the launcher.
4. **`CLAUDE.md`'s "count explicitly" rule is wrong inside a Nix builder** and
   cost a build failure with no diagnostic.
5. **`emacs-mail.desktop` is dead residue of spec 10.** `emacs-lucid` was removed
   while `emacs-common` stayed installed and kept shipping an entry whose
   `Exec=emacs` resolves nowhere. Not caused by this spec; recorded because this
   spec's measurement is what surfaced it.
6. **A measurement error of this document's own.** The first attempt to count
   entries set `IFS=:` and then wrote `$HOME/.local/share $QDD` unquoted, so the
   space between them was literal and the first directory silently did not exist.
   The population figures above are from the corrected walk. `IFS` splitting is
   on the separator only — a space is not a separator once you have set that.

## Not measured

- **Whether the `StdioCollector` surfaces the launcher's own message.** The
  collector demonstrably works — it delivered foot's warning — and the shell
  demonstrably writes the message. That the two connect for a *failing* launch
  was not observed, because after the fix no entry in the panel fails to resolve.
- **Whether `runtimeDeps` is still accurate for its own purpose.** The handover
  said the same. The defect was never that the list is wrong; it was that one
  list served two questions.
- **The remaining two dead entries.** `emacs-mail.desktop` and `vim.desktop` will
  now produce an `AppLaunch: cannot resolve` line instead of silence, which is
  the intended behaviour rather than a regression. Removing them belongs to
  whichever spec next touches those packages.
