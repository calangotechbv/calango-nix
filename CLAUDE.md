# calango-nix

A Hyprland desktop on Debian 13 (`suffer`), migrating from apt to Nix +
standalone Home Manager. Ten specs are done and written up in
`docs/2026-08-1*-results-suffer-*.md`, with every defect and its owner. Count
that number, never increment it: `ls -1 docs/*results-suffer-*.md | wc -l` is
the authority, and spec 10 landed here saying "Nine" because eight had been
incremented once and spec 9 had never bumped it at all. This
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

`nix flake check` now runs **three** checks (see `flake.nix`):
`no-dangling-home-files`, `no-pulseaudio-daemon` and `gui-desktop-ids`.

Run it after touching a `source =` anywhere under `home/`, `guiPackages` in
`home/gui-apps.nix`, the `applications/` `xdg.dataFile` entries in
`home/apps.nix`, or the `required` list in `flake.nix`. The first of those is
deliberately stated as *syntax* rather than as a list of modules: an earlier
version of this passage named `home/portals.nix` and `home/uwsm.nix`, and
`grep -l 'source =' home/*.nix` returns **ten** modules, so the named pair
silently excused the other eight — `home/audio.nix:195,231` among them. Grep
for the property; do not trust a list of names, including this sentence's.

Further build-time guards ride in `home.packages` rather than in `checks`, so
they run on every generation build — strictly more often than
`nix flake check` is invoked — and none of them appears in that count of three.
Enumerate them the same way, by syntax: `grep -n 'home.packages' home/*.nix`,
then read what each list contains. An earlier version of this passage said
"two", naming only `home/gui-apps.nix`'s `wrappedGuiApps` and
`dbusActivatableGuiApps`; `home/audio.nix:385` also puts `pulseaudioClients`
there, and *that derivation's own body* carries three `exit 1` guards — a
number that needs its own command, because the file around it has nine:

```sh
grep -c 'exit 1' home/audio.nix
# 9   -- the whole file, a different thing
sed -n "/pulseaudioClients = pkgs.runCommand/,/^  '';$/p" home/audio.nix | grep -c 'exit 1'
# 3   -- inside pulseaudioClients, which is what the claim is about
```

