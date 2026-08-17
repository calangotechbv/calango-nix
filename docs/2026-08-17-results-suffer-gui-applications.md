# Results: GUI applications — suffer

2026-08-17

Spec: `docs/superpowers/specs/2026-08-17-gui-application-migration-design.md`
Plan: `docs/superpowers/plans/2026-08-17-gui-application-migration.md`

## Phase 0: baseline, the five removals, and the GL question

### Pinned versions

Realised from the pinned flake input, not the registry (`nixpkgs#`
answers about `nixpkgs-unstable`, a different version — see `CLAUDE.md`).

```
$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.seahorse'
/nix/store/7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1

$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.gammastep'
/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11

$ sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.seahorse.version'; echo
47.0.1

$ sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.gammastep.version'; echo
2.0.11
```

`SH=/nix/store/7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1`
`GS=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11`

Both versions read `47.0.1` and `2.0.11`, confirming the pinned input was
consulted rather than the registry.

### Baseline

Captured read-only, before any removal:

```
=== Debian versions
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  seahorse gammastep thunar thunar-volman pcmanfm-qt emacs-lucid deskflow kitty \
  gnome-keyring gcr4
ii  deskflow 1.26.0.0
ii  emacs-lucid 1:30.1+1-6
ii  gammastep 2.0.9-1+b1
ii  gcr4 4.4.0.1-3
ii  gnome-keyring 48.0-1
ii  kitty 0.41.1-2+deb13u1
ii  pcmanfm-qt 2.1.0-2
ii  seahorse 47.0.1-2
ii  thunar 4.20.2-1+deb13u1
ii  thunar-volman 4.20.0-1

=== which binary a launcher would run today
$ command -v seahorse; command -v gammastep; command -v gammastep-indicator
/usr/bin/seahorse
/usr/bin/gammastep
/usr/bin/gammastep-indicator

$ systemctl --user show-environment | tr ':' '\n' | grep -nE 'nix-profile/bin|^/usr/bin'
30:/home/isutton/.nix-profile/bin
34:/usr/bin

=== .desktop ids, both sides
$ dpkg -L seahorse  | grep 'applications/.*desktop' | xargs -n1 basename
org.gnome.seahorse.Application.desktop

$ dpkg -L gammastep | grep 'applications/.*desktop' | xargs -n1 basename
gammastep-indicator.desktop
gammastep.desktop

$ ls -1 "$SH/share/applications/" "$GS/share/applications/"
/nix/store/7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1/share/applications/:
org.gnome.seahorse.Application.desktop

/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11/share/applications/:
gammastep.desktop
gammastep-indicator.desktop

=== the keyring daemon that seahorse must keep talking to
$ busctl --user status org.freedesktop.secrets | head -4
PID=2895
PIDFD=yes
PPID=2865
TTY=n/a

$ readlink -f /proc/2895/exe
/usr/bin/gnome-keyring-daemon

$ tr '\0' ' ' < /proc/2895/cmdline; echo
/usr/bin/gnome-keyring-daemon --foreground --components=pkcs11,secrets --control-directory=/run/user/1000/keyring

$ ls -l ~/.local/share/keyrings/
total 8
-rw------- 1 isutton isutton 3571 Aug 17 06:11 login.keyring
-rw------- 1 isutton isutton  207 Jul 15 15:52 user.keystore

=== the night-light split, before
$ systemctl --user show night-light.service -p ActiveState -p MainPID
MainPID=3810
ActiveState=active

$ readlink -f /proc/3810/exe
/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11/bin/.gammastep-wrapped

$ tr '\0' ' ' < /proc/3810/cmdline; echo
/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11/bin/gammastep -m wayland -l -22.9056 -47.0608 -t 6500 3000

$ ps --ppid 3810 -o pid,cmd
    PID CMD
(no rows besides the header — no children under 3810 in ps either)
```

All package states, `command -v` resolutions, `.desktop` ids on both
sides, and the secrets-service owner/PID matched what the plan expected.
One row did not, and it is the one worth dwelling on:

