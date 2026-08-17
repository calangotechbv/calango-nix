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

The user ran each binary by hand, bare and unwrapped, from a terminal
inside the live Hyprland session — no automated check can watch a window
appear or a screen change color, so this step could only ever be theirs.
The observations below (a window for `seahorse`, the two warnings from
`gammastep`, the geoclue complaint from `gammastep-indicator`) are as the
user reported them.

#### seahorse

The user ran `$SH/bin/seahorse` and reported a window appeared. **Needs
no nixGL.**

Observation was the only instrument that could settle this, and it had
to be the user's. `ldd` is a false negative for a toolkit that `dlopen`s
its platform and GL plugins rather than linking them — the same shape
`CLAUDE.md` records for `hyprpolkitagent`, where a binary starts,
registers, and only dies the instant it is asked to render. A clean
`ldd` output proves nothing about that failure mode either way, so it
was not consulted for the verdict; the user watching the binary draw
against the real compositor was.

#### gammastep

The user ran `$GS/bin/gammastep -m wayland -O 4000` and reported the
screen warmed; the process ran until they sent Ctrl-C. **Needs no
nixGL.**

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
invalid, and that is the controller's fault, not gammastep's.** The
user's run of `$GS/bin/gammastep -m wayland -O 4000` happened alongside
the already-running `night-light.service` — whose MainPID is already an
active gammastep instance holding the compositor's gamma control — which
asked a second client to take a resource only one client can hold at a
time. The unit's own gammastep did not relinquish it, so the second
instance's request to adjust gamma was refused and the user saw it print
`Warning: Zero outputs support gamma adjustment` / `1/1 output(s) do not
support gamma adjustment`. That is not an ambiguous result and it is not
evidence against gammastep needing or not needing nixGL — it is what
running two exclusive clients against the same compositor resource
produces, every time, regardless of GL. The screen visibly warming
during the same run, also as the user reported it, is the actual
verdict; the warning is an artifact of a badly-designed probe.

#### gammastep-indicator

The user ran `$GS/bin/gammastep-indicator` and reported a tray icon
appeared, with a geoclue2 complaint printed alongside it.

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

## Phase 1: seahorse

`home/gui-apps.nix` moves `seahorse` to Nix while `gnome-keyring` and
`gcr4` deliberately stay on apt — the coupling is `org.freedesktop.secrets`
over D-Bus, a stable cross-version API, not shared libraries. `seahorse`
is deliberately **not** nixGL-wrapped: Task 1 measured that it draws
unwrapped against the real compositor, and wrapping it anyway would have
been an unexamined cost rather than a margin, so `guiPackages` in
`home/gui-apps.nix` names the bare `pkgs.seahorse`.

### Two defects surfaced while building the brief's guard code, verbatim

**1. The output type.** Step 1's code, taken verbatim, does not build.
`wrappedGuiApps` ends with `touch "$out"`, making its output a regular
*file*; `gui-apps-guard` is then `ln -s ${wrappedGuiApps} $out`, a
symlink to that file. Referencing that symlink from `home.packages`
fails `pkgs.buildEnv`, which requires every package it merges to be (or
resolve to) a directory:

```
error: builder for '.../home-manager-path.drv' failed with exit code 2;
       last 2 log lines:
       > structuredAttrs is enabled
       > pkgs.buildEnv error: The store path /nix/store/9yh6jiawm761vzzx5m6knnx58j6hzg2b-gui-apps-guard is a file and can't be merged into an environment using pkgs.buildEnv! at .../builder.pl line 140.
```

Fixed by changing `wrappedGuiApps`'s terminal `touch "$out"` to
`mkdir -p "$out"` — an empty directory instead of an empty file. The
guard's logic, its exemption derivation, and its `.desktop`-detection
mechanism are otherwise verbatim from the brief; only the output *type*
changed, so the guard still means "this ran and passed" and
`gui-apps-guard`'s `ln -s` (also verbatim) now links to a directory,
which `buildEnv` merges as an empty, harmless contribution.

**2. A self-authored comment, not the brief's code.** Explaining fix 1 in
a comment inside `wrappedGuiApps`'s own `''...''` string with the literal
text `${wrappedGuiApps}` self-referenced the attribute from within its
own definition, which Nix evaluates eagerly enough inside an interpolated
string to hit `infinite recursion encountered` at build time — this
attribute's own line, not user code elsewhere. Fixed by describing the
relationship in prose instead of naming the attribute, which sidesteps
Nix string interpolation entirely. Recorded here because it changed
`wrappedGuiApps`'s derivation text and so its output hash: `$NEW` moved
once more after this fix, to the value below.

Both defects have the same shape: the plan's Nix was written down
without ever being built. That is the same class of failure as spec 9's
`/dev/null` mask, where the runtime layer was probed by hand and passed,
and the build layer — whether Nix's evaluator would accept the same
shape — was assumed rather than checked. Here neither defect touches
runtime behavior at all; both are things `nix build` refuses before a
generation exists to run.

### Step 3: build

```
$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
/nix/store/nswj9agqc1qn88hlhcwwxcywpwvzh0bp-home-manager-generation
```

`NEW=/nix/store/nswj9agqc1qn88hlhcwwxcywpwvzh0bp-home-manager-generation`

### Step 4: the guard proven to fail, then restored

Pointed the detector at a name no wrapper produces:

```
$ sed -i "s/-name '\.\*-wrapped'/-name '.*-NOT-wrapped'/" home/gui-apps.nix
$ grep -n 'NOT-wrapped' home/gui-apps.nix
44:      wrapped="$(find "$pkg/bin" -maxdepth 1 -name '.*-NOT-wrapped' 2>/dev/null | wc -l)"

$ sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -8
       last 6 log lines:
       > 7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1 ships GSettings schemas but no wrapped binary.
       >   Its schemas are at share/gsettings-schemas/, which GLib does
       >   not search, and nothing here adds that to XDG_DATA_DIRS. The
       >   application would abort at startup with
       >   "Settings schema ... is not installed".
       >   Expected a .<name>-wrapped sibling in bin/ from wrapGAppsHook.
error: 1 dependencies of derivation '.../gui-apps-guard.drv' failed to build
```

The build failed with exactly the expected message. Restored and
confirmed the identical `$NEW`:

```
$ sed -i "s/-name '\.\*-NOT-wrapped'/-name '.*-wrapped'/" home/gui-apps.nix
$ grep -c 'NOT-wrapped' home/gui-apps.nix
0

$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
/nix/store/nswj9agqc1qn88hlhcwwxcywpwvzh0bp-home-manager-generation
```

Same store path as Step 3 — a guard proven able to fail, then shown to
reproduce the same output once restored.

### Step 5: what landed

```
=== the binary in the profile is the WRAPPER, not the raw ELF
$ ls -la "$NEW/home-path/bin/seahorse"
lrwxrwxrwx 1 root root 72 Dec 31  1969 .../home-path/bin/seahorse -> /nix/store/7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1/bin/seahorse
$ readlink -f "$NEW/home-path/bin/seahorse"
/nix/store/7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1/bin/seahorse

=== and the schema dirs it prefixes
$ strings "$(readlink -f "$NEW/home-path/bin/seahorse")" | grep -oE 'gsettings-schemas/[a-z0-9.+-]*' | sort -u
gsettings-schemas/gcr-3.41.2
gsettings-schemas/gsettings-desktop-schemas-50.1
gsettings-schemas/gtk+3-3.24.52
gsettings-schemas/seahorse-47.0.1

=== the .desktop it ships, and its Exec
$ ls -1 "$NEW/home-path/share/applications/" | grep -i seahorse
org.gnome.seahorse.Application.desktop
$ grep '^Exec' "$NEW/home-path/share/applications/org.gnome.seahorse.Application.desktop"
Exec=seahorse %u

=== flake check
$ sg nix-users -c 'nix flake check' 2>&1 | tail -1
running 2 flake checks...
```

All four expectations matched: `bin/seahorse` resolves into the store as
a symlink to the makeBinaryWrapper output; four `gsettings-schemas`
directories, including `seahorse-47.0.1`; the `.desktop` id is
`org.gnome.seahorse.Application.desktop` with the bare-name
`Exec=seahorse %u`; `nix flake check` exits `0` with both checks
(`no-dangling-home-files`, `no-pulseaudio-daemon`) passing.

### Steps 6 and 7: the switch, the removal, and the gate

The human ran the switch and `sudo apt remove seahorse`, then the gate.
The gate found one Critical, fixed it, and reproduced the gate clean.

### The Critical: seahorse could not be launched at all

`org.gnome.seahorse.Application.desktop` declares `DBusActivatable=true`.
A launcher honouring that never runs the entry's `Exec=` line — it asks
the session bus to activate the name instead, and the bus resolves that
through a `.service` file on its own search path, not through
`XDG_DATA_DIRS` the way a plain `Exec=` launch would. Measured before the
fix:

```
.desktop declares DBusActivatable=true, so a launcher never runs Exec=
StartServiceByName org.gnome.seahorse.Application -> 'The name is not activatable'
session bus XDG_DATA_DIRS: ...flatpak...:/usr/local/share/:/usr/share/   (no Nix profile)
copies in ~/.local/share/dbus-1/services/: 0
```

The bus's own `XDG_DATA_DIRS` — read from `/proc/<bus MainPID>/environ`,
not inferred — carries no `~/.nix-profile/share`, so the activation file
`pkgs.seahorse` ships was invisible to it, and `StartServiceByName`
returned `The name is not activatable`.

**`CLAUDE.md` had recorded this exact trap since spec 7** — "D-Bus
activation files must go into `XDG_DATA_HOME` via `xdg.dataFile`" — and it
was missed anyway. The plan's own text (Step 5's note, above) reasons
about `Exec=` and `PATH`: the two search orders it discusses. It never
considers that `DBusActivatable=true` takes the launch off both of those
paths entirely, onto a third one — D-Bus activation — that neither
mentions.

### Fix, and why the file on disk was not enough

Fixed with the same pattern `home/portals.nix` already uses three times:

```nix
xdg.dataFile."dbus-1/services/org.gnome.seahorse.Application.service".source =
  "${pkgs.seahorse}/share/dbus-1/services/org.gnome.seahorse.Application.service";
```

After the rebuild and a `home-manager switch`, the file landing at
`~/.local/share/dbus-1/services/` was not, by itself, sufficient:

```
AFTER (commit 006db5a adds the xdg.dataFile entry, then ReloadConfig):
  StartServiceByName -> u 1
  lrwxrwxrwx 1 isutton nix-users 130 Aug 17 08:20 /home/isutton/.local/share/dbus-1/services/org.gnome.seahorse.Application.service -> /nix/store/16kx5qwz682yqik8j7aviwcc0yjjmm86-home-manager-files/.local/share/dbus-1/services/org.gnome.seahorse.Application.service
```

`dbus-broker` caches its service directory at its own startup and never
rescans it on a switch — recorded in `CLAUDE.md`. The user ran
`busctl --user ReloadConfig` to make the new file visible; a fresh login
would have had the same effect. Only after that did `StartServiceByName`
return success.

### The gate

Captured 2026-08-17T08:26:29-03:00, after the switch, the apt removal,
and `busctl --user ReloadConfig`.

The live, launcher-started process:

```
pid=485425  comm=.seahorse-wrapp
exe=/nix/store/7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1/bin/.seahorse-wrapped
usr-maps=0
XDG_DATA_DIRS schema entries:
  gsettings-schemas/gcr-3.41.2
  gsettings-schemas/gsettings-desktop-schemas-50.1
  gsettings-schemas/gtk+3-3.24.52
  gsettings-schemas/seahorse-47.0.1
cgroup=0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-dbus\x2d:1.1\x2dorg.gnome.seahorse.Application.slice/dbus-:1.1-org.gnome.seahorse.Application@4.service
```

