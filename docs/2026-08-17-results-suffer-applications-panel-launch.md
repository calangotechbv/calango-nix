# Results: the Applications panel launch path — suffer

2026-08-17. Spec 11. Branch `panel-launch-path`.

The diagnosis this fix rests on is
`docs/2026-08-15-handover-suffer-applications-panel-launch.md`, carried onto the
mainline as this branch's first commit. Every claim in it that this work depended
on still held two days later: the `sh -c` string was unchanged, both fallback
sites were live, and `foot` was still `MISSING` on quickshell's own `PATH` read
from `/proc/<pid>/environ`.

Six commits. Three of them exist because an earlier one was wrong, and the
review found two more defects after that. The sequence is the useful part of this
record.

---

## The defect

`quickshell.service` runs with a curated `PATH` built to satisfy the commands the
shell itself invokes — `awk`, `nmcli`, `matugen`. `systemd-run` resolves the
executable **in its own process, against its own `PATH`, before it creates the
unit**, so an entry whose `Exec` is a bare `foot` was handed a list assembled for
something else. It resolved nothing, created no scope, and exited. Silently:
`--quiet` plus `>/dev/null 2>&1` discarded the one message that said why.

```
$ PATH="$QPATH" command -v foot        # $QPATH from the running process's environ
MISSING
```

## How much of the panel was affected — not asserted here

The handover reported 214 entries, 122 launching and 92 not, measured on
2026-08-15 by loading the real config in a second windowless quickshell.

**This document does not restate that figure and does not offer a replacement.**
Three attempts were made to re-census the population and they did not reconcile:

- A flat walk of `applications/` in each data directory gave 81 unique ids, 20
  absolute, 59 bare.
- A recursive walk gave 177 unique ids, 121 absolute, 54 bare — the difference
  being 107 `screensavers/*.desktop` entries in a subdirectory, which a flat walk
  misses and which are valid desktop ids under the XDG naming rule.
- The recursive resolution counts then failed to add up: 53 resolving plus 3
  failing against 54 bare entries. The arithmetic does not close, so the parsing
  is wrong somewhere — most likely `Exec` values carrying quotes, or the subdir id
  mangling colliding during deduplication.

A census whose totals do not reconcile is not evidence, and the earlier
`92 of 214` was produced by a method this document did not reproduce. So the
scale of the defect is recorded as unquantified here. **What the fix rests on is
the mechanism and the named cases below, neither of which needs a census.**

Two code comments previously quoted `57 of 59` from the flat walk. They now cite
the same caveat as this section.

## The named cases, each checked

`foot` is the case that matters and it is fully measured: `MISSING` on the unit's
`PATH` before, resolving after, and confirmed by the user opening it from the
panel. The user subsequently confirmed further applications that had not worked
before now launch; which ones was not recorded, and no attempt is made here to
name them.

Three entries resolve on neither `PATH`. Each was checked rather than assumed,
and **none of them is a panel failure** — a conclusion an earlier draft of this
document got wrong in all three cases:

- `emacs-mail.desktop` — `Exec=emacs`, `NoDisplay=true`. Never shown in the
  panel. It is also residue of spec 10, which removed `emacs-lucid` while
  `emacs-common` stayed installed and kept shipping the entry.
- `claude-code-url-handler.desktop` — `Exec="/home/isutton/.local/bin/claude" …`,
  `NoDisplay=true`. Never shown in the panel, and its target is an absolute path
  in double quotes, which this document's `awk` mis-binned as a bare name while
  quickshell's own parser strips the quotes.
- `vim.desktop` — `Exec=vim`, and `Terminal=true`. `AppLauncher.qml:95` prepends
  `root.terminal`, so `argv[0]` becomes `foot`, which resolves. The `vim` binary
  is absent from this machine, so the terminal will open and the command inside
  it will fail — but the launcher resolves fine and emits nothing.

So "no entry in the panel fails to resolve" is true, for three reasons an earlier
draft did not identify and instead predicted the opposite of.

## `uwsm app` was tested first, and is not an alternative

The handover named this as the question to answer before writing anything.

```
$ uwsm app -- foot.desktop     # quickshell's real PATH and XDG_DATA_DIRS
<3>Entry /home/isutton/.nix-profile/share/applications/foot.desktop points to missing executable foot
```

No scope was created. `uwsm app` finds the entry and then resolves its `Exec`
against the caller's `PATH`, exactly as `systemd-run` does, so a change of
mechanism could not have fixed this. One detail of it is better and worth
remembering: its message names the entry *and* the missing executable, where
`systemd-run` names only the executable.

An earlier attempt at this probe reported `Desktop entry not found` and that was
the probe's own fault — `env -i` had stripped `XDG_DATA_DIRS`.

---

## The fix, and the three things wrong with it

### 1. The `PATH` is widened in the launching shell

`home/quickshell.nix` gains `appPath`, one definition, substituted into
`AppLaunch.qml` through the same `@token@` mechanism the matugen config already
used. A hand-copied list in the QML would drift from the Nix one, and the symptom
of that drift is an application that does not launch and says nothing.