**The PATH position.** `~/.nix-profile/bin` sits at position 30 against
`/usr/bin` at position 34 on the manager's own `show-environment` — measured,
not assumed, and measured on the property that actually governs the
outcome. `seahorse`'s `.desktop` file carries `Exec=seahorse`, a bare
binary name, which a launcher resolves through `$PATH` rather than
through any path recorded in the `.desktop` file itself. With both the
apt and the Nix package installed side by side, this ordering — Nix's
profile ahead of `/usr/bin` — is what makes Nix's binary win the race,
not the version, not which package was installed more recently. It is
the same shape `CLAUDE.md` documents for `ExecCondition=/bin/sh -c
"command -v X"`: the PATH lookup happens, and where a directory sits on
that list is what decides. `command -v seahorse` still reported
`/usr/bin/seahorse` at this point because the baseline was captured
*before* the apt package was removed — package presence and the .desktop
race are two separate questions, and the second one only mattered once
the first became true.

**The night-light child search.** The plan's Step 2 expected "a child
under `/nix/store`" beneath `night-light.service`'s `MainPID`. There is
no child: `/proc/3810/task/3810/children` is empty and `ps --ppid 3810`
returns no rows. `quickshell/night-light/run.sh:112` is `exec "$@"`, and
line 110 documents why — "exec, so gammastep is this unit's own main
PID: `systemctl stop` then kills the gamma client directly rather than a
shell that happens to be holding it." MainPID 3810 *is* gammastep;
`/proc/3810/exe` resolves straight to
`…-gammastep-2.0.11/bin/.gammastep-wrapped`. The substance the plan
wanted — night-light already running the Nix binary — holds; the
specific shape it looked for does not exist on this unit, and a check
built to find a child would report by printing nothing. See "Defects
found in the plan" below.

### The five removals

`thunar`, `pcmanfm-qt`, `emacs-lucid`, `deskflow`, `kitty` were removed,
along with `thunar-volman`, which Thunar drags along — six packages, none
migrated. `kitty` because `home/quickshell.nix` already records that this
project installs `foot` and deleted the theme switcher's kitty path.

Confirmed with `dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n'` —
the status-abbreviation field, not the version, because
`dpkg-query -W -f='${Version}'` prints a version and exits `0` for an
`rc` package (removed, conffiles retained): that is exactly the state
`apt remove` leaves behind, and reading only the version would report a
removed package as present.

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' thunar
rc  thunar

$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' thunar-volman
rc  thunar-volman

$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' pcmanfm-qt
rc  pcmanfm-qt

$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' emacs-lucid
un  emacs-lucid

$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' deskflow
dpkg-query: no packages found matching deskflow

$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' kitty
dpkg-query: no packages found matching kitty
```

None read `ii`. `thunar`, `thunar-volman` and `pcmanfm-qt` are `rc`
(removed, conffiles retained); `emacs-lucid` is `un` (not installed,
nothing retained); `deskflow` and `kitty` are gone from dpkg's database
entirely — `dpkg-query -W` finds no match at all, which is the state one
level past `rc`. All six ways of reading "gone" are consistent with the
plan's expectation that this removal leaves zero installed; none of them
is the `ii`-with-a-version false positive `CLAUDE.md` warns about.

`seahorse`, `gammastep`, `gnome-keyring` and `gcr4` remain `ii`, confirmed
the same way:

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' seahorse gammastep gnome-keyring gcr4
ii  gammastep
ii  gcr4
ii  gnome-keyring
ii  seahorse
```

### The GL verdict

#### seahorse

Run bare, unwrapped, from a terminal inside the live Hyprland session:
`$SH/bin/seahorse` drew a window. **Needs no nixGL.**

Observation was the only instrument that could settle this. `ldd` is a
false negative for a toolkit that `dlopen`s its platform and GL plugins
rather than linking them — the same shape `CLAUDE.md` records for
`hyprpolkitagent`, where a binary starts, registers, and only dies the
instant it is asked to render. A clean `ldd` output proves nothing about
that failure mode either way, so it was not consulted for the verdict;
running the binary against the real compositor was.

#### gammastep

Run bare: `$GS/bin/gammastep -m wayland -O 4000` — the screen warmed and
the process ran until Ctrl-C. **Needs no nixGL.**