These four `gsettings-schemas` entries live on a single `XDG_DATA_DIRS=`
line inside `/proc/$p/environ`; a naive `grep -c gsettings-schemas` over
the raw environment returns `1` (one matching line), not four — the
count that matters is the number of directory entries within that line,
which is four, not the line count.

**The cgroup is the strongest line here.** The evidence file's own
summary of it reads: "the process sits under
`dbus-:1.1-org.gnome.seahorse.Application@3.service`, so it was started
through the D-Bus activation path — the exact mechanism that was
broken." The raw `cgroup=` field above and that summary sentence carry
different instance numbers (`@4` vs `@3`) for the same activation unit;
both are reproduced here exactly as captured, and neither changes what
the cgroup proves: the process's parent unit is a
`dbus-:1.1-org.gnome.seahorse.Application@` activation unit, not a bare
`Exec=` fork.

The daemon did not move:

```
:1.203                                        485425 .seahorse-wrapp isutton :1.203        user@1000.service -       -
:1.204                                        485425 .seahorse-wrapp isutton :1.204        user@1000.service -       -
org.freedesktop.secrets                         2895 gnome-keyring-d isutton :1.3          user@1000.service -       -
org.gnome.seahorse.Application                485425 .seahorse-wrapp isutton :1.203        user@1000.service -       -

org.freedesktop.secrets owner:
  exe=/usr/bin/gnome-keyring-daemon
  ii  gcr4 4.4.0.1-3
  ii  gnome-keyring 48.0-1
  seahorse: dpkg-query: no packages found matching seahorse
not installed
```

**`org.freedesktop.secrets` is still owned by PID 2895,
`/usr/bin/gnome-keyring-daemon`** — the same daemon, same PID, as Task 1's
baseline. That pairing is the task's thesis stated in two measurements:
the client (`org.gnome.seahorse.Application`, PID 485425) crossed to Nix
and was started by the activation path that had been broken, while the
daemon it talks to over `org.freedesktop.secrets` did not move at all.
`seahorse` itself is no longer an apt package (`dpkg-query: no packages
found matching seahorse`); `gnome-keyring` and `gcr4` remain `ii`.

By hand, reported by the user:
- `gtk-launch org.gnome.seahorse.Application` opened the window: YES
- The window lists the keyring contents served by Debian's daemon: YES

### A third trap the gate itself hit

The plan's Step 7 gate command was `pgrep -u "$USER" -x seahorse`, which
found nothing — not because seahorse was not running, but because Nix
wraps the binary and the kernel truncates `comm` at 15 characters, so the
running process reads `.seahorse-wrapp`, not `seahorse`. `CLAUDE.md`
documents this trap by name (`pgrep` on a Nix binary). The instrument
that actually worked was walking `/proc/*/exe` for the `/nix/store` path,
which is what produced `pid=485425` above.

## Phase 2: gammastep

Task 3 closed a split rather than starting a migration. `nightLightPath`
in `home/services.nix` had named `pkgs.gammastep` since `8a7b947`, long
before this task — it is the night-light unit's own `Environment=PATH`,
so the unit itself already ran Nix's `2.0.11`. What it fed from was never
`home.packages`, so a shell and both `.desktop` entries still resolved
Debian's `2.0.9`. Debian's `gammastep` was still installed alongside it:
two providers of the same binary on the same machine, the shape CLAUDE.md
already names for spec 6's `fumon` and the foot server. Task 3
(`6ed055b`) added `pkgs.gammastep` to `guiPackages` in `home/gui-apps.nix`
and the user removed Debian's package, closing the split rather than
moving anything that was not already moved.

### Provenance: PASS

Apt no longer has `gammastep` at all — not even as `rc`:

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' gammastep gammastep-indicator
dpkg-query: no packages found matching gammastep
dpkg-query: no packages found matching gammastep-indicator

$ ls -l /usr/bin/gammastep
ls: cannot access '/usr/bin/gammastep': No such file or directory
```

That distinction matters because `dpkg-query -W -f='${Version}'` alone
prints a version and exits `0` for an `rc` package — removed, conffiles
retained — which is exactly what `apt remove` leaves behind, and this
machine carries 128 of them. The `db:Status-Abbrev` form is the one that
tells the two states apart, and here it reports no package at all, not
`rc`.

The unit's own `MainPID`, read directly rather than through `command -v`
or a child process:

```
$ systemctl --user show night-light.service -p ActiveState -p MainPID -p NRestarts -p Environment
ActiveState=active
SubState=running
MainPID=597879
NRestarts=0
Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11/bin:...

# /proc walk by exe, since `pgrep -x gammastep` cannot match a Nix wrapper
597879 /nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11/bin/.gammastep-wrapped
  cmdline=.../bin/gammastep -m wayland -l -22.9056 -47.0608 -t 6500 3000
```

`pgrep -x gammastep` was not the instrument here for the same reason it
never is against a Nix binary: the wrapper's `comm` is truncated to
`.gammastep-wrapped`, and a name match against `gammastep` finds nothing
in either the working or the broken state. `NRestarts=0`, `exe` resolves
into the store, and `Environment=PATH` names only the derivation's own
`bin` — the unit does not depend on profile ordering at all, which is the
property `nightLightPath` was written to hold even before this task.

### Function: FAIL, cause not established

Every gamma client on the machine now fails identically:

```
Warning: Zero outputs support gamma adjustment.
Warning: 1/1 output(s) do not support gamma adjustment.
```

No warning appears anywhere in the journal before 2026-08-17T08:57:01, and
they are continuous after it while the unit is active — the count grows
only during that window, not indefinitely: measured counts of the `Zero
outputs support gamma adjustment` line alone were `169` at 09:04:25 and
`430` at 09:26:15. The last such warning was logged at 09:15:11, and the
unit stopped at 09:15:15, so `430` is the all-time total, fixed since
that stop, not a figure still climbing at the time of the second reading.
The distribution (none before 08:57:01, continuous after while running)
is what carries the argument here, not a bare total.

Several measurements bear on whether Task 3 caused this, and none of them
does.

The same store path had worked for nearly three hours earlier in this
session: the unit started at 06:11:42 with `-t 6500:3000` and logged no
warning until 08:57:01. The store path itself is byte-identical across the
working and failing period — the same derivation,
`/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11`, in the unit
fragment of generations 33, 34, and 35. Task 3 added a comment to the
`nightLightPath` let-binding and added the package to `home.packages`;
neither changes the derivation the unit actually runs. `gammastep` reaches
the unit through its `Environment=PATH`, not through `Exec=` — `ExecStart`
is `run.sh`, which then resolves `gammastep` off that PATH — and those
three identical paths in generations 33, 34, and 35 are the proof that the
derivation did not move, rather than an inference from it.

**A competing live client is ruled out**, using the union instrument
CLAUDE.md requires — `ps -eo args` matched against the full command line,
plus a `/proc` cmdline walk — rather than the exe-only `/proc` walk this
section originally relied on, which is exactly the instrument CLAUDE.md
calls insufficient (an exe-only walk covers roughly a quarter of this
machine's processes). With the unit already inactive:

```
$ systemctl --user show night-light.service -p ActiveState -p MainPID --value
inactive
0

$ ps -eo pid,user,args | grep -iE 'gammastep|indicator|redshift|sunset' | grep -v grep
(no output)

$ for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue;
    case "$c" in *gammastep*|*sunset*|*redshift*) echo "${p#/proc/} :: $c";; esac; done