A package-producing derivation can be a guard too, which is exactly what a
remembered list of "the guards" misses.

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
what `apt remove` leaves. There are **128** `rc` packages on this machine as of
spec 10 — and that figure moves every time a spec removes something, so count it
rather than quoting this line:

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="rc"' | wc -l
```

It read 120 for three specs while the true count drifted upward, and spec 10's
own three (`thunar`, `thunar-volman`, `pcmanfm-qt`) are part of the difference.
Use:

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

**Nor does it make the unit disappear from `systemctl --user show`.** The
manager caches its unit table until a reload, so a unit whose fragment has just
been deleted still reports `LoadState=loaded` and `UnitFileState=enabled`, with
a `FragmentPath` pointing at a file that is no longer there. Measured right
after `apt remove foot`:

```sh
systemctl --user show foot-server.service -p LoadState -p FragmentPath -p UnitFileState
# LoadState=loaded
# FragmentPath=/usr/lib/systemd/user/foot-server.service   <- does not exist
# UnitFileState=enabled
```

`list-unit-files` had already dropped it, so the two disagree. Checking a
unit's *absence* with `show`, without a `daemon-reload` or a fresh login, is a
false positive waiting to happen.

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

**Deleting a Debian `.wants` link does not disable the unit for long.** `gcr4`'s
and `openssh-client`'s postinst run `deb-systemd-helper --user unmask` and then
re-enable when `was-enabled` returns true — and it defaults to true, because a
bare `rm` never updates that helper's statefile under
`/var/lib/systemd/deb-systemd-helper-enabled/`. So the next upgrade of the
package silently restores the link. `deb-systemd-helper` only ever touches
`/etc`, so the durable answer is a **mask** in `~/.config/systemd/user`
(UnitPath position 5), which is also owned by the flake instead of by root.

**A symlink's meaning depends on which question systemd is asking, and the
answers differ.** Masking asks "does this unit path resolve to `/dev/null`",
which is a full chase, so a store-mediated link masks fine. Aliasing compares
the link's name against its **immediate** target's basename, so a store-mediated
link is not an alias at all (see `home/audio.nix`). Both were measured on this
machine. Do not carry a result from one to the other.

**And probe every layer the change passes through, not just the interesting
one.** The mask shape above was probed against systemd by hand and passed —
then the build failed, because `xdg.configFile`'s `source` is a `types.path`
and Nix refuses to import `/dev/null` in pure evaluation mode
(`access to absolute path '/dev' is forbidden`). The runtime question was
answered and the build question was assumed. The fix is a one-line
`runCommand` whose output *is* a symlink to `/dev/null`, which is pure because
`ln -s` never resolves its target.

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

**nixpkgs relocates GSettings schemas, and then wraps the binary to find
them.** Schemas live at `share/gsettings-schemas/<name>/glib-2.0/schemas`, a
path GLib never searches — but `wrapGAppsHook` produces a `bin/<name>` wrapper
that prefixes `XDG_DATA_DIRS` with every schema directory the application
needs, so a Nix GTK application works on Debian with no help from this flake.
The thing to check is that the wrapper *exists*: a package that missed the hook
aborts at startup with `Settings schema … is not installed`, which reads as a
broken package rather than a missing environment. Detect it by the
`.<name>-wrapped` sibling in `bin/`, not by grepping the binary —
`makeWrapper` emits a shell script and `makeBinaryWrapper` an ELF, and a check
that understands only one passes vacuously on the other.
`home/gui-apps.nix`'s `wrappedGuiApps` is the guard for this property, and it is
the only one — spec 10 first wrote that `gui-desktop-ids` was "the other half"
of it, which is false: that check asserts `.desktop` ids and contains no schema
or wrapper logic at all. The three checks spec 10 added cover three unrelated
properties, and conflating any two of them is how a guard comes to look
load-bearing for something it never touches:

| check | property | where |
|---|---|---|
| `wrappedGuiApps` | every GUI package with schemas has a wrapped binary | `home.packages` |
| `dbusActivatableGuiApps` | every package shipping a D-Bus service file has an `xdg.dataFile` mirror | `home.packages` |
| `gui-desktop-ids` | the `.desktop` ids this flake must ship are present | `checks` |

**A `.desktop` file's winning entry and its winning binary are chosen by two
different search paths.** `XDG_DATA_DIRS` decides which `.desktop` a launcher
reads; a bare-name `Exec=` is then resolved through `PATH`. While both a Debian
and a Nix package are installed, those can disagree — Nix's `.desktop` running
Debian's binary, or the reverse. Same shape as spec 6's `fumon`. Removing the
apt package is part of making it deterministic, not cleanup afterwards.

**`.desktop` ids are not stable across the Debian/Nix boundary.** nixpkgs'
`signal-desktop` ships `signal.desktop` where Debian's ships
`signal-desktop.desktop`, and `~/.config/mimeapps.list` names the Debian id for
`x-scheme-handler/sgnl` and `x-scheme-handler/signalcaptcha`. Migrating Signal
without checking kills both handlers silently. Some ids *are* identical —
`firefox-esr.desktop`, `org.gnome.seahorse.Application.desktop` — which is
worse than none being identical, because it invites the assumption.

**A Nix comment and a shell comment are not the same thing, and the difference
is which side of the string boundary it is on.** A `#` comment in a Nix
expression — inside a `lib.makeBinPath` list, say — does not reach the
derivation and cannot change its hash. A `#` comment inside a `''…''` string
that becomes `buildCommand` **is** part of the derivation, so editing it moves
the output path. Both claims were made on the same branch, the second one
asserting byte-identical derivations across generations; it was disproved by
diffing them, where `inputDrvs`, `inputSrcs`, `args`, `builder` and `system`
were identical and `buildCommand` differed by exactly one comment line. If you
want to know whether a comment mattered, diff the derivation rather than
reasoning about the comment.

---

## Standing facts about this machine

- **`bluez` cannot move to Nix.** `bluetoothd` runs from
  `/usr/lib/systemd/system/bluetooth.service` — a *system* unit — and
  standalone Home Manager writes only `~/.config/systemd/user`. Permanent apt
  dependency, by architecture. It is marked manual so `autoremove` cannot take
  it. Do not re-open this.
- **`gnome-keyring` stays on apt, deliberately — and this one was decided after
  a survey, not by default.** It serves `org.freedesktop.secrets` and
  `org.gnome.keyring` on the session bus and backs
  `org.freedesktop.impl.portal.Secret`, which `hyprland-portals.conf` names. It
  is a genuine candidate on paper, and three measurements say leave it:
  - **nixpkgs' package ships no systemd units and no D-Bus activation files.**
    `find <store> -path '*systemd*'` returns 0, where Debian ships two units
    and three activation files. Every migration in this project copied units
    verbatim; here all five artifacts would have to be hand-authored, which is
    the drift the copy-verbatim rule exists to avoid.
  - **`pam_gnome_keyring.so` is in `/etc/pam.d/greetd`** (`auth optional`, and
    `session optional … auto_start`), from Debian's `libpam-gnome-keyring`.
    That is the auto-unlock path. nixpkgs does ship the module at
    `lib/security/pam_gnome_keyring.so`, but using it means a root-owned
    system file referencing a `/nix/store` path — and if that path is ever
    garbage-collected or the package dropped, **login breaks**. Every other
    failure mode this project has accepted is recoverable from a running
    desktop. This one is not.
  - 48 → 50 is two majors, on `~/.local/share/keyrings/login.keyring`, a live
    file.

  Note the daemon is currently owned by the *systemd user unit*, not by PAM's
  `auto_start` — `/proc/<pid>/cgroup` puts it in
  `app.slice/gnome-keyring-daemon.service`. PAM's `auth` hook is what passes
  the login password through to unlock the keyring, and that is the part with
  no user-space replacement. Do not re-open this without answering the PAM
  question first.
