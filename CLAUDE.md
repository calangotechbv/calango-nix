# calango-nix

A Hyprland desktop on Debian 13 (`suffer`), migrating from apt to Nix +
standalone Home Manager. Eight specs are done and written up in
`docs/2026-08-1*-results-suffer-*.md`, with every defect and its owner. This
file exists because the same mistakes kept recurring across them; everything
below has been paid for at least once.

## Running commands

Wrap every `nix` and `home-manager` invocation:

```sh
sg nix-users -c 'nix build ...'
```

`/nix/var/nix/daemon-socket/` is `0770 root:nix-users` (the socket inside is
`0666`). A process whose credentials lack the group fails with
`getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`,
which reads as a broken Nix install. A fresh login also picks the group up, but
`sg` is the convention here and is always correct.

`nix flake check` now runs **two** checks (see `flake.nix`):
`no-dangling-home-files` and `no-pulseaudio-daemon`. Run it after touching any
`.source` in `home/portals.nix` or `home/uwsm.nix`, or anything in
`home/audio.nix`'s `home.packages`.

---

## Tools that answer a different question than the one asked

**Package versions.** `nixpkgs#<pkg>` reads the flake *registry*
(nixpkgs-unstable), not this flake's pinned input. They differ:

```sh
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.xdg-desktop-portal.version'
# 1.20.4  -- the pinned input, what actually gets installed
sg nix-users -c 'nix eval --raw nixpkgs#xdg-desktop-portal.version'
# 1.22.1  -- the registry, irrelevant here
```

Reaching for `nixpkgs#` has produced a wrong version at least three times.

**The systemd user unit search path.** `systemd-analyze --user unit-paths`
computes the list from the *caller's* environment and reports 18 entries,
including `~/.nix-profile/share/systemd/user` at 12 — which the manager has
never seen. The authoritative property is the manager's own:

```sh
systemctl --user show -p UnitPath --value | tr ' ' '\n' | nl
# 5   /home/isutton/.config/systemd/user     <- home-manager's territory
# 6   /etc/systemd/user
# 15  /usr/lib/systemd/user                  <- Debian's
```

In one review cycle a reviewer and the controller drew opposite wrong
conclusions from `systemd-analyze`.

**Enumerating units.** `systemctl --user list-units` does not show a `oneshot`
that has finished — this miscounted `xdg-desktop-portal`'s units as three.
Use `dpkg -L <pkg> | grep systemd/user`, `systemctl --user list-unit-files`, or
`list-units --all`.

**"What is in use".** `/proc/<pid>/maps` is unreadable for other users'
processes, and root outnumbers the user roughly 3:1 here (301 vs 115; only 99
of ~430 processes yield readable maps). A `/proc`-only walk covers a quarter of
the system and once nearly swept `bluez`. Any in-use check must union a `/proc`
walk (`maps` + `exe`) with the first field of `ps -eo args` for *every*
process, resolved through `dpkg -S`.

**Package presence.** `dpkg-query -W -f='${Version}'` prints a version and
exits `0` for `rc` packages (removed, conffiles retained) — which is exactly
what `apt remove` leaves. There are 120 `rc` packages on this machine. Use:

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' <pkg>...
```

Dependency scans over `dpkg-query` include `rc` packages too; filter to `ii`
(`awk '$1=="ii"'`) or the count is inflated.

**Pipelines that report by printing nothing.** `grep … | sed …` exits 0 even
when grep matched nothing, so "the property holds" and "the pipeline broke" are
indistinguishable. Count explicitly (`| wc -l`) and compare the number.

**`pgrep` on a Nix binary.** Nix wraps binaries, so the process name is
`.fumon-wrapped` or `.Hyprland-wrapp` (truncated at 15 chars). `pgrep -x fumon`
matches nothing in both the working and the broken state.

---

## Mechanisms that are not what they look like

**A relative `ExecStart` does not use the manager's `PATH`.** systemd resolves
it against a search path fixed when systemd was compiled:

```sh
systemd-path search-binaries-default
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
```

No `/nix/store` path can ever appear there. `ExecStart=fumon` ran Debian's
binary under Nix's unit file for two whole phases. But
`ExecCondition=/bin/sh -c "command -v X"` *does* use `$PATH`, because `/bin/sh`
is absolute and the shell does the lookup — `~/.nix-profile/bin` is at position
18 against `/usr/bin` at 22 in the session PATH. Every `Exec*=` in a unit this
flake ships must be an absolute path; `home/uwsm.nix` asserts that at build
time by directive *syntax* (`^Exec[A-Za-z]*=`), not by a hand-written list of
directive names.

**A Nix package alone places nothing where it will be found.** Two gaps:

- The session bus's `XDG_DATA_DIRS` has no `~/.nix-profile/share` — check with
  `tr '\0' '\n' < /proc/$(systemctl --user show dbus.service -p MainPID --value)/environ | grep XDG_DATA_DIRS`.
  D-Bus activation files must go into `XDG_DATA_HOME` via `xdg.dataFile`.
- `~/.nix-profile/share/systemd/user` is not on the manager's UnitPath at all.
  Units must go into `~/.config/systemd/user` via `xdg.configFile`.

`dbus-broker` caches its service directory at *its own* startup, before uwsm
sets the session environment, and never rescans on a switch: a fresh login (or
`busctl --user ReloadConfig`) is required.

**D-Bus prefers `SystemdService=` over `Exec=`.** That is a unit *name*, so the
unit search path decides which binary runs — not the `Exec=` line sitting right
above it. Adding the Nix package while Debian's unit is at position 15 changes
nothing.

**`xdg-desktop-portal` case-folds `$XDG_CURRENT_DESKTOP`.** With
`XDG_CURRENT_DESKTOP=Hyprland` the config file is `hyprland-portals.conf`,
lower-case (`man 5 portals.conf`; the binary calls `g_ascii_strdown`). To prove
a config is actually read rather than merely present, run the binary verbosely
on a throwaway bus:

```sh
dbus-run-session -- env XDG_CURRENT_DESKTOP=Hyprland \
  /nix/store/…-xdg-desktop-portal-1.20.4/libexec/xdg-desktop-portal -v