Here `ldd` *is* a valid instrument, and it agrees: `.gammastep-wrapped`
links zero of `libGL`, `libEGL`, `libgbm`, `libvulkan`. It links
`libdrm` and `libwayland-client` and drives the compositor through
`wlr-gamma-control`, a Wayland protocol extension rather than a
rendering surface. `CLAUDE.md` excludes `ldd` specifically for binaries
with a `dlopen`-based plugin architecture — Qt's platform plugins,
PipeWire's SPA modules — where the linkage a static tool sees and the
code path actually taken at runtime can diverge. `gammastep` is a plain
C program with no such indirection: what it links is what it runs.
Applying the exclusion here anyway — treating every GUI-adjacent binary
as an `ldd` false negative on principle — would be cargo-culting the
rule rather than using it for the reason it exists.

**The probe that produced `Zero outputs support gamma adjustment` was
invalid, and that is the controller's fault, not gammastep's.** Running
`$GS/bin/gammastep -m wayland -O 4000` alongside the running
`night-light.service` — whose MainPID is already an active gammastep
instance holding the compositor's gamma control — asked a second client
to take a resource only one client can hold at a time. The unit's own
gammastep did not relinquish it, so the second instance's request to
adjust gamma was refused and it printed `Warning: Zero outputs support
gamma adjustment` / `1/1 output(s) do not support gamma adjustment`.
That is not an ambiguous result and it is not evidence against
gammastep needing or not needing nixGL — it is what running two
exclusive clients against the same compositor resource produces, every
time, regardless of GL. The screen visibly warming during the same run
is the actual verdict; the warning is an artifact of a badly-designed
probe.

#### gammastep-indicator

Run bare: `$GS/bin/gammastep-indicator` produced a tray icon and printed
a geoclue2 complaint.

The complaint is pre-existing and irrelevant to this desktop.
`geoclue-2.0` is `rc` — not installed — and
`quickshell/night-light/run.sh:70-72` reads a fixed latitude/longitude
pair out of a state file rather than calling into geoclue at all, so the
indicator's inability to reach geoclue changes nothing this desktop
relies on.

The indicator is also redundant here: zero references to
`gammastep-indicator` across `quickshell/`, `home/` or `hypr/`, and
night-light on this desktop is driven by
`quickshell/night-light/NightLightService.qml` (imported by `Bar.qml`)
together with the `night-light.service` unit, neither of which touches
the indicator binary. Because nothing gates on it, **its GL status was
not measured and settles nothing** — the tray icon appearing is a weaker
signal than seahorse's window or gammastep's warming screen, and no
downstream task needs it resolved.

## Defects found in the plan

Two, both material to what Task 3 has to do differently from what the
plan as written would have produced.

**1. The night-light gate looks for a child process that cannot exist.**
The plan's Step 2 (and the report it produced) expected
`night-light.service`'s `MainPID` to have a child process under
`/nix/store` — the shape of a wrapper script forking off the real
binary. `quickshell/night-light/run.sh:112` is `exec "$@"`, and line 110
documents exactly why: `exec` replaces the shell rather than forking, so
`systemctl stop` kills the gamma client directly. MainPID *is*
gammastep. A check written against "the child" walks
`/proc/$MainPID/task/$MainPID/children`, finds it permanently empty, and
reports success or failure by printing nothing to distinguish "checked
and found none" from "the check never engaged" — precisely the shape
`CLAUDE.md` names as a pipeline that reports by staying silent. Task 3's
gate reads `MainPID`'s own `exe` instead of walking for children.

**2. The gammastep probe manufactured its own failure.** The plan's
Step 4 asked for `$GS/bin/gammastep -m wayland -O 4000` to be run
directly, without checking whether anything else already held the
compositor's gamma control. `night-light.service` was active at the
time with its own gammastep as MainPID, so the probe pitted two
exclusive clients against the same resource and then read the resulting
refusal as if it might be a GL problem. The defect is in the probe's
design, not in an ambiguous result it produced — the fix is to check
what already holds gamma control before running a second client against
it, which this task did not do until after the fact.