- **`gcr4` cannot be removed either — it takes `gnome-keyring` with it.**
  `apt-get -s remove gcr4` removes `gcr`, `gcr4`, `gnome-keyring`, `seahorse`,
  `pinentry-gnome3` and `golang-docker-credential-helpers`; `gnome-keyring`
  declares `Depends: gcr (>= 3.4)`. So `gcr-ssh-agent` can be **masked but
  never uninstalled**, and a one-level `apt-cache rdepends` does not show this
  — it reports only `gcr`, which looks discardable. Simulate the removal.
- **The ssh agent is `gcr-ssh-agent`; openssh's `ssh-agent.service` and
  `.socket` are masked in `home/services.nix`.** Debian enables both, and both
  set `SSH_AUTH_SOCK` from `ExecStartPost` with no ordering between them, so
  which agent a shell talked to was decided by whichever activated last
  (measured: identical `ActiveEnterTimestamp`). `SSH_AUTH_SOCK` is now
  `/run/user/1000/gcr/ssh`. `gcr-ssh-agent` is a wrapper and runs openssh's own
  agent underneath on a private socket, so nothing is lost by the choice; it
  was kept because `gcr4` is a permanent resident anyway. Home Manager's
  `services.ssh-agent` is **not** a drop-in — it exports the variable only from
  shell initialisation, where Debian's socket sets it in the manager's
  environment, so adopting it would leave every GUI application that was not
  launched from a shell without it.
- **Open question, not a conclusion: can `gcr-ssh-agent` persist a key across
  logins?** The reason to prefer it would be keyring-backed passphrases. What
  was measured: `ssh-add` against its socket writes nothing to
  `~/.local/share/keyrings/login.keyring`, and the key does not survive even a
  restart of the agent — because `ssh-add` decrypts the key locally and sends
  the *decrypted key* over the agent protocol, so the agent never sees a
  passphrase to store. What was not measured: the binary links `libsecret` and
  carries `secret_password_storev`/`lookupv`, so a storage path exists that
  this probe did not reach. The likely trigger is on-demand loading of a key
  from `~/.ssh/`, which needs a test against real key material. Until someone
  runs that, treat keyring persistence as unproven.
- **The corp set stays on apt permanently:** `google-chrome-stable`, `code`,
  `1password`, `1password-cli`, `endpoint-verification`, and flatpak Slack
  (`com.slack.Slack`). Note `1password` is load-bearing beyond its own window:
  `~/.ssh/config` sets `IdentityAgent ~/.1password/agent.sock` for `github.com`,
  and that agent holds the SSH keys — which is why Debian's `ssh-agent` and
  `gcr-ssh-agent` serve nothing here.
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
- **There is deliberately no foot server.** `pkgs.foot` ships
  `foot-server.service` and `foot-server.socket`, but they land in
  `~/.nix-profile/share/systemd/user`, which is not on the manager's UnitPath
  at all — so their presence in the store is not an oversight to be corrected.
  Debian's `foot` was removed because its unit *was* enabled, by two root-owned
  links, and had been running a 1.21.0 server for months while every terminal
  on screen was Nix's 1.27.0: a mixed-provenance shadow of the same shape as
  spec 6's `fumon`. Nothing used it — zero references to `footclient` anywhere
  in this repo, and `SUPER+Q` runs `foot` standalone. Server mode buys startup
  latency and, measured here, roughly 13 MB of private RSS per window beyond
  the first against a 15.7 MB baseline — a wash at two windows. It would also
  put every window in one process that parses the config once, which is a
  hazard for the quickshell theme switcher (see `home/foot.nix`, which records
  that a theme change already fails to reach an *open* window). Adopt it only
  after testing that interaction.
