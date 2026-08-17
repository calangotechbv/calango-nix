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
machine carries 120 of them. The `db:Status-Abbrev` form is the one that
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
they are continuous after it. The count is not a fixed total — it grows
with time rather than settling: measured counts of the `Zero outputs
support gamma adjustment` line alone were `169` at 09:04:25 and `430` at
09:26:15. The distribution (none before 08:57:01, continuous after) is
what carries the argument here, not a bare total.

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
08-14 17:29, 08-15 10:30, and 08-15 23:17. The 08-15 23:17 one is
decisive, because it ran the identical Nix binary in the identical unit:

```
2026-08-15T23:17:51 Stopping night-light.service
2026-08-15T23:17:55 Started night-light.service
2026-08-15T23:17:55 Stopping night-light.service
2026-08-15T23:17:55 Started night-light.service
2026-08-15T23:17:55 night-light: gammastep -m wayland -l -22.9056:-47.0608 -t 3000:3000
2026-08-15T23:17:58 Stopping night-light.service
2026-08-15T23:18:02 Started night-light.service
2026-08-15T23:18:02 night-light: gammastep -m wayland -l -22.9056:-47.0608 -t 6500:3000
```

No warning followed any of those restarts. Generation 23 was active at
that instant (switched 21:19:31; generation 24 followed at 23:34:14), and
its unit names the same store path the failing one does:

```
$ for g in 20 23 24 31 32; do grep -o 'Environment=PATH=/nix/store/[a-z0-9]*-gammastep-[0-9.]*' \
    ~/.local/state/nix/profiles/home-manager-$g-link/home-files/.config/systemd/user/night-light.service; done
gen 20  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
gen 23  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
gen 24  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
gen 31  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
gen 32  Environment=PATH=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
```

`8a7b947`, which put `pkgs.gammastep` into `nightLightPath`, is dated
2026-08-14 16:25:31, so every generation from 20 on ran the store binary —
the same one running today. The identical binary, the identical unit, and
the identical restart pattern worked two days ago and fail today, so the
variable is neither the package nor the toggle path. What triggers the
refusal is unidentified; "latent in the toggle path, exposed by testing"
is deleted here rather than softened, because the 08-15 23:17 restart is
that same toggle path succeeding.

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