(no match other than this shell's own command line)

$ timeout 4 ~/.nix-profile/bin/gammastep -m wayland -O 3000
Warning: Zero outputs support gamma adjustment.
Warning: 1/1 output(s) do not support gamma adjustment.
exit=124
```

Both instruments agree: nothing gammastep-shaped is alive anywhere on the
machine, yet a fresh client still fails. A client that had merely lost a
race against a live predecessor would succeed once that predecessor was
gone; this one does not, with nothing else alive to race against, so the
refusal is state held on the compositor side rather than a client-side
timing accident.

**A leaked control from an earlier probe is not ruled out, and this
document already put the candidate probes on record before this task
started.** The Phase 0 section above, written before Task 3, describes the
user hand-running `$GS/bin/gammastep -m wayland -O 4000` — interrupted
with Ctrl-C — and `$GS/bin/gammastep-indicator`, both inside this same
login session (which began at 06:11:39), and states plainly that gamma
control is single-holder and that this exact warning pair is what a second
client gets when it asks for a resource an active holder will not release.
Those probes ran before this section's "worked for nearly three hours"
window closed. The measurement above rules out a *live* competing client;
it does not rule out one of those interrupted runs leaving Hyprland holding
a gamma-control object it never released. If that is what happened, the
cause is this branch's own verification activity, not `pkgs.gammastep` —
a real cost of the work, and one this record should carry rather than
paper over.

Last, the protocol itself is still bound: gammastep prints a different
message when `zwlr_gamma_control_manager_v1` is absent entirely, and this
is not that message — reaching the per-output warning means the manager
bound and enumerated `eDP-1`; it is the per-output gamma control that came
back `failed`.

### What happened at 08:57

The Quickshell night-light toggle restarts the unit —
`quickshell/night-light/NightLightService.qml:102` is the `Process` whose
`command` is `["systemctl", "--user", "restart", "night-light.service"]`
— and the journal shows it firing twice within one second:

```
08:57:00 Stopping/Stopped                      <- the 06:11 client, killed
08:57:00 Started ... run.sh[596876]: night-light: off
08:57:01 Started ... run.sh[597144]: gammastep -m wayland -l ... -t 3000:3000
08:57:01 Warning: Zero outputs support gamma adjustment.
```

`run.sh`'s `off` branch, `quickshell/night-light/run.sh:63-66`, reports
`off` and exits 0 without execing anything, so in the interval between
those two `Started` lines no gamma client existed on the machine at all.
The client that started a second later got `failed`, and every client
since has too.

Hyprland is pid 3154, started 06:11:39 per `/proc`, and has not restarted
since — the same compositor process served the working 06:11:42 client
and is the one refusing every client from 08:57:01 on.

**The toggle path itself is not the trigger.** An earlier draft of this
section read only the four immediately preceding boots — a 40-line
journal window — and concluded this was the first mid-session restart the
machine had ever logged, then called the defect "latent in the toggle
path, exposed by testing." Over the full journal that premise is false:
mid-session `off` → 3000 → 6500 toggles ran warning-free on 08-13 16:06,
08-14 17:29, 08-15 10:30, and 08-15 23:17. **08-15 10:30:39** is the
decisive one, because it shows every step the failing 08:57:00 → 08:57:01
sequence shows — a stop, an `off` run that execs nothing, then a new
client roughly one second later, then a further restart:

```
2026-08-15T10:30:39 Stopping night-light.service
2026-08-15T10:30:39 Stopped night-light.service
2026-08-15T10:30:39 Started night-light.service
2026-08-15T10:30:39 night-light: off
2026-08-15T10:30:40 Started night-light.service
2026-08-15T10:30:41 night-light: gammastep -m wayland -l -23.6261:-46.7917 -t 3000:3000
2026-08-15T10:30:45 Stopping night-light.service
2026-08-15T10:30:49 Stopped night-light.service
2026-08-15T10:30:49 Started night-light.service
2026-08-15T10:30:49 night-light: gammastep -m wayland -l -23.6261:-46.7917 -t 6500:3000
```

No warning followed any of it. Generation 18 was active at that instant
(switched 2026-08-15 09:15:24; generation 19 followed at 10:49:08), and
its unit names the same store path the failing one does:

```
gen 17  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
gen 18  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
gen 19  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
```

08-15 23:17 is a secondary data point rather than the primary one: a
mid-session stop/start cycle under generation 23, three restarts inside
eleven seconds, warning-free, but without a `night-light: off` line in
its own journal block, so it does not license the `off`-toggle comparison
the way 10:30:39 does.

`8a7b947`, which put `pkgs.gammastep` into `nightLightPath`, is dated
2026-08-14 16:25:31; generation 15 (2026-08-14 17:53:57) is the earliest
generation verified to carry `gammastep-2.0.11`, consistent with that
landing date, and generations 1 through 19 all exist before the 10:30:39
exemplar above. The identical binary, an equivalent unit, and the same
stop / `off` / new-client-a-second-later / restart shape worked two days
ago and fail today, so the variable is neither the package nor the toggle
path. What triggers the refusal is unidentified; "latent in the toggle
path, exposed by testing" is deleted here rather than softened, because
08-15 10:30:39 is that same toggle path succeeding.

An attempt to recover by re-applying the monitor rule was rejected by
this Hyprland build outright and settles nothing either way:

```
$ hyprctl keyword monitor "eDP-1,1920x1200@60,0x0,1.25"
keyword can't work with non-legacy parsers. Use eval.
```

### The gate items still owed

Two Step 6 gate items belong in the record rather than being left
implicit:

- The `.desktop` uniqueness count passed: each of `gammastep.desktop` and
  `gammastep-indicator.desktop` resolves to exactly one file across the
  search path — `1` and `1`.
- The by-hand launcher and tray confirmation — launch
  `gammastep-indicator` from the launcher and confirm the tray icon,
  toggle night light from the shell panel and confirm the screen warms —
  has **not been run**. This is the same class of path Task 2 proved can
  fail silently for a different application, so it is recorded here as
  outstanding, not folded into the PASS above.

### Not measured

Whether a re-login recovers gamma control. The unit worked moments after
the 06:11 login and every client has failed since 08:57, which makes a
re-login the obvious next probe — but it is a probe, not a result, and it
was not run. Do not read anything above as having already answered it.

Nor is it established which candidate actually holds the leaked state: one
of the interrupted Phase 0 probes described above, or a monitor that lost
its gamma LUT size some other way — both fit every measurement taken here,
and nothing separates them. The Quickshell monitor panel applied a mode
during this session: the live scale is 1.25 against the 1.5 that
`hypr/hosts/suffer.lua` documents, so a monitor re-apply is a further
untested candidate, not a ruled-out one. `hyprctl keyword monitor` being
rejected by this build (above) leaves that recovery path unprobed as well.

`apt remove gammastep` was checked for orphans after the fact, not at
removal time, and found none:

```
$ grep -A4 'Commandline: apt remove gammastep' /var/log/apt/history.log
Commandline: apt remove gammastep
Requested-By: isutton (1000)
Remove: gammastep:amd64 (2.0.9-1+b1)
End-Date: 2026-08-17  08:42:10
```

One package, no orphans.

`night-light.service` was left in whatever state the user's own toggling
left it, rather than in the fixed state this section originally quoted: a
further toggle after the gate moved `MainPID` again, and by the time of
the union-instrument measurement above the unit was `inactive` with
`MainPID=0` because the last toggle switched it off. The warning recurs
whenever it is switched back on.

## Phase 3: the .desktop identity checks

Task 4 adds two `.desktop` identity checks and a third, unrelated-looking
guard that belongs with them. It was scheduled last on purpose: with no
migrated application, every one of them would have passed vacuously.

### Why this is two layers and not one

The obvious form — a flake check that reads `~/.config/mimeapps.list` and
`/usr/share/applications` and asserts every id it names resolves — cannot
exist. A flake check builds in the Nix sandbox, where both of those paths
are impure and invisible; there is no flag that makes them visible without
giving up the property that makes a flake check worth having. So the
property splits by what each layer can see:

- **`flake.nix`'s `gui-desktop-ids`**, fatal, at build time, over the ids
  *this flake itself ships* — which live in the built generation's
  `home-path/share/applications` and are therefore inside the sandbox.
- **`home/apps.nix`'s `mimeappsIds` activation hook**, non-fatal, at switch
  time, over the ids *the live file names* — which is the only layer that
  can read `~/.config/mimeapps.list` at all.

This is the same trap spec 9 paid for with the `/dev/null` mask: the runtime
question was probed by hand and passed, and the build question — whether Nix
would even accept the shape — was assumed. Here the build question is asked
first and answers "not like that", which is why the design has two halves
rather than one.

### Layer 1: `gui-desktop-ids`, the third flake check

`flake.nix` now carries a third check beside `no-dangling-home-files` and
`no-pulseaudio-daemon`, on the same generation and through the same
`activationPackage` binding the other two already trust. It asserts four ids
are present, each with the reason it is required:
`org.gnome.seahorse.Application.desktop`, `gammastep.desktop`,
`gammastep-indicator.desktop`, and `eu.calangotech.CalangoOpen.desktop`.

#### Two trees, because this flake ships `.desktop` entries two ways

The check searches both of these, and an id found in either satisfies the
requirement:

```
home-path/share/applications           <- home.packages, merged by buildEnv
home-files/.local/share/applications   <- xdg.dataFile entries
```

That is not symmetry for its own sake. The first version of this check read
`home-path` only, which made its own stated purpose — "the ids
`mimeapps.list` names AND this flake provides" — unreachable by its own
mechanism, because the single id satisfying both halves lives in the other
tree:

```
$ grep -n 'CalangoOpen' home/apps.nix
129:  config.xdg.dataFile."applications/eu.calangotech.CalangoOpen.desktop".source =
130:    "${desktopEntries}/eu.calangotech.CalangoOpen.desktop";

$ NEW=/nix/store/mrfhzdidk627kg1v9x345lasl4lwsm6j-home-manager-generation
$ ls -1 "$NEW/home-path/share/applications/"
footclient.desktop
foot.desktop
foot-server.desktop
gammastep.desktop
gammastep-indicator.desktop
mimeinfo.cache
org.gnome.seahorse.Application.desktop
org.quickshell.desktop
uuctl.desktop
xdg-desktop-portal-gtk.desktop

$ ls -1 "$NEW/home-files/.local/share/applications/"
code.desktop
eu.calangotech.CalangoOpen.desktop
```

`eu.calangotech.CalangoOpen.desktop` appears in the second listing and not
the first. Adding it to `required` while the check read only `home-path`
would have failed the build spuriously, so the fix was to widen the check
rather than narrow the claim.

#### What the four ids are for, and what the counts mean

`mimeapps.list` names six unique ids, of which this flake provides exactly
one. Measured:

```
$ sed -n 's/^[^=]*=//p' ~/.config/mimeapps.list | tr ';' '\n' | sed '/^$/d' | sort -u
bitwarden.desktop
claude-code-url-handler.desktop
eu.calangotech.CalangoOpen.desktop
eu.calangotech.KBrowserSelector.desktop
signal-desktop.desktop
slack.desktop

$ grep -c '=' ~/.config/mimeapps.list
12
```

Six unique ids across twelve assignment lines (ten under
`[Default Applications]`, two under `[Added Associations]`). **Both figures
are counts of 2026-08-17, not standing properties** — `bitwarden.desktop`
and `signal-desktop.desktop` are among the follow-on applications this
project intends to migrate, so the flake's share of that list is expected to
grow. That is the reason this check exists now rather than later.

`eu.calangotech.CalangoOpen.desktop` is the one id that is both named by a
handler and provided here: `x-scheme-handler/http`, `/https`, `text/html`,
`/about` and `/unknown` all resolve through it. The other three required ids
are named by no handler at all, and the check does not pretend otherwise;
they are asserted for their own sake, since a launcher entry that vanishes is
worth catching whether a MIME handler points at it or not, and they exercise
the `home-path` branch.

The failure this is really for arrives the moment a package is *added*:
nixpkgs' `signal-desktop` ships `signal.desktop` where Debian's ships
`signal-desktop.desktop`, and `mimeapps.list` names the Debian id for both
`x-scheme-handler/sgnl` and `x-scheme-handler/signalcaptcha` — visible in the
live file quoted under Layer 2 below. Migrate Signal without noticing and
both handlers stop resolving, with nothing on stderr.

#### No directory-existence preamble, and why that is not an inconsistency

Unlike the two checks beside it, this one carries no "does the directory
exist" opening, and the difference is the *direction of the assertion*. Those
two are negative checks — nothing dangling, no `pulseaudio` binary — where a
directory that stopped existing yields an empty result that reads as a pass,
which is why each opens by proving it is looking somewhere. This one is
positive: every id must be found in one tree or the other, so a broken
`$apps` or `$files` makes some `[ ! -e ... ]` pair true and the check fails.
Both branches are load-bearing and neither can rot unnoticed — the three
package ids exist only under `$apps`, `CalangoOpen` only under `$files` — and
that was proven by mutating each path in turn rather than argued.

#### Proven able to fail, on all three of its moving parts

Baseline before any of this — two checks, green:

```
$ sg nix-users -c 'nix flake check' 2>&1 | tail -5
evaluation warning: 'system' has been renamed to/replaced by 'stdenv.hostPlatform.system'
derivation evaluated to /nix/store/idv6vdfv2zp8f73ma2igig1dd16ky28z-portal-stack-no-dangling-home-files.drv
checking derivation checks.x86_64-linux.no-pulseaudio-daemon...
derivation evaluated to /nix/store/6nxz9n0mlr0fvn34yibpv7ym18lwq1nl-portal-stack-no-pulseaudio-daemon.drv
running 2 flake checks...
```

That is the only transcript in this section using the piped form, and its
exit status is deliberately not quoted: `… | tail -5` reports `tail`'s
status. The evidence here is the `running 2 flake checks...` line, which
`nix` prints only on the path where every check succeeded.

Every mutation below was confirmed to have landed with an explicit count
*before* the check was run against it. The `sed` for the first one matches
twelve literal leading spaces, and a `sed` that matches nothing still exits
0, so without the count a check that never engaged would have been recorded
as a check proven to fail.

Note the shape of every invocation here: output is redirected to a file and
the exit status read from the redirected command, then the file is quoted
separately. A `nix flake check … | tail -8; echo $?` reports `tail`'s status,
not the build's — `pipefail` is off — so that form cannot show a failing
exit code at all. An earlier draft of this section printed `exit=1` under
exactly that form; the conclusion was right and the transcript could not have
produced it.

**1. A renamed id (the `$apps` branch, via the `required` list).**

```
$ sed -i 's/^            gammastep.desktop gammastep-launcher/            gammastep-WRONG.desktop gammastep-launcher/' flake.nix
$ grep -c 'gammastep-WRONG' flake.nix
1

$ sg nix-users -c 'nix flake check' >/tmp/fc-wrong-id.out 2>&1; echo "exit=$?"
exit=1
$ grep -E 'missing .desktop id|under a different name' /tmp/fc-wrong-id.out
       > missing .desktop id: gammastep-WRONG.desktop (needed for: gammastep-launcher)
       >   under a different name, or an xdg.dataFile entry was
```

Restored, confirmed by count in both directions:

```
$ sed -i 's/^            gammastep-WRONG.desktop gammastep-launcher/            gammastep.desktop gammastep-launcher/' flake.nix
$ grep -c 'gammastep-WRONG' flake.nix
0
$ grep -c '^            gammastep.desktop gammastep-launcher' flake.nix
1
```

**2. The `$files` branch, drifted.** This is the branch the widening added,
and it needed its own proof — the mutation above exercises only `$apps`, so
without this the new search path would have been untested code:

```
$ sed -i 's|.../home-files/.local/share/applications$|.../home-files/.local/share/NOPE|' flake.nix
$ grep -c 'home-files/.local/share/NOPE' flake.nix
1

$ sg nix-users -c 'nix flake check' >/tmp/fc-files-broken.out 2>&1; echo "exit=$?"
exit=1
$ grep -E 'missing .desktop id|Looked in both trees|NOPE' /tmp/fc-files-broken.out
       > missing .desktop id: eu.calangotech.CalangoOpen.desktop (needed for: mimeapps-http-https-texthtml-about-unknown-handler)
       >   Looked in both trees this flake ships entries to:
       >     /nix/store/mrfhzdidk627kg1v9x345lasl4lwsm6j-home-manager-generation/home-files/.local/share/NOPE
```

Only `CalangoOpen` failed — the three package ids were still found under
`$apps` — which is the precise evidence that `CalangoOpen` is satisfied by
the new branch and by nothing else.

**3. The `$apps` branch, drifted**, for the mirror image:

```
$ sed -i 's|.../home-path/share/applications$|.../home-path/share/NOPE|' flake.nix
$ grep -c 'home-path/share/NOPE' flake.nix
1

$ sg nix-users -c 'nix flake check' >/tmp/fc-apps-broken.out 2>&1; echo "exit=$?"
exit=1
$ grep -E 'missing .desktop id' /tmp/fc-apps-broken.out
       > missing .desktop id: org.gnome.seahorse.Application.desktop (needed for: seahorse-launcher)
```

Both paths restored, each confirmed by count in both directions
(`home-files/.local/share/NOPE` → 0 and the real `files=` line → 1;
`home-path/share/NOPE` → 0 and the real `apps=` line → 1), and the check
green again:

```
$ sg nix-users -c 'nix flake check' >/tmp/fc-final.out 2>&1; echo "exit=$?"
exit=0
$ grep -n 'checking derivation' /tmp/fc-final.out
5:checking derivation checks.x86_64-linux.no-dangling-home-files...
8:checking derivation checks.x86_64-linux.no-pulseaudio-daemon...
10:checking derivation checks.x86_64-linux.gui-desktop-ids...
$ tail -1 /tmp/fc-final.out
running 3 flake checks...
```

Three named checks, exit 0. The `evaluation warning: 'system' has been
renamed` line on a green run is pre-existing and untouched.

### Layer 2: `mimeappsIds`, the activation hook

`home/apps.nix` gains a non-fatal `home.activation.mimeappsIds`, ordered
`entryAfter [ "linkGeneration" "installPackages" "defaultBrowser" ]`.

#### The search path spans two trees, and only one of them is on `XDG_DATA_DIRS`

The hook's loop searches `$XDG_DATA_DIRS` **and** `$HOME/.local/share`, and
the second is the load-bearing half rather than a belt-and-braces addition:

```
$ echo "$XDG_DATA_DIRS" | tr ':' '\n' | nl
     1	/home/isutton/.nix-profile/share
     2	/home/isutton/.local/share/flatpak/exports/share
     3	/var/lib/flatpak/exports/share
     4	/usr/local/share
     5	/usr/share
```

`~/.local/share` is not on that list at any position — only
`~/.local/share/flatpak/exports/share`, a different directory. And
`~/.local/share/applications` is exactly where this module's own
`xdg.dataFile` entries land, `eu.calangotech.CalangoOpen.desktop` included
(the same split Layer 1 had to widen for). A hook searching `XDG_DATA_DIRS`
alone would have reported this flake's own default browser as missing on
every switch.

#### Three ordering edges, all real, none inherited from an attribute name

The first version declared only `entryAfter [ "linkGeneration" ]`, and that
was not enough. Two of its three real dependencies were unstated:

| edge | why |
| --- | --- |
| `linkGeneration` | creates `~/.local/share/applications/*.desktop` from the `xdg.dataFile` entries — half the search path |
| `installPackages` | builds `~/.nix-profile`, and so populates `~/.nix-profile/share/applications`, the first entry on `XDG_DATA_DIRS` — the other half |
| `defaultBrowser` | rewrites the very file the hook reads, via `xdg-settings set default-web-browser` |

Home Manager's `hm.dag.topoSort` feeds `builtins.attrValues` — attribute-name
sorted — into a stable `lib.toposort`, so any pair of entries with no stated
relation is ordered alphabetically. Measured on the built script with only
the one edge declared — generation
`/nix/store/491v1scgzdqc3qz6g667p1adn0049apq-home-manager-generation`, the one
this task first produced — every hook after `linkGeneration` sat in
alphabetical order *except* the one pair with a real edge between them:
`desktopDatabase` (302) before `defaultBrowser` (308), which `defaultBrowser`
itself declares with `entryAfter [ "desktopDatabase" ]` and has since the
branch base `3afbf7a` (`git show 3afbf7a:home/apps.nix | grep -n entryAfter`
prints both hooks' edges). Corrected here after the whole-branch review: the
listing below always showed that pair, and the sentence above it used to say
"exactly alphabetical", which the listing contradicts.

```
$ G=/nix/store/491v1scgzdqc3qz6g667p1adn0049apq-home-manager-generation
$ grep -n '_iNote "Activating %s"' "$G/activate" | sed 's/_iNote "Activating %s" //'
270:"linkGeneration"
302:"desktopDatabase"
308:"defaultBrowser"
317:"footThemeColors"
324:"gtkAppearance"
334:"hyprlockConf"
342:"installPackages"
372:"mimeappsIds"
391:"onFilesChange"
394:"pipewireSessionManagerAlias"
407:"reloadSystemd"
```

So `mimeappsIds` ran after `defaultBrowser` and `installPackages` only
because the letter `m` sorts after `d` and `i`. This is the same defect
`home/audio.nix`'s `pipewireSessionManagerAlias` already paid for, in a new
place, and it was latent here — the live order was correct, so nothing was
broken. That is exactly when it is cheap to fix.

Declaring the two missing edges does **not** change the live order — with
`mimeappsIds` as the attribute name it still lands at 372 with
`installPackages` at 342, byte-identically to the listing above. That is the
whole reason a rename was needed to test the fix: on this attribute name, a
correct DAG and a lucky alphabet are indistinguishable.

**Proven both ways by renaming the attribute**, which is the only mutation
that isolates a tie-break from a declared edge. `auditMimeappsIds` sorts
*first* of all the post-`linkGeneration` hooks.

With the three edges declared, the rename does not move it ahead of its
dependencies:

```
$ grep -c '^  config.home.activation.auditMimeappsIds =$' home/apps.nix
1
$ M=$(sg nix-users -c 'nix build --no-link --print-out-paths \
      .#homeConfigurations."isutton@suffer".activationPackage')
$ grep -n '_iNote "Activating %s"' "$M/activate" | sed 's/_iNote "Activating %s" //'
270:"linkGeneration"
302:"desktopDatabase"
308:"defaultBrowser"
317:"installPackages"
347:"auditMimeappsIds"
366:"footThemeColors"
373:"gtkAppearance"
383:"hyprlockConf"
391:"onFilesChange"
```

It landed at 347, behind `defaultBrowser` (308) and `installPackages` (317)
and ahead of `footThemeColors` (366) — a position alphabetical order cannot
explain, so the edges are what put it there. Note `installPackages` also
*moved*, from 342 to 317, which is the DAG re-solving around the new
constraint rather than the old order surviving by luck.

Then the same rename with the two new edges reverted, reproducing the
defect:

```
$ grep -c '"installPackages" "defaultBrowser"' home/apps.nix
0
$ M2=$(sg nix-users -c 'nix build --no-link --print-out-paths \
       .#homeConfigurations."isutton@suffer".activationPackage')
$ grep -n '_iNote "Activating %s"' "$M2/activate" | sed 's/_iNote "Activating %s" //'
270:"linkGeneration"
302:"auditMimeappsIds"
321:"desktopDatabase"
327:"defaultBrowser"
336:"footThemeColors"
343:"gtkAppearance"
353:"hyprlockConf"
361:"installPackages"
391:"onFilesChange"
```

At 302 it now runs *before* `defaultBrowser` (327) and `installPackages`
(361) — reading the file before it is rewritten and searching a profile
before it is built, with nothing to distinguish that from a genuine finding.
So the fix is not a no-op: the hazard was real and the edges are what close
it.

Both mutations were reverted and the generation reproduced at the identical
store path it had before either
(`/nix/store/mrfhzdidk627kg1v9x345lasl4lwsm6j-home-manager-generation`), with
`auditMimeappsIds` → 0, the `mimeappsIds` attribute → 1, and the three-edge
`entryAfter` line → 1.

**`entryAfter`, not `entryBetween`, and that is deliberate.** The in-repo
precedent, `pipewireSessionManagerAlias`, needs `entryBetween` because its
second edge is real: `reloadSystemd` must come *after* the alias link or
systemd never sees it. Here nothing downstream reads anything this hook
produces — it only writes warnings to stderr — so the `before` list would be
empty, and `entryBetween [] xs` is by definition `entryAfter xs`. Declaring
an empty edge would state a constraint that does not exist. The fragility was
entirely on the `after` side and all three of those are now stated.

#### Why non-fatal

Non-fatal is a requirement, not a convenience, and the live file is why. Its
full contents:

```
$ cat ~/.config/mimeapps.list
[Added Associations]
x-scheme-handler/http=eu.calangotech.KBrowserSelector.desktop;
x-scheme-handler/https=eu.calangotech.KBrowserSelector.desktop;

[Default Applications]
x-scheme-handler/http=eu.calangotech.CalangoOpen.desktop
x-scheme-handler/https=eu.calangotech.CalangoOpen.desktop
x-scheme-handler/slack=slack.desktop
x-scheme-handler/bitwarden=bitwarden.desktop
x-scheme-handler/claude-cli=claude-code-url-handler.desktop
x-scheme-handler/sgnl=signal-desktop.desktop
x-scheme-handler/signalcaptcha=signal-desktop.desktop
text/html=eu.calangotech.CalangoOpen.desktop
x-scheme-handler/about=eu.calangotech.CalangoOpen.desktop
x-scheme-handler/unknown=eu.calangotech.CalangoOpen.desktop
```

Most of those ids belong to applications this flake does not own and never
will — flatpak Slack, bitwarden, `claude-code-url-handler`, Signal. Whether
they resolve is none of this flake's business, and it must never be the
reason a switch aborts.

#### The hook is in the built script, and `DRY_RUN` cannot exercise it

```
$ NEW=/nix/store/mrfhzdidk627kg1v9x345lasl4lwsm6j-home-manager-generation
$ grep -n 'mimeappsIds' "$NEW/activate"
372:_iNote "Activating %s" "mimeappsIds"

$ grep -n -E '_iNote "Activating %s" "(linkGeneration|installPackages|defaultBrowser|mimeappsIds)"' "$NEW/activate"
270:_iNote "Activating %s" "linkGeneration"
308:_iNote "Activating %s" "defaultBrowser"
342:_iNote "Activating %s" "installPackages"
372:_iNote "Activating %s" "mimeappsIds"

$ DRY_RUN=1 "$NEW/activate" 2>&1 | grep -c -i 'mimeapps'
4
$ DRY_RUN=1 "$NEW/activate" 2>&1 | grep -i -A3 'mimeappsIds'
Activating mimeappsIds
/nix/store/3d6jlqvsnq8p2ix98j3qkb4i6wsk3ak1-bash-interactive-5.3p9/bin/sh -c
  list="$HOME/.config/mimeapps.list"
  [ -r "$list" ] || exit 0
```

The hook is present and behind all three of its declared dependencies. What the
dry run does **not** do is run it: under `DRY_RUN` the `run` wrapper prints
the command instead of executing it, which is the whole point of `run` and
is why no warning appears above. So this output proves the hook exists and
proves nothing about whether it can fire.

#### Proving the hook's logic can fire, without a switch

A check nobody has seen fail is not a check, and `DRY_RUN` cannot make this
one fail. The body was therefore extracted **from the built activation
script**, byte-identically, and run standalone against a synthetic `HOME` —
so what was tested is the shipped text, not a retyped paraphrase of it:

```
$ NEW=/nix/store/mrfhzdidk627kg1v9x345lasl4lwsm6j-home-manager-generation
$ T=$(mktemp -d)
$ mkdir -p "$T/fakehome/.config" "$T/fakehome/.local/share/applications" \
           "$T/datadir/applications"
$ touch "$T/datadir/applications/present.desktop"
$ printf 'x-scheme-handler/ok=present.desktop\nx-scheme-handler/probe=definitely-not-installed.desktop\n' \
    > "$T/fakehome/.config/mimeapps.list"

  # lines 374-387 are the hook's sh -c body; 372 is its _iNote, 373 the
  # `run … sh -c '` line and 388 the closing `' || true`
$ sed -n '374,387p' "$NEW/activate" > "$T/hook.sh"
$ diff <(sed -n '374,387p' "$NEW/activate") "$T/hook.sh" && echo identical
identical

$ HOME="$T/fakehome" XDG_DATA_DIRS="$T/datadir" \
    /nix/store/3d6jlqvsnq8p2ix98j3qkb4i6wsk3ak1-bash-interactive-5.3p9/bin/sh \
    "$T/hook.sh"; echo "exit=$?"
mimeapps.list names a missing .desktop id: definitely-not-installed.desktop
1 unresolved id(s) in mimeapps.list -- handlers for them will do nothing
exit=0
```

Both halves in one run: it names the id that does not resolve, stays silent
about the one that does (`present.desktop`, which was created in
`$T/datadir/applications`), and exits `0` — the non-fatal requirement, at
the level of the script's own exit status.

**What this does not establish.** It does not establish that the hook fires
during a real `home-manager switch`, nor what it will say there. The
environment a switch hands the activation script is not this shell's, and
`CLAUDE.md` names that exact trap twice — `systemctl --user show-environment`
is not what a boot-path unit inherited, and `systemd-analyze --user
unit-paths` computes from the caller. Step 5 of the brief is the measurement
that would settle it, and it needs a switch. It is outstanding; see below.

#### A defect in the brief: Step 6 expects zero warnings, and the real file has two

The same shipped body, run read-only against the **real**
`~/.config/mimeapps.list` in this shell's environment:

```
$ echo "$XDG_DATA_DIRS"
/home/isutton/.nix-profile/share:/home/isutton/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share

  # same $T/hook.sh as above, but with the REAL $HOME, so it reads the
  # live ~/.config/mimeapps.list rather than the synthetic one
$ /nix/store/3d6jlqvsnq8p2ix98j3qkb4i6wsk3ak1-bash-interactive-5.3p9/bin/sh \
    "$T/hook.sh"; echo "exit=$?"
mimeapps.list names a missing .desktop id: eu.calangotech.KBrowserSelector.desktop
mimeapps.list names a missing .desktop id: slack.desktop
2 unresolved id(s) in mimeapps.list -- handlers for them will do nothing
exit=0

$ stat -c '%y %n' ~/.config/mimeapps.list
2026-08-14 17:23:10.467658973 -0300 /home/isutton/.config/mimeapps.list
```

The file was not modified — the `mtime` above predates this task by three
days. Both ids were then checked independently of the hook, by counting
matches across the same search path and by a direct `find`:

```
$ for id in eu.calangotech.KBrowserSelector.desktop slack.desktop; do
    n=0
    IFS=':'; for d in $XDG_DATA_DIRS "$HOME/.local/share"; do
      [ -e "$d/applications/$id" ] && n=$((n+1))
    done; unset IFS
    echo "$id -> $n"
  done
eu.calangotech.KBrowserSelector.desktop -> 0
slack.desktop -> 0

$ find /usr/share/applications /usr/local/share/applications \
    ~/.local/share/applications -maxdepth 1 \
    -name 'eu.calangotech.KBrowserSelector.desktop' | wc -l
0

$ IFS=':'; for d in $XDG_DATA_DIRS "$HOME/.local/share"; do unset IFS
    ls -1 "$d/applications" 2>/dev/null | grep -i slack | sed "s|^|$d/applications/|"
  IFS=':'; done; unset IFS
/var/lib/flatpak/exports/share/applications/com.slack.Slack.desktop
```

The last command is the one that identifies *why* `slack.desktop` does not
resolve: the only Slack entry anywhere on the search path is under a
different id, `com.slack.Slack.desktop`.

So the check is right and the brief's expectation is wrong. Two real,
pre-existing dead handlers:

- `eu.calangotech.KBrowserSelector.desktop` is the stale root-owned entry
  `home/apps.nix`'s `defaultBrowser` hook was written to displace. It is
  displaced in `[Default Applications]` — `http` and `https` there name
  `eu.calangotech.CalangoOpen.desktop` — but the two `[Added Associations]`
  lines still name it, and it exists nowhere on disk.
- `x-scheme-handler/slack=slack.desktop` names an id flatpak does not
  export. The installed entry is `com.slack.Slack.desktop`.

Neither is this flake's to fix, which is the case for non-fatal made
concretely rather than hypothetically: had this been a fatal check, it would
have blocked every switch on this machine from its first build.

**The count at the gate may not be 2, and 2 must not be read as the gate's
result.** This run used this shell's `XDG_DATA_DIRS`, not the activation
script's. A *smaller* search path can only find fewer entries and so report
more missing ids, and both of these are missing even against the widest path
available here, so the gate's count will be at least 2 — but it could be
higher, and only the switch can say. Step 6's stated expectation of `0` is
corrected to "at least 2, and the switch succeeds anyway".

### The third guard: every D-Bus activation file must be declared

Task 2 shipped a single hand-written `xdg.dataFile` entry for
`org.gnome.seahorse.Application.service`, after seahorse turned out not to
be launchable at all: its `.desktop` carries `DBusActivatable=true`, so a
launcher never runs `Exec=` and asks the session bus to activate the name
instead — and the bus's own `XDG_DATA_DIRS` has no `~/.nix-profile/share`,
so the copy inside the package was invisible to it. The comment on that
entry said plainly that nothing but a human noticing stood behind it, and
named Task 4 as the owner of the gap. `home/gui-apps.nix` now closes it with
`dbusActivatableGuiApps`, a build-time guard shaped like the `wrappedGuiApps`
schema guard beside it: every `guiPackages` member that ships a
`share/dbus-1/services/*.service` file must have a matching `xdg.dataFile`
entry.

It iterates `guiPackages` members individually — `${pkg}/share/dbus-1/services/`
per package — and deliberately does **not** read
`~/.nix-profile/share/dbus-1/services` or the generation's merged
`home-path`. That directory is a merged view, and measuring it says why:

```
$ ls -1 ~/.nix-profile/share/dbus-1/services/
org.freedesktop.impl.portal.desktop.gtk.service
org.freedesktop.impl.portal.desktop.hyprland.service
org.freedesktop.impl.portal.PermissionStore.service
org.freedesktop.portal.Desktop.service
org.freedesktop.portal.Documents.service
org.gnome.seahorse.Application.service
```

Five of those six are `home/portals.nix`'s, not this module's. A guard
reading the merge would demand `xdg.dataFile` entries on behalf of packages
`home/gui-apps.nix` does not own, and would report a portals regression as a
gui-apps failure. (Task 2's comment said "home/portals.nix's three
`xdg.dataFile` entries"; the file has five, and the count is corrected in
place.)

The *declared* side is read off `config.xdg.dataFile`'s own attribute names
rather than kept in a parallel list, filtering on the `dbus-1/services/`
prefix and stripping it before comparison. That is the whole
configuration's declared set, portals' five included, and that is
deliberate: the property that matters is that the file lands in
`XDG_DATA_HOME`, the only place the bus looks, and any module putting it
there satisfies it. A wider declared set can only make the guard more
permissive, never produce a false failure. Reading `config` to build
something that feeds `home.packages` is not a cycle here — every
`xdg.dataFile` definition in this flake is a literal and none reads
`home.packages` — but this plan has already shipped one `infinite
recursion` from a self-referencing binding, so the shape was built rather
than reasoned about, and it evaluates.

**What it found.** Non-vacuous today, from its own build log:

```
$ sg nix-users -c 'nix log /nix/store/lr3iy85l09hwvskqwilzgzl8bbkwnzyv-gui-apps-dbus-activation.drv'
ok (declared): 7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1 -> org.gnome.seahorse.Application.service
ok (no activation files): bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
```

One real comparison and one derived exemption: `pkgs.seahorse` ships exactly
one `.service` file and it is declared; `pkgs.gammastep` ships no
`share/dbus-1/services` directory at all (`ls` on it exits 2). So today's
single hand-written entry is complete — confirmed by a guard rather than
asserted by a comment, which is what the Task 2 comment asked for.

**What forces those packages to be built by then is the guard's own
`inputDrvs`, not `home.packages`.** An earlier version of the comment on the
`xdg.dataFile` entry credited `home.packages`; interpolating each store path
into the guard's build script is what actually does it, making every package a
build-time dependency of the guard itself. Verified on the derivation:

```
$ sg nix-users -c 'nix derivation show /nix/store/lr3iy85l09hwvskqwilzgzl8bbkwnzyv-gui-apps-dbus-activation.drv' \
    | grep -oE '/nix/store/[a-z0-9]+-(seahorse|gammastep)[^"]*\.drv'
/nix/store/1v75abldp56l3qn1hwshyywna157r2qy-gammastep-2.0.11.drv
/nix/store/1vm3i0g402kzmynjlwwnz7knj956j5yv-seahorse-47.0.1.drv
```

Both are among its `inputDrvs`, so the guard would remain correct if these
packages left `home.packages` entirely. The distinction matters because it is
the reason no import-from-derivation is needed: IFD would only bite when
auto-*generating* the `xdg.dataFile` entries, whose attribute names Home
Manager's option model wants at Nix eval time.

Like `wrappedGuiApps`, it rides in `home.packages` rather than being a flake
check, so the flake-check count stays at three. And like it, its output is
`mkdir -p "$out"` and not `touch "$out"`: `pkgs.buildEnv` refuses to merge a
store path that is a file, which is the error Phase 1 hit on the first build
of this plan. The two `gui-desktop-ids` and `dbusActivatableGuiApps` outputs
are opposite on purpose — the flake check is not in `home.packages` and its
`touch "$out"` is correct.

**Proven able to fail, twice.** First the property itself, by renaming the
`xdg.dataFile` attribute so seahorse's real file has no match — mutation
confirmed by count first, per the same discipline as Layer 1:

```
$ sed -i 's|...org.gnome.seahorse.Application.service".source =|...org.gnome.seahorse.WRONG.service".source =|' home/gui-apps.nix
$ grep -c 'org.gnome.seahorse.WRONG.service' home/gui-apps.nix
1

$ sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
error: builder for '/nix/store/cdj9ymjfrc49536v7c2s7dzy0kqi0m88-gui-apps-dbus-activation.drv' failed with exit code 1;
       last 13 log lines:
       > 7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1 ships org.gnome.seahorse.Application.service but no xdg.dataFile declares it.
       >   A .desktop with DBusActivatable=true is never launched
       >   through Exec= or PATH -- the launcher asks the session bus
       ...
       >     xdg.dataFile."dbus-1/services/org.gnome.seahorse.Application.service".source =
       >       "${pkg}/share/dbus-1/services/org.gnome.seahorse.Application.service";
       > ok (no activation files): bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
error: 1 dependencies of derivation '.../gui-apps-dbus-guard.drv' failed to build
error: 1 dependencies of derivation '.../home-manager-path.drv' failed to build
```

Then its own anti-vacuity anchor. The guard's exemption path — "this package
ships no activation files" — is exactly where a layout change would hide: if
`share/dbus-1/services` ever moved, every package would take that path and
the guard would pass having compared nothing. So it counts what it examined
and refuses a zero, the same way `no-pulseaudio-daemon` asserts `pactl` is
present before concluding `pulseaudio` is absent. Drifting the path proves
that block fires:

```
$ sed -i 's|dir="$pkg/share/dbus-1/services"|dir="$pkg/share/dbus-1/NOPE"|' home/gui-apps.nix
$ grep -c 'dbus-1/NOPE' home/gui-apps.nix
1

$ sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | grep -E 'vacuous|No guiPackages|exempt path|failed with exit'
error: builder for '/nix/store/xkd0k9nd3816203f1y0hwcvajczy1mq1-gui-apps-dbus-activation.drv' failed with exit code 1;
       > No guiPackages member ships a share/dbus-1/services/*.service.
       >   Every entry took the 'no activation files' exempt path, so
       >   would be vacuous. Today seahorse ships exactly one such file,
```

Both mutations restored, each confirmed by a count in both directions, and
the generation reproduced byte-for-byte at the same store path it had before
either mutation:

```
$ grep -c 'org.gnome.seahorse.WRONG' home/gui-apps.nix
0
$ grep -c '^  xdg.dataFile."dbus-1/services/org.gnome.seahorse.Application.service".source =' home/gui-apps.nix
1
$ grep -c 'dbus-1/NOPE' home/gui-apps.nix
0
$ grep -c '^      dir="$pkg/share/dbus-1/services"$' home/gui-apps.nix
1

$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
/nix/store/491v1scgzdqc3qz6g667p1adn0049apq-home-manager-generation
```

That path is the generation **as of this section's measurements**. Fix round 1
then moved it to
`/nix/store/mrfhzdidk627kg1v9x345lasl4lwsm6j-home-manager-generation`, and the
guard's own derivation moved with it —
`lr3iy85l…-gui-apps-dbus-activation.drv` became
`245rxpvz…-gui-apps-dbus-activation.drv`. That was checked rather than
assumed, and the first assumption was wrong: a claim that the derivation was
byte-identical was written here and then disproved by diffing the two. The
whole difference is one shell comment line inside the build script, corrected
from `gui-apps-guard` to `gui-apps-dbus-guard`:

```
$ (diff of the two derivations' env.buildCommand)
-# output is reached from home.packages through gui-apps-guard's symlink,
-# and pkgs.buildEnv refuses to merge a store path that is a file.
+# output is reached from home.packages through gui-apps-dbus-guard's
+# symlink, and pkgs.buildEnv refuses to merge a store path that is a file.
```

`inputDrvs`, `inputSrcs`, `args`, `builder` and `system` are all identical;
only `buildCommand` and the resulting `out` path differ. A shell comment
inside a Nix `''…''` string is part of the derivation, unlike a Nix `#`
comment outside one — which is why the other comment corrections in this file
did not move the hash and this one did. The guard's *logic* is unchanged, so
the two mutation proofs above still describe the shipped check, and the new
derivation produces the same verdict:

```
$ sg nix-users -c 'nix log /nix/store/245rxpvzgcg348dmwxhaahwgj51mg29v-gui-apps-dbus-activation.drv' | tail -2
ok (declared): 7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1 -> org.gnome.seahorse.Application.service
ok (no activation files): bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
```

### Outstanding: the two gate items that need a switch

Task 4 stops at the switch boundary. Neither of the following was run, and
nothing above should be read as having answered them:

- **Step 5 — the activation hook firing during a real switch.** Proving the
  hook's *logic* warns (above) is not proving the *hook* warns. It needs a
  bogus id appended to `~/.config/mimeapps.list`, a real
  `home-manager switch`, the warning observed in the switch's own output,
  the switch succeeding anyway, and the file restored byte-identically
  afterwards. `~/.config/mimeapps.list` was **not** mutated by this task.
- **Step 6 — the gate.** The warning count on the real, unmutated file
  during a switch, and `nix flake check` green afterwards. The flake check
  half is green here (three checks, exit 0). The warning-count half is not
  measured, and its expected value is **at least 2**, not the `0` the brief
  states — see the defect above.

The user-gate command block for both lives with Task 4's report.

## Endpoint

Measured 2026-08-17, after Tasks 1-4, with nothing switched or removed by
this task.

### Eight fewer apt packages, in three different dpkg states

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    seahorse gammastep thunar thunar-volman pcmanfm-qt emacs-lucid deskflow kitty
dpkg-query: no packages found matching seahorse
dpkg-query: no packages found matching gammastep
dpkg-query: no packages found matching deskflow
dpkg-query: no packages found matching kitty
un  emacs-lucid 
rc  pcmanfm-qt 2.1.0-2
rc  thunar 4.20.2-1+deb13u1
rc  thunar-volman 4.20.0-1
```

Eight packages, not one of them `ii`, so the spec's prediction of eight
holds. Reporting that as "eight removed" would flatten a distinction this
repository has paid for, because those eight sit in **three** different
dpkg states:

- **No record at all** — `seahorse`, `gammastep`, `deskflow`, `kitty`.
  `dpkg-query -W` finds no matching package to report on.
- **`rc`** — `thunar`, `thunar-volman`, `pcmanfm-qt`. Want `r`emove, state
  `c`onfig-files: removed with conffiles retained, which is exactly what
  `apt remove` leaves behind and exactly why a bare
  `dpkg-query -W -f='${Version}'` is forbidden here — it prints a version
  and exits `0` for all three of these. Counted at the same time as the rest
  of this section rather than carried from `CLAUDE.md`, which said 120:

  ```
  $ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="rc"' | wc -l
  128
  ```

  These three are themselves part of the difference between the two figures,
  which is the whole argument for counting it here: a number that moves every
  time a spec removes a package cannot be quoted from a file written during an
  earlier spec, least of all under a heading that says "Measured".
- **`un`** — `emacs-lucid`, alone. Want unknown, state not-installed:
  dpkg holds a record for the name with no selection recorded against it
  and nothing installed, not even conffiles. Note its version column is
  empty where the three `rc` rows still carry one.

**Why `emacs-lucid` reads `un` where its three siblings read `rc` is not
established here, and neither is why four of the eight have no record at
all.** What is measured is that a single command produced all three
outcomes:

```
$ grep -B1 -A3 'apt remove thunar' /var/log/apt/history.log
Start-Date: 2026-08-17  07:47:34
Commandline: apt remove thunar pcmanfm-qt emacs-lucid deskflow kitty
Requested-By: isutton (1000)
Remove: deskflow:amd64 (1.26.0.0), emacs-lucid:amd64 (1:30.1+1-6), kitty:amd64 (0.41.1-2+deb13u1), thunar-volman:amd64 (4.20.0-1), pcmanfm-qt:amd64 (2.1.0-2), thunar:amd64 (4.20.2-1+deb13u1)
End-Date: 2026-08-17  07:47:38
```

One `apt remove`, no `purge` anywhere in that history entry, six packages,
three resulting states. So the state is a property of each package rather
than of how it was removed — but which property, this task did not
measure. Do not read the three-way split as evidence of three different
removals.

### GUI candidates still on apt, counted from the filesystem

```
$ for p in $(apt-mark showmanual); do
    case "$p" in 1password|1password-cli|code|google-chrome-stable|endpoint-verification) continue;; esac
    dpkg -L "$p" 2>/dev/null | grep -q '/usr/share/applications/.*\.desktop' && echo "$p"
  done | sort
bitwarden
displaycal
firefox-esr
flatseal
fresh-editor
hx
isoimagewriter
signal-desktop
syncthingtray
vim-common
virt-manager
```

Eleven, against the spec's inventory of eighteen. The difference is
exactly the seven this plan touched — `seahorse` and `gammastep` migrated,
`kitty`, `thunar`, `pcmanfm-qt`, `emacs-lucid` and `deskflow` removed.
`thunar-volman` never appeared in the inventory: it ships no
`.desktop` file and rode along with Thunar, which is why the endpoint is
eight packages against eleven inventory rows retired.

Of the eleven, two stay on apt permanently (`flatseal`, absent from
nixpkgs; `fresh-editor`, a downgrade there) and two need none of this
spec's mechanisms (`vim-common`, `hx` — terminal programs with no draw
path). The seven the spec calls follow-on work are the remainder.

### The flake checks: three, green

```
$ sg nix-users -c 'nix flake check' >/tmp/t5-fc.out 2>&1; echo "exit=$?"
exit=0
$ grep -n 'checking derivation' /tmp/t5-fc.out
4:checking derivation checks.x86_64-linux.no-dangling-home-files...
7:checking derivation checks.x86_64-linux.no-pulseaudio-daemon...
9:checking derivation checks.x86_64-linux.gui-desktop-ids...
$ tail -1 /tmp/t5-fc.out
running 3 flake checks...
```

Output is redirected and the exit status read from the redirected command,
not from a pipeline — `… | tail -1; echo $?` reports `tail`'s status with
`pipefail` off, and cannot show a failing build at all. `CLAUDE.md`'s
count of the flake checks is updated from two to three by this task, along
with the list of edits that should trigger a re-run.

The guards that ride in `home.packages` rather than in `checks` are not in
that three. They run whenever the generation is built, which is strictly
more often than `nix flake check` is invoked. Two of them are this task's,
`wrappedGuiApps` and `dbusActivatableGuiApps`; enumerated by syntax rather
than from this sentence, there is a third, and "the two guards" was the
wording here until the whole-branch fix round:

```
$ grep -c 'home.packages = ' home/*.nix | grep -v ':0$' | wc -l
10
$ grep -n 'home.packages = ' home/*.nix
home/lf.nix:82:  config.home.packages = [ lfWrapped ];
home/services.nix:67:  config.home.packages = [ nmSecretAgent ];
home/apps.nix:107:  config.home.packages = [ calangoOpen codeShim ];
home/default.nix:35:  home.packages = with pkgs; [
home/audio.nix:385:  home.packages = [ pkgs.pipewire pkgs.wireplumber pulseaudioClients ];
home/gtk.nix:130:  config.home.packages = [ applyGtkTheme ];
home/session.nix:145:  home.packages = [ hyprland-nixgl hyprland-nixgl-session ];
home/quickshell.nix:103:  config.home.packages = [ pkgs.quickshell ];
home/gui-apps.nix:264:  home.packages = guiPackages ++ [
home/hyprland.nix:171:  config.home.packages = [ hyprlock-nixgl ];
```

`home/audio.nix:385` carries `pulseaudioClients`, whose derivation body
holds three `exit 1` guards of its own — a package-producing derivation is
a guard too. `CLAUDE.md` records both that and the command that counts
those three.

### Residue: no dangling `/etc/systemd/user` symlinks

Six apt packages were removed on this branch, so the census `CLAUDE.md`
tracks was re-taken:

```
$ n=0; for f in /etc/systemd/user/*.wants/* /etc/systemd/user/*.upholds/*; do
    [ -e "$f" ] || { echo "$f"; n=$((n+1)); }; done; echo "dangling=$n"
/etc/systemd/user/*.upholds/*
dangling=1
```

**That one line is the loop's own artifact, not a dangling link.** The
`*.upholds/*` glob matched nothing, so the shell left the pattern
uninterpolated and `[ -e ]` failed on a literal `*`. The directory it
would have searched does exist and is empty:

```
$ ls -1d /etc/systemd/user/*.upholds
/etc/systemd/user/sockets.target.upholds
$ ls -1 /etc/systemd/user/*.upholds/ | wc -l
0
```

The `*.wants/*` half **did** expand — twelve entries, every one of them
present — so the real count of dangling symlinks is **zero**, unchanged
from the audio spec's sweep. `CLAUDE.md` already records this blind spot
for `pipewire.service.wants/`; `sockets.target.upholds/` is a second
instance of it, and here it made the loop print a line that reads exactly
like a finding.

The count of dangling links is zero, and the sweep above is the direct
measurement of that. What the sweep does not by itself explain is *why* it
did not rise, and the answer covers **eight** packages rather than the six of
that single `apt remove` — `seahorse` and `gammastep` went in their own
removals, and an earlier draft of this sentence said "six" while making a
claim that ranges over all eight.

The supporting evidence is uneven across the eight, and saying so is the
point. `gammastep` still has a cached `.deb`, which answers directly:

```
$ dpkg -c /var/cache/apt/archives/gammastep_2.0.9-1+b1_amd64.deb | grep -c systemd
0
```

`seahorse` has **neither** a cached `.deb` nor an installed file list, so no
equivalent check is available for it — do not read the line above as covering
both. What covers all eight is the absence of any `deb-systemd-helper` state:

```
$ ls /var/lib/systemd/deb-systemd-helper-enabled/ \
    | grep -icE 'gammastep|seahorse|thunar|pcmanfm|kitty|deskflow|emacs'
0
```

That is the load-bearing half rather than a second opinion. `CLAUDE.md`
records that `deb-systemd-helper`'s `was-enabled` defaults to true and that a
leftover statefile is what silently re-enables a link on the next upgrade — so
an empty statefile directory is what makes the zero durable instead of
merely current.

### What this endpoint does not include

Three things are outstanding, and none of them may be read as passing:

- **Night light is degraded.** Every gamma client on this machine is
  refused by Hyprland; see the open defect below. The user has deferred
  the re-login test and directed the work to proceed on the assumption
  that gammastep functions. That is an assumption pending a check.
- **The by-hand launcher and tray confirmation for `gammastep` has not
  been run** — launching `gammastep-indicator` from the launcher, and
  toggling night light from the shell panel to see the screen warm.
- **Task 4's Steps 5 and 6 have not been run**; both need a real
  `home-manager switch`. The flake-check half of Step 6 is green above;
  the activation-warning half is not measured, and its expected value is
  at least 2, not the `0` the brief stated.

## Defects found

Recorded without softening, including the controller's own errors and the
findings that came from reviewers rather than from production. The two
defects in the *plan* that Task 1 found are in "Defects found in the plan"
above and are not repeated here; this section is the spec's, the briefs',
and the controller's.

### In the spec

**1. Mechanism 2 was wrong: nothing needed building.** The spec's
"GSettings schemas, which nixpkgs relocates out of `XDG_DATA_DIRS`"
correctly measured the relocation — schemas really do live at
`share/gsettings-schemas/<name>/glib-2.0/schemas`, a path GLib never
searches — and then concluded that this repository had no mechanism to
handle it and needed one, offering two candidate shapes to choose between.
That conclusion was never checked. `wrapGAppsHook` already produces a
`bin/<name>` wrapper per package that prefixes `XDG_DATA_DIRS` with every
schema directory the application needs; the four directories on the live
seahorse process's own `XDG_DATA_DIRS`, quoted in Phase 1's gate, are that
wrapper's work. So the whole "wrapper versus merged directory, and what
happens to `gschemas.compiled` on collision" question the spec posed does
not arise. What shipped in its place is a *guard* that each `guiPackages`
member is wrapped, which is a different artefact from the one the spec
specified — and a smaller one.

The relocation half of mechanism 2 is the part worth keeping: a package
that misses the hook aborts with `Settings schema … is not installed`,
which reads as a broken package rather than a missing environment.

**2. The spec never named the two-independent-search-orders risk.** It
records a "second, milder half" of mechanism 3 — that during a migration
both trees are on `XDG_DATA_DIRS` and launchers show duplicate entries
until Debian's package goes — and treats duplicate entries as cosmetic.
The real hazard is that the winning `.desktop` entry and the winning
binary are chosen by **two different search paths**: `XDG_DATA_DIRS`
decides which entry a launcher reads, and a bare-name `Exec=` is then
resolved through `PATH`. With both packages installed those can disagree,
so a Nix `.desktop` can run a Debian binary or the reverse. Task 1
measured the `PATH` side (`~/.nix-profile/bin` at 30, `/usr/bin` at 34)
and `seahorse`'s `Exec=seahorse %u` is exactly the bare-name shape. Same
species as spec 6's `fumon` and the foot server. Removing the apt package
is therefore part of making the outcome deterministic, not tidying up
afterwards — which is a different reason for the removal than the one the
spec gives.

**3. The Phase 3 check could not have existed as written.** The spec's
build-time half asks `flake.nix` to assert, "for a list of `mimeapps.list`
ID → package pairs", that the package ships that `.desktop` file — and its
activation-time half to read the real file. A flake check builds in the
Nix sandbox, where `~/.config/mimeapps.list` and `/usr/share/applications`
are both invisible, so the build-time half can never see the list it is
supposed to be checking against. To the spec's credit it says the obvious
form is not implementable and splits the property in two; what it did not
notice is that its own build-time half still names `mimeapps.list` as the
source of the pairs. The shipped `gui-desktop-ids` asserts a
hand-maintained `required` list instead, each entry carrying the reason it
is required, and the correspondence to `mimeapps.list` is a human's to
keep. That is weaker than the spec implies, and the activation hook is
what covers the gap.

### In the task briefs

**4. Task 4's Step 6 expected zero unresolved ids; the real file has at
least two.** `eu.calangotech.KBrowserSelector.desktop` and `slack.desktop`
both fail to resolve, measured in Phase 3 above. Both are pre-existing and
neither is this flake's to fix. Had `mimeappsIds` been fatal, it would have
aborted every switch on this machine from its first build — the case for
non-fatal, made by measurement rather than by argument.

**5. Task 4's brief named a function where it meant a property.** It
specified `entryBetween`; the implementer used
`entryAfter [ "linkGeneration" "installPackages" "defaultBrowser" ]` and
argued that nothing in the DAG consumes this hook's output, so its
`before` list would be empty and `entryBetween [] xs` is by definition
`entryAfter xs`. Declaring an empty edge would state a constraint that does
not exist. The substance the brief wanted — ordering stated rather than
inherited from an attribute-name tie-break — was delivered; the deviation
was accepted.

**6. Task 5's own brief omitted `kitty` from the endpoint command while its
prediction named it among the eight.** Run as written, the command would
have reported seven rows and invited the conclusion that the spec's
prediction of eight had missed by one. `kitty` was added before running
it; the eight-row transcript is at the top of this section.

### In execution

**7. The plan's Nix was written down without ever being built, twice
over.** `wrappedGuiApps` ended with `touch "$out"`, and `pkgs.buildEnv`
refuses to merge a store path that is a file, so the generation could never
have built; and a comment inside that derivation's own `''…''` string
naming `${wrappedGuiApps}` produced `infinite recursion encountered`.
Both are recorded in Phase 1. Same class as spec 9's `/dev/null` mask: the
runtime layer probed by hand, the build layer assumed.

**8. Seahorse could not be launched at all, and `CLAUDE.md` had recorded
the trap since spec 7.** `DBusActivatable=true` takes the launch off both
`XDG_DATA_DIRS` and `PATH` onto a third path — D-Bus activation — and the
session bus's own `XDG_DATA_DIRS` has no `~/.nix-profile/share`. The plan
was reasoning about the two search orders it discusses and never noticed
that neither is consulted. Full account in Phase 1. Task 4's
`dbusActivatableGuiApps` closes the class.

**9. A check whose declared scope exceeded what it read.**
`gui-desktop-ids` claimed to cover the ids that `mimeapps.list` names *and*
this flake provides, but read only `home-path/share/applications`. The one
id satisfying both halves today,
`eu.calangotech.CalangoOpen.desktop`, is an `xdg.dataFile` entry and lands
in `home-files/.local/share/applications` — so the check's stated purpose
was unreachable by its own mechanism. It passed because every id it
actually listed was one no handler references. This is the same species as
spec 6's three checks that passed while the property they stood for was
false, and it was caught by a **reviewer**, not by production. The fix
widened the check to both trees and added `CalangoOpen` to `required`,
with each branch proven by mutating it.

**10. A shell comment inside a Nix string is part of the derivation; a Nix
comment outside one is not.** Both claims were made on this branch. The
first — that a comment in a Nix expression, inside a `lib.makeBinPath`
list, does not change the derivation — is true. The second, that the D-Bus
guard's derivation was byte-identical across two generations, was asserted
on the same reasoning and is false: the comment in question sat inside a
`''…''` string, so it is part of `buildCommand`, and the implementer
disproved its own claim by diffing the two derivations. `inputDrvs`,
`inputSrcs`, `args`, `builder` and `system` were identical; `buildCommand`
and the `out` path differed by one comment line. The distinction is which
side of the string boundary the comment is on, and it is now in
`CLAUDE.md`.

**11. The recurring defect recurred, inside a controller ruling.** Ruling
11 held that the mid-session restart of the night-light client at 08:57 was
the first such restart the machine had ever logged — generalised from a
40-line journal window containing only the four immediately preceding
boots. Over the full journal that is false: warning-free mid-session
toggles ran on 08-13 16:06, 08-14 17:29, 08-15 10:30 and 08-15 23:17. The
ruling was withdrawn and replaced, but not before it reached a committed
document. `CLAUDE.md`'s closing section already names this pattern — a real
command run, real output read, and a conclusion drawn afterwards the
measurement did not license. A ruling is the worst place for it, because
the rest of the task is built on the ruling rather than on the sentence.

**12. The union-instrument rule was violated again, on a branch whose
`CLAUDE.md` already forbids it.** The first gate evidence's decisive step
was a bare comment — `# /proc walk: no gammastep process anywhere` — with
no command, no output, and an exe-only walk behind it, which `CLAUDE.md`
calls insufficient because it covers roughly a quarter of this machine's
processes. A reviewer reproduced the hazard and found a `gammastep` by
`ps -eo args` that the exe walk had missed. Re-measured with the union of
`ps -eo args` over full command lines and a `/proc` cmdline walk, the
finding held — but the original was not evidence.

**13. Two other documented traps were walked into.** `pgrep -x seahorse`
found nothing because Nix wraps the binary and `comm` truncates to
`.seahorse-wrapp`; and the `mimeappsIds` hook's three real ordering
dependencies were satisfied only by an alphabetical tie-break, the same
defect `home/audio.nix`'s `pipewireSessionManagerAlias` already paid for.
Both are documented in `CLAUDE.md` by name. The second was latent — the
live order was correct — which is exactly when it is cheap to fix.

**14. Two implementers were dispatched against `home/gui-apps.nix`
concurrently, which the process forbids.** Task 3's agent committed at
08:31 and the Task 2 fix agent began editing after it; the worktree
happened to be clean between them. Had the order differed, one would have
clobbered the other. The only mitigation actually in place was a warning
in the dispatch telling the second agent to re-read the file and stop
rather than revert. The outcome was luck, not design.

**15. A count was stated wrongly three times, and the third time was in
this list.** `home/portals.nix` was described as declaring three
`xdg.dataFile` activation entries, then four; it declares five. The
sentence that recorded that error then said "the merged profile holds five
service files", dropping the word `portal` — and dropping that word is what
made it wrong, because five is the portal-owned count and **six** is the
total. Both quantities, counted separately and at last correctly:

```
$ for f in home/*.nix; do n=$(grep -cE '"dbus-1/services/[^"]+"' "$f"); \
    [ "$n" -gt 0 ] && echo "$f $n"; done
home/gui-apps.nix 3      # one entry; the other two are the guard's error text
home/portals.nix 5       # five entries

$ ls -1 ~/.local/share/dbus-1/services/ | wc -l
6
$ ls -1 ~/.nix-profile/share/dbus-1/services/ | wc -l
6
```

Six files in each directory, the same six names: five from
`home/portals.nix` and `org.gnome.seahorse.Application.service` from
`home/gui-apps.nix`. A defect entry about a miscount restating the miscount
is the sharpest available illustration of why a number belongs next to the
command that produced it.

**16. A derived exemption that the same file already disproved.** Found by the
whole-branch review, fixed in the round after it. `wrappedGuiApps` exempted any
`guiPackages` member shipping no `share/gsettings-schemas` directory of its
own — `[ ! -d "$pkg/share/gsettings-schemas" ]`, on the reasoning that there
was then "nothing to find and nothing to wrap". `home/gui-apps.nix`'s own
`gammastep` comment contained the disproof, in the same `let` block, above the
guard it exempted:

```
$ G=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
$ find $G -path '*gsettings-schemas*' | wc -l
0
$ for b in gammastep gammastep-indicator; do \
    grep -oE "/nix/store/[^']*/share/gsettings-schemas/[^']*" $G/bin/$b \
      | sort -u | wc -l; done
2
2
```

Zero schema directories of its own, two on each wrapper's `XDG_DATA_DIRS`
prefix — gtk+3's and gsettings-desktop-schemas', both from dependencies. So the
schemas that matter to a package need not be the package's own, and a GTK
application that missed `wrapGAppsHook` would have taken the exempt path,
printed `ok (no schemas)`, and aborted at startup with `Settings schema … is
not installed`: the exact failure the guard exists to turn into a build error.
The measurement was right and the conclusion drawn from it was not licensed by
it, which is the closing pattern in `CLAUDE.md` and the same species as defect
9 above.

Fixed by deleting the exemption. Every `guiPackages` member must now have a
wrapped binary, and both do:

```
gui-apps-schema-wrapped> ok (1 wrapped): 7kw783zcy9kdanj1fgx3fc4gwj1jyxbn-seahorse-47.0.1
gui-apps-schema-wrapped> ok (2 wrapped): bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
```

**Proven strictly stronger, not merely different**, by putting one unwrapped,
schema-free package into `guiPackages` and building both versions of the guard
against it. `pkgs.hello` — 1 binary, 0 wrapped siblings, 0 schema directories.
With the exemption gone:

```
$ grep -c 'guiPackages = \[ pkgs.seahorse pkgs.gammastep pkgs.hello \];' home/gui-apps.nix
1
gui-apps-schema-wrapped> ok (1 wrapped): …-seahorse-47.0.1
gui-apps-schema-wrapped> ok (2 wrapped): …-gammastep-2.0.11
gui-apps-schema-wrapped> i270m2h1mhfm9fh4iqif6qvaq488lhlv-hello-2.12.3 has no wrapped binary in bin/.
error: builder for '/nix/store/s9ygpvyvi17chamhphsdr2xj568ni0wa-gui-apps-schema-wrapped.drv' failed with exit code 1
```

With the exemption branch pasted back and the same `guiPackages`, the identical
tree builds green and says so about the package that would have crashed:

```
$ grep -c 'ok (no schemas)' home/gui-apps.nix
1
gui-apps-schema-wrapped> ok (1 wrapped): …-seahorse-47.0.1
gui-apps-schema-wrapped> ok (no schemas): …-gammastep-2.0.11
gui-apps-schema-wrapped> ok (no schemas): …-hello-2.12.3
```

Both mutations were then reverted and the file compared against a copy taken
before either was applied (`sha256sum` equal,
`eeaa215b29a0d4e38f64cb6389032bdc49edbbf848373f0085e90b384753cbc6`). Note the
counts were taken *before* each build: a `sed` or a patch that matches nothing
exits 0, so "the mutation is in the file" is its own measurement.

**17. Deferred and now recorded: the wrapped-binary test counts wrappers but
never compares them to the number of binaries.** `home/gui-apps.nix`'s
`wrapped="$(find "$pkg/bin" -maxdepth 1 -name '.*-wrapped' … | wc -l)"` is
tested `-eq 0`, so a package with N binaries passes on 1 wrapper. Task 2
deferred this, the ledger carried it, and the code is unchanged — defensible
today, because both members are fully wrapped (`seahorse` 1/1, `gammastep`
2/2), and no longer defensible silently.

The exposure, measured on the two named follow-on candidates rather than
assumed:

```
$ VM=/nix/store/fka6dyxn9kfxafarm0m845b3hppyxqhz-virt-manager-5.1.0
$ ls -1 $VM/bin | wc -l; find $VM/bin -maxdepth 1 -name '.*-wrapped' | wc -l
4
4
$ BW=/nix/store/l3dy6i7lxh2vs5k3q3cylbkm57gchg52-bitwarden-desktop-2026.7.0
$ ls -1 $BW/bin | wc -l; find $BW/bin -maxdepth 1 -name '.*-wrapped' | wc -l
1
0
```

`virt-manager` is the multi-binary case: four binaries (`virt-clone`,
`virt-install`, `virt-manager`, `virt-xml`), four wrappers today, so an
upstream change that wrapped only the GUI entry point would pass this test
while `virt-install` lost its schemas. **Any migration that adds
`virt-manager` — or any other multi-binary package — to `guiPackages` must
strengthen this test to compare the wrapper count against the binary count
first.**

`bitwarden` is a different exposure than the one the ledger predicted, and the
correction is worth keeping: it is not multi-binary. In this flake's pinned
nixpkgs the attribute is also gone — `pkgs.bitwarden` throws `'bitwarden' has
been renamed to/replaced by 'bitwarden-desktop'` — and `bitwarden-desktop`
ships one binary with **zero** wrappers. Under the guard as it now stands,
adding it fails the build. That is the intended behaviour, not a regression —
its one binary is a script that execs Electron, not a GTK program:

```
$ grep -o 'electron[^"]*' $BW/bin/bitwarden | head -1
electron-41.9.1/bin/electron
```

So it is the first legitimate named exemption
the stronger guard will need, and defect 16 is the reason it will be written
down in `home/gui-apps.nix` instead of granted silently by a `[ ! -d … ]` test.

**18. Three committed statements that their own cited measurement
contradicted.** All three were found by the whole-branch review and all three
are text, not behaviour:

- `home/apps.nix`'s ordering comment said every hook after `linkGeneration`
  "sat in exactly alphabetical order" and then listed eight of the ten. The
  built script has `desktopDatabase` (302) before `defaultBrowser` (308),
  forced by `defaultBrowser`'s own `entryAfter [ "desktopDatabase" ]`, and it
  has ten hooks — `pipewireSessionManagerAlias` (394) and `reloadSystemd`
  (407) were the two omitted. The comment now quotes
  `grep -n 'Activating %s' "$A"/activate | sed -n '4,14p'` and its eleven
  lines. The prose at the top of Phase 3's ordering section carried the same
  "exactly alphabetical" word over its own contradicting listing and is
  corrected in place.
- The same file's `mimeapps.list` comment said "6 unique ids … the rest are"
  and then named four, omitting `eu.calangotech.KBrowserSelector.desktop` —
  one of the two ids the hook actually warns about and this module's own
  displaced entry. It also glossed `slack.desktop` as "flatpak Slack", which
  is the opposite of Phase 3's own finding above: flatpak exports
  `com.slack.Slack.desktop`, a different id, and that difference is *why* the
  association is dead. The comment now prints all six ids from
  `sed -n 's/^[^=]*=//p' … | sort -u` and states the distinction. The
  `defaultBrowser` comment below it was carrying "six associations (slack,
  bitwarden, claude-cli, signal x2)" — a count matched by no name list and by
  nothing on disk; it now says 7 of the 12 assignment lines, all but the 5
  naming `CalangoOpen` (`grep -c 'CalangoOpen' ~/.config/mimeapps.list` → 5,
  `grep -c '^[^=]*=' ~/.config/mimeapps.list` → 12). The word "root-owned"
  was dropped from the `KBrowserSelector` description in that comment:
  `~/.config/mimeapps.list` is `isutton:nix-users` and the `.desktop` it names
  exists nowhere on the search path, so nothing measurable supports it.
- `CLAUDE.md`'s own passage from the previous fix round said
  `pulseaudioClients` "carries three `exit 1` guards" with no command that
  yields 3 — the obvious `grep -c 'exit 1' home/audio.nix` yields **9**. It now
  carries both commands and both numbers, scoped to the derivation body.

**19. `gui-desktop-ids` had no anti-vacuity anchor.** The other three guards
each assert they are looking somewhere before drawing a conclusion; this one
would pass with an empty `required` list, because the loop then runs zero
times and `$fail` stays 0. Anchored on a non-blank-line count of `required`
rather than on a fixed number, so adding an id needs no second edit. Proven by
mutation, count first:

```
$ grep -c '^            required=""$' flake.nix
1
$ grep -c 'org.gnome.seahorse.Application.desktop seahorse-launcher' flake.nix
0
gui-desktop-ids> the required .desktop id list is empty.
gui-desktop-ids>   Nothing would be looked up in either tree, the loop
gui-desktop-ids>   below would run zero times, and this check would pass
gui-desktop-ids>   no matter what the flake ships -- a check that cannot
gui-desktop-ids>   fail is worse than no check, because it reads as one.
error: builder for '/nix/store/l9rgi4klg7z32f8yhwj641gzrfdjxbmi-gui-desktop-ids.drv' failed with exit code 1
```

Reverted afterwards, `sha256sum flake.nix` equal to the pre-mutation copy.

### Open: every gamma client on this machine is refused

**This is not resolved and must not be presented as resolved.**

After the migration, `night-light.service`'s client and any hand-run
gammastep both print `Warning: Zero outputs support gamma adjustment.` /
`Warning: 1/1 output(s) do not support gamma adjustment.` The full
measurement is in Phase 2; what the close-out needs to carry is the
shape of what is and is not known:

- **The trigger is unidentified.** It is not the package: the store path
  `bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11` is byte-identical
  across generations 33, 34 and 35, and Task 3 added a comment and a
  `home.packages` entry, neither of which the unit reads. It is not the
  toggle path: the same store path in the same unit ran the same
  stop → `off`-execing-nothing → new-client-a-second-later → restart
  sequence warning-free at **2026-08-15 10:30:39** under generation 18,
  which names that same path in its `Environment=PATH`.
- **A competing live client is ruled out**, by the union instrument
  `CLAUDE.md` requires — `ps -eo args` over full command lines plus a
  `/proc` cmdline walk, both quoted in Phase 2, with the unit inactive.
  A lone fresh client still fails, so the refusal is state held on the
  compositor side rather than a client-side race.
- **A gamma control leaked by Task 1's own interrupted hand-run probes is
  NOT ruled out.** Task 1 had the user run
  `$GS/bin/gammastep -m wayland -O 4000`, interrupted with Ctrl-C, and
  `$GS/bin/gammastep-indicator`, both inside the same login session that
  is now refusing every client. If that is the cause, then **this
  branch's own verification activity caused the breakage** — a real cost
  of the work, not a fault in `pkgs.gammastep`. A monitor re-apply is a
  second unseparated candidate: the live scale is 1.25 against the 1.5
  `hypr/hosts/suffer.lua` documents, so the Quickshell monitor panel
  applied a mode during this session.
- **The re-login test was deferred by the user**, who could not log out
  and directed the work to proceed on the assumption that gammastep
  functions. That assumption is honoured for sequencing only. It is a
  pending check, not a pass, and the recovery path through
  `hyprctl keyword monitor` is unprobed because this Hyprland build
  rejects the command outright.

Owner: not this flake. It belongs with the applications-panel defect as
follow-up work.