- **`seahorse` is Nix's; `gnome-keyring` and `gcr4` are Debian's, and that is
  correct rather than half-finished.** The coupling is D-Bus — `libsecret`
  talking to `org.freedesktop.secrets`, a stable cross-version API — not shared
  libraries. Nix's seahorse links Nix's own gcr inside its own process. This is
  the first client in this project to cross the boundary while its daemon did
  not, and it is the template for the remaining GUI applications.
- **`gammastep` is entirely Nix's.** It was a two-provenance split until spec
  10: `pkgs.gammastep` reached the night-light unit through
  `home/services.nix`'s `nightLightPath` but never through `home.packages`, so
  the unit ran 2.0.11 while a shell got Debian's 2.0.9. `nightLightPath` still
  names it explicitly on purpose — a unit that resolves its own binaries does
  not depend on `PATH` order.
- **`flatseal` and `fresh-editor` stay on apt.** `flatseal` is absent from
  nixpkgs and is really a flatpak; nixpkgs' `fresh-editor` is 0.3.6 against
  Debian's 0.4.7, so moving it would be a downgrade.
- **`~/.config/mimeapps.list` has at least two dead associations, and they are
  not this flake's.** `eu.calangotech.KBrowserSelector.desktop` — the stale
  root-owned entry `home/apps.nix`'s `defaultBrowser` hook displaced in
  `[Default Applications]`, still named by both `[Added Associations]` lines,
  and present nowhere on disk — and `slack.desktop`, where the only Slack entry
  on the search path is flatpak's `com.slack.Slack.desktop`, a different id.
  "At least two" rather than exactly two: the count was measured in one shell's
  `XDG_DATA_DIRS`, not the activation script's, and a narrower search path can
  only report more missing ids. This is why `home/apps.nix`'s `mimeappsIds`
  hook is **non-fatal by requirement rather than by convenience** — a fatal
  version would now abort every switch on this machine over associations this
  flake does not own and never will.
- **Night light is degraded, with the trigger unidentified.** Since
  2026-08-17 08:57 every gamma client on this machine is refused by Hyprland
  (`Zero outputs support gamma adjustment`), including `night-light.service`'s
  own. It is not the package — the same store path in the same unit toggled
  warning-free on 08-15 10:30:39 under generation 18 — and a competing live
  client is ruled out by the union instrument. A gamma control leaked by spec
  10's own interrupted hand-run probes is **not** ruled out, nor is a monitor
  re-apply (live scale 1.25 against the 1.5 in `hypr/hosts/suffer.lua`).
  The re-login test that would separate them was deferred by the user and has
  **not** been run; `hyprctl keyword monitor` is rejected by this Hyprland
  build, so that recovery path is unprobed. Do not read "proceed assuming it
  works" as a measurement.

  **Disposition: if a re-login restores gamma control, delete this entry — do
  not soften it.** A transient compositor state is not a standing fact about
  this machine, and the wrong move on recovery is to reword it into something
  vaguer that survives forever. If instead it persists across a fresh login,
  the entry stays and stops being about spec 10 at all: it becomes a Hyprland
  gamma-control fact, and the leaked-probe candidate above is dead, because a
  leak cannot outlive the process that held it.

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

**And prove it against the property it claims to cover, not just against
itself.** Spec 10's `gui-desktop-ids` was proven able to fail by mutation and
still did not do what it said: it declared coverage of the ids
`mimeapps.list` names *and* this flake provides, while reading only
`home-path/share/applications` — and the single id satisfying both halves is an
`xdg.dataFile` entry landing in `home-files/.local/share/applications`. It
passed because every id it actually listed was one no handler references, so its
stated purpose was unreachable by its own mechanism. Same species as spec 6's
three checks, and caught by a reviewer rather than by production. Read a
check's declared scope against the paths it really searches.

The deeper pattern is not laziness. In every one of these cases a real command
was run and real output was read; the error was in the *conclusion drawn
afterwards*, which the measurement did not support. Enumerate by syntax, never
by a remembered list of names — including inside a document that says so.

**Spec 10 reproduced this inside a controller ruling**, which is worse than in a
comment: a ruling is what the rest of a task is built on. The ruling held that a
mid-session restart of the night-light client was the first the machine had ever
logged, generalised from a 40-line journal window containing only the four
preceding boots; the full journal shows warning-free mid-session toggles on
08-13, 08-14 and twice on 08-15. It was withdrawn, but not before reaching a
committed document. And the union-instrument rule above — that a process-absence
claim must union `ps -eo args` over *full* command lines with a `/proc` walk —
was violated on that same branch despite already being written here: an exe-only
walk backed the decisive step, and a reviewer found a process it had missed. A
rule being documented is not a rule being followed; check the instrument against
this file when the claim is load-bearing.