Widened **there** and not in the unit's own `PATH`, because two `command -v`
probes in the shell fail on purpose — `ddcutil` and `swww` — and would start
finding Debian's copies if `/usr/bin` joined the unit's list.

`--setenv=PATH=…` cannot work and was not used: it sets the *unit's* environment,
and `systemd-run` has already resolved the executable by then. The handover
measured that; this work did not re-litigate it.

The fallbacks were fixed in the same commit. `DesktopEntry.execute()` and
`Quickshell.execDetached()` both inherit the unit's narrow `PATH`, so fixing only
`run()` would have left a fallback that fails identically to the path it catches
for — and that fallback is reached in the window before the `canScope` probe
resolves, on every quickshell start.

### 2. It shipped inert

After the switch that was supposed to fix the panel, `foot` still did not start.

```
$ grep -n appPath ~/.config/quickshell/common/AppLaunch.qml
43:  readonly property string appPath: "…:/usr/bin:/bin:/usr/games"     # present

$ systemctl --user show quickshell.service -p NRestarts -p ActiveEnterTimestamp
NRestarts=0
ActiveEnterTimestamp=Mon 2026-08-17 06:11:42 -03                        # hours earlier
```

sd-switch decides what to restart by diffing unit *files*. This unit's text
mentioned nothing about `quickshellConfig`, so a change confined to the QML left
it byte-identical, sd-switch correctly did nothing, and quickshell went on serving
the previous generation's config from a store path with no symlink pointing at it.

**This was true of every quickshell change this flake ever made.** Any that
appeared to take effect did so because the session happened to be restarted for
another reason.

The unit now carries `X-Restart-Triggers = [ "${quickshellConfig}" ]`. Proven by
mutation: one comment line added to any file in the tree moved the store path
from `x9kylc08…` to `gbggpmkl…`, and reverting restored it.

Verified twice on real switches, and the second time is the stronger evidence
because nobody arranged it:

```
12:47:57   ActiveEnterTimestamp after the switch that added the trigger
13:08:08   ActiveEnterTimestamp after the next switch, restarted by the trigger itself
```

`NRestarts=0` throughout is correct rather than contradictory: sd-switch stops and
starts the unit, and a fresh start resets that counter. `ActiveEnterTimestamp` is
the property that moves.

### 3. It adopted every application's stderr

Letting the launching shell's stderr through ended the silence and was wrong. The
user's first successful launch is what showed it:

```
AppLaunch: warn: wayland.c:1854: compositor does not implement the xdg-toplevel-icon protocol
```

That is foot's own harmless warning, attributed to the launcher. `systemd-run
--scope` **execs into the application**, so after a successful launch that file
descriptor belongs to the app for as long as it runs. Every launched application
would have buffered its whole output inside the `StdioCollector` and reported it
as a launch error — and only on exit, since `onStreamFinished` fires on stream
close. The message arrived at 12:49:57, when that foot instance closed.

The shell now resolves the target itself, before `systemd-run` sees it, and
reports only that. Application streams go back to `/dev/null`. The target is
passed as its own positional argument rather than parsed out of argv, because the
token after `--` moves when a `--working-directory` precedes it.

```
resolvable bare name   -> ran; wrote its marker file; printed nothing
unresolvable name      -> AppLaunch: cannot resolve 'definitely-not-a-binary-xyz' on PATH
                          and no scope was created