# every interface should resolve "(config)"
```

**Removing a Debian package that ships a systemd *user* unit leaves a dangling
root-owned `/etc/systemd/user/*.wants` symlink.** dpkg's helper creates them;
dpkg does not own them. Seen with `fumon`, `ydotool`, `rewrite-launchers` and
the audio removal. The census taken across specs has moved 8 → 14 → 0: the
audio spec's own removal took the dangling total to 14 (its six audio links
plus the eight inherited), and a subsequent sweep cleared all fourteen — the
count right now is zero, all of them unowned per `dpkg -S`. It will rise again
the next time a package shipping a user unit is removed. Sweep with:

```sh
for f in /etc/systemd/user/*.wants/* /etc/systemd/user/*.upholds/*; do [ -e "$f" ] || echo "$f"; done
```

The glob `*.wants/*` needs at least one entry to expand, so an **empty**
`.wants` directory is invisible to this loop rather than reported by it.
`/etc/systemd/user/pipewire.service.wants/` is exactly that right now — empty,
still present, silent here. Cosmetic, since an empty directory dangles
nothing, but don't read this loop's silence as "no residue of any kind" —
only as "no dangling *symlinks*".

**Removing a package does not kill its running process.** Absence is only
measurable after the session ends — check after the reboot, not before.

**A `.source` pointing at a nonexistent path builds fine.** Home Manager's file
builder uses a bare `ln -s` with no existence test, so you get a dangling
symlink and a clean switch. `nix flake check`'s `no-dangling-home-files` exists
for this.

**fontconfig builds a process's font map at startup.** A running application
cannot see newly installed fonts and keeps deleted ones mmapped — it looks fine
until it is next launched. Restart applications before removing font packages.

**A systemd alias symlink must point at a sibling inside a unit directory.**
systemd decides from the link's *immediate* target, not the fully chased one.
A link into `/nix/store` loads as a second, independent unit with its own
`FragmentPath`; a relative link to the sibling gives one unit under two
names. `xdg.configFile` always emits `~/.config/… -> /nix/store/<home-manager-files>/…`,
so it can never express an alias — and neither can `mkOutOfStoreSymlink`,
which routes hop 1 through the same store. Home Manager's
`modules/systemd.nix` has no `Install.Alias` handling and sd-switch never
calls `enable`. The only mechanism is a raw `ln -s` from `home.activation`.
The failure is silent: `Wants=` and `After=` naming a unit that does not
exist are dropped along with their ordering, and `--state=failed` stays empty.
And the link is unmanaged by Home Manager's own file manifest —
`no-dangling-home-files` walks `home-files` and never sees it, so removing
`home/audio.nix` from the flake's module list leaves
`~/.config/systemd/user/pipewire-session-manager.service` dangling forever
unless someone deletes it by hand — the same species as the root-owned
`/etc/systemd/user/*.wants` residue below, now reproduced in the user's own
tree by this flake.

**`systemctl --user show-environment` is not what a boot-path unit
inherited.** It reports the manager's environment *as it is now*, after uwsm
has set the session environment. Units pulled in by `default.target` or
`sockets.target` start before that — measured here, three seconds before
`graphical-session.target` — so their `XDG_DATA_DIRS` has no
`~/.nix-profile/share`. The authoritative source is the unit's own
`/proc/<MainPID>/environ`. Same trap as `systemd-analyze --user unit-paths`
above, in a new place.

**wireplumber resolves its scripts and config through `XDG_DATA_DIRS`;
pipewire does not.** pipewire uses a compiled-in datadir and
`PIPEWIRE_CONFIG_DIR`. So a Nix wireplumber will happily execute Debian's Lua
scripts, and the resulting API-mismatch tracebacks read as an upstream bug in
the new version. `home/audio.nix` pins it with a `wireplumber.service.d`
drop-in setting `WIREPLUMBER_DATA_DIR`. Do not assume the two halves of a
subsystem find their data the same way.

**PipeWire's bluez5 SPA plugins are loaded by wireplumber, not pipewire.**
Checking `/proc/<pipewire-pid>/maps` for them returns 0 whether Bluetooth
works or not — a check that cannot fail. The session manager's maps are where
they appear.

**An apt removal orphans packages the Nix side still needs.**
`apt-get -s remove` prints a "no longer required" list that is easy to skim
past. Removing the audio set orphaned `rtkit` and, at that same moment,
`pulseaudio-utils` — both were marked manual to survive the removal. Neither
goes at removal time; an unmarked orphan goes to some later `apt autoremove`,
by which point the breakage gets blamed on something else entirely. Read
that list and `apt-mark manual` what is still in use, **as of that
moment** — that qualifier matters, because the two kept different fates.
`rtkit` stayed manual permanently: `rtkit-daemon` is a system service Nix can
never own (see Standing facts below). `pulseaudio-utils` did not — once
`pactl` and its siblings came from Nix (`home/audio.nix`'s
`pulseaudioClients`, in Phase 3b), it was removed on purpose. The sequence is
the instructive part: "rescued from autoremove" is not "kept forever", and
the standing fact further down that `pulseaudio-utils` is gone is that same
package at a later phase, not a contradiction of this one.

---

## Standing facts about this machine

- **`bluez` cannot move to Nix.** `bluetoothd` runs from
  `/usr/lib/systemd/system/bluetooth.service` — a *system* unit — and
  standalone Home Manager writes only `~/.config/systemd/user`. Permanent apt
  dependency, by architecture. It is marked manual so `autoremove` cannot take
  it. Do not re-open this.
- **The corp set stays on apt permanently:** `google-chrome-stable`, `code`,
  `1password`, `1password-cli`, `endpoint-verification`, and flatpak Slack
  (`com.slack.Slack`).
- **A previous Home Manager generation is not a recovery path.** It lacks the
  uwsm session units, both portal backends, the portal frontend, the portal
  config and the font baseline. Recovery is fix-forward:
  `home-manager switch` from tty1, or
  `sudo dpkg -i /root/pkg-archive/uwsm_*.deb` (note: **root's** home).
- **One file outside `$HOME`:** `/usr/local/share/wayland-sessions/hyprland-nix.desktop`,
  root-owned, hand-created, covered by no Nix module. greetd needs it and
  nothing else supplies it.
- Every Nix **GUI** binary needs the nixGL wrapper (compositor, quickshell,
  hyprlock, hyprpolkitagent, the hyprland portal). Apt GUI applications do not.
  `ldd` cannot answer this for Qt: it `dlopen`s its platform and GL plugins, so
  `ldd` is clean for a binary that aborts on first draw.
- Recurring shape: a Nix library resolving a NixOS-only path
  (`/run/opengl-driver/lib`, `/run/wrappers/bin/polkit-agent-helper-1`,
  `/run/wrappers/bin/unix_chkpwd`). Fixed with scoped overlays in `flake.nix`,
  always with `--replace-fail` so an upstream change breaks the build.
- 218 MB of fonts under `~/.local/share/fonts` are owned by neither apt nor
  Nix; `~/.local/share/fonts/calango-desktop/` shadows the flake's
  `adwaita-fonts`.
- **`rtkit` cannot move to Nix,** for the same architectural reason as
  `bluez`: `rtkit-daemon` runs from
  `/usr/lib/systemd/system/rtkit-daemon.service`, a *system* unit, and
  standalone Home Manager writes only `~/.config/systemd/user`. It grants
  pipewire's `data-loop.0` thread `SCHED_RR` priority 20 — measured under
  Nix's pipewire. Marked manual so `autoremove` cannot take it. Do not
  re-open this.
- `pulseaudio-utils` is gone; `pactl` comes from Nix through
  `home/audio.nix`'s `pulseaudioClients`, which withholds the daemon
  deliberately. Never add `pkgs.pulseaudio` to `home.packages` —
  `flake.nix`'s `no-pulseaudio-daemon` check exists to stop exactly that.

---

## The method that actually worked

Checks that read a **running process's own state** told the truth every time:

```
/proc/<pid>/exe        /proc/<pid>/cmdline      grep -c '/usr/' /proc/<pid>/maps
busctl --user status   systemctl --user show -p MainPID -p NRestarts
```

Checks that compared a **path, a name or an exit code** eventually lied. A unit
resolving to `~/.config/systemd/user` says nothing about which binary it
executes. `NRestarts=0` after a cold boot is worth more than `is-active` after
a warm start.

**Prove a check can fail before trusting it.** Three checks in spec 6 passed
while the property they stood for was false, and two guards in `home/uwsm.nix`
were only trusted after being verified by mutation.

The deeper pattern is not laziness. In every one of these cases a real command
was run and real output was read; the error was in the *conclusion drawn
afterwards*, which the measurement did not support. Enumerate by syntax, never
by a remembered list of names — including inside a document that says so.