```

### 4. Two defects the review found after all that

**`exec()` held the singleton `Process` for the application's lifetime.** It used
`exec setsid "$@"`, which replaces the shell, so the process quickshell spawned
*became* the application. `launchProc` is a singleton, so one fallback launch
would hold it for the whole session and every later launch would be dropped —
`running = true` on a busy `Process` is ignored, while `run()` and `exec()` both
still return `true`. Silent, and self-healing only when the user closes the app.
The exact species of silence this branch exists to remove, introduced by the fix
for it. It now backgrounds and exits, as `run()` does.

Whether `exec setsid` keeps the pid depends on whether the shell is already a
process-group leader, since `setsid` forks when it is and does not when it is
not. A hand probe under an interactive shell therefore shows it forking, and the
reviewer's probe against quickshell's own `Process` showed it not. The shape now
used does not depend on that distinction, which is why it was chosen over
adjudicating the two measurements.

**Prefixing `appPath` flipped the provenance of the launcher's own tools.**
`appPath` was prefixed, with a comment claiming that kept the unit's closure
reachable. Measured, that is exactly backwards:

```
prefixed   systemd-run -> /usr/bin/systemd-run
appended   systemd-run -> /nix/store/…-systemd-260.2/bin/systemd-run
prefixed   setsid      -> /usr/bin/setsid
appended   setsid      -> /nix/store/…-util-linux-2.42.2-bin/bin/setsid
```

Neither tool is in `~/.nix-profile/bin`, so `appPath` cannot supply them and a
prefix could only take them away — from `runtimeDeps`, which pins them on
purpose. Benign today, because the user manager is Debian's systemd anyway, but a
silent provenance flip of the kind spec 6 and spec 10 both paid for. `appPath` is
now appended, and `foot` still resolves from `~/.nix-profile/bin` either way.

---

## Two guards, and the first one was vacuous

Both were proven to fail by mutation, with the mutation confirmed by a count
before the build ran.

**The `appPath` content guard.** Its first version grepped `AppLaunch.qml` for
`/usr/bin` and **could never fail**: that file's own comments contain the literal
`/usr/bin`, so the guard matched its own prose. Proven by deleting `/usr/bin`
from the Nix list, at which point the build went green.

It now reads the property's value out of the substituted file and compares whole
colon-separated elements. With the same mutation it fails and names the value.
Whole-element and not substring, deliberately: `/usr/bin` is a substring of
nothing else in that list, but `/bin` is a substring of four of its six entries.

**This is the third check in this project to pass while the property it stood for
was false.** The only reason it was caught is that it was mutated before it was
trusted.

**The token guard.** No `@token@` may survive anywhere in the copied tree, the
same invariant `home/foot.nix` and `home/hyprland.nix` assert, enumerated by
syntax over the whole tree rather than by listing the files known to carry
tokens. Proven by planting one.

## A Nix builder inverts one of this repo's own rules

The first token guard was `left="$(grep -rl … | wc -l)"`, written that way
**because `CLAUDE.md` says to count explicitly rather than trust a pipeline that
reports by printing nothing**. Inside a builder that is exactly wrong, and it
failed the build with no diagnostic.

```
$ … runCommand "pipefail-probe" … "echo \$-; set -o | grep pipefail"
pipefail-probe> ehB
pipefail-probe> pipefail        on
```

`-e` and `pipefail` are both on, so `grep … | wc -l` aborts on grep's exit status
instead of yielding `0`. A condition is exempt from `set -e`, which is why
`home/foot.nix`'s guard has always been `if grep -q …; then`. `CLAUDE.md` now
distinguishes the two contexts.

---

## Defects found

1. **The first `appPath` guard was vacuous**, satisfied by the file's own
   comments. Caught by mutation.
2. **The fix shipped inert.** Nothing restarted the unit that reads the changed
   config. True of every quickshell change this flake had ever made, and never
   noticed.
3. **The obvious cure for the silence adopted every application's stderr.** Found
   only because the user pasted a journal line that named foot rather than the
   launcher.
4. **`exec()` held the singleton `Process` for the app's lifetime**, silently
   dropping every later launch. Found by the review.
5. **Prefixing `appPath` flipped `systemd-run` and `setsid` to Debian's copies**,
   with a comment asserting the opposite. Found by the review.
6. **`CLAUDE.md`'s "count explicitly" rule is wrong inside a Nix builder** and
   cost a build failure with no diagnostic.
7. **This document's own census did not reconcile across three methods**, and no
   figure is asserted as a result. The first attempt also set `IFS=:` and then
   wrote two paths separated by a space, so the first directory silently did not
   exist — `IFS` splits on the separator only, and a space stops being one once
   you have set that.
8. **This document predicted the wrong outcome for all three unresolvable
   entries**, having checked their `Exec` lines and not their `NoDisplay` or
   `Terminal` keys. Two are never shown in the panel and the third resolves
   through the terminal wrapper.
9. **`emacs-mail.desktop` is dead residue of spec 10.** Not caused here;
   surfaced here.

## Known gap, not fixed here

**`xdg-desktop-portal.service` has the same sd-switch blind spot and no trigger.**
Its unit is a verbatim store copy (`home/portals.nix:213`), and
`hyprland-portals.conf` (`:166`) is read by the frontend at startup. Editing that
config changes no unit text, so sd-switch will not restart the frontend and the
change will not take effect — precisely the defect fixed for quickshell above.

Not fixed on this branch, deliberately. The clean shape is a drop-in carrying
`X-Restart-Triggers`, which preserves the verbatim unit, but **whether sd-switch
diffs drop-ins as well as unit fragments was not measured**, and adding an
unverified mechanism at the end of a branch that has already shipped three wrong
fixes is not a trade worth making. Owner: whichever spec next touches the portal
config. Verify the drop-in actually triggers a restart before relying on it.

The rest of the tree was checked and is clean: `night-light.service` already
names `quickshellConfig` in its `ExecStart`, the audio drop-ins carry their store
paths, and `home/foot.nix` and `home/lf.nix` back no unit at all.

## Not measured

- **Whether the `StdioCollector` surfaces the launcher's own message.** The
  collector demonstrably works — it delivered foot's warning — and the shell
  demonstrably writes the message. That the two connect for a *failing* launch
  was not observed, because after the fix no entry shown in the panel fails to
  resolve.
- **Which applications the user confirmed beyond `foot`.** Only long-lived scopes
  from session start remain, so nothing readable identifies them.
- **Whether `runtimeDeps` is still accurate for its own purpose.** The handover
  said the same. The defect was never that the list is wrong; it was that one
  list answered two questions.
