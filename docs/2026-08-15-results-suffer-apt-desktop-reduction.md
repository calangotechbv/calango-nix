# Results: reducing the apt desktop footprint — suffer

2026-08-15

## Phase 1: the tasksel metapackages

The list was built by syntax rather than transcribed:

```
$ apt-mark showmanual | grep '^task-' | sort | wc -l
136
$ apt-mark showmanual | grep '^task-' | grep -v -- '-desktop$'
(no output — all 136 end in -desktop)
```

The **entire** removal list was read before executing, not sampled:

```
$ apt-get -s remove $(…136 names…) tasksel | grep '^Remv' | wc -l
138
$ … | grep -v '^task-'
tasksel
tasksel-data
```

Two non-`task-` entries, both expected. A grep for danger patterns
(`pam|login|greet|systemd|dbus|polkit|portal|kde|qt|gtk`) returned 63 hits,
every one of them a `task-*-kde-desktop` metapackage *name* — the pattern
matching a substring of the thing being removed rather than a package of that
kind. Worth recording because it is the shape of a false positive that could
easily have been read as a false negative in the other direction.

### After

```
task-* remaining:  0
tasksel:           rc
installed total:   3118   (from 3256 — exactly 138)
failed units:      none
```

All five session services active. `xdg-desktop-portal-gtk` still `ii`, which
mattered: at this point it was still the only FileChooser provider.

### The number the plan got wrong

The plan expected `apt-get -s autoremove` to report **0** afterwards. It
reported **466**.

Removing the metapackages orphaned the entire language stack they had been
holding. By `Section`: 133 localization, 121 libs, 65 fonts, 53 utils, 28 doc,
17 text, 12 x11. In content: `fcitx5`, `ibus`, `uim`, `anthy`, `hangul`,
`mozc` and their libraries, thesauri, and 63 font packages spanning Indic,
Arabic, Georgian, Khmer, Ethiopic, Uyghur and Japanese scripts.

This mattered because Phase 2 runs a bare `apt autoremove`, which would have
swept all 466 alongside KDE's own packages — a scope expansion the spec had
explicitly excluded, happening inside a task labelled "the KDE installation".

Measured before deciding: no input method was running, none autostarts, the
locale is `en_US.UTF-8`, and `XMODIFIERS=@im=ibus` is set but consumed by
nothing. The fonts were the real question, and the user's answer was that only
Latin scripts are used here.

## The font baseline moves to Nix

Not in the original plan. It came out of the Phase 1 finding: if Debian's
fonts were going to be swept, what was actually supplying the defaults?

```
$ fc-match sans-serif → /usr/share/fonts/truetype/noto/NotoSans-Regular.ttf   (fonts-noto-core)
$ fc-match serif      → /usr/share/fonts/truetype/noto/NotoSerif-Regular.ttf  (fonts-noto-core)
$ fc-match monospace  → /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf   (fonts-dejavu-mono)
```

All three providers survive the sweep — so this was insurance, not a fix. But
they survive *incidentally*: nothing in the flake asked for them, and they are
held by apt reverse-dependencies that a later spec could remove. A default
font that exists by accident is one `apt autoremove` away from tofu in every
application.

`noto-fonts`, `dejavu_fonts` and `liberation_ttf` went into `home.packages`.
`noto-fonts` ships **229 files** covering Bengali, Devanagari, Arabic,
Armenian and the rest, which makes the sweep's per-script Debian font packages
redundant rather than a loss.

The mechanism needed no new wiring, and was verified rather than assumed:
`fc-list` already listed `Adwaita Sans` and `AdwaitaMono Nerd Font`, which
exist only in the store, so Debian applications were already reading Nix fonts
through the same fontconfig. After the switch:

```
$ fc-match sans-serif → /nix/store/…-home-manager-path/share/fonts/noto/NotoSans.ttf
$ fc-match serif      → /nix/store/…-home-manager-path/share/fonts/noto/NotoSerif.ttf
$ fc-match monospace  → /nix/store/…-home-manager-path/share/fonts/truetype/DejaVuSansMono.ttf
```

### A process must be restarted to see new fonts

Chrome had 38 font files mmapped, every one from `/usr/share/fonts`, and zero
from the store — because fontconfig builds a process's font map at startup.

This is not cosmetic. Had Chrome still been running on Debian's font files
when Phase 2 removed them, it would have kept the deleted inodes mapped and
looked fine until closed, then broken on next launch — a failure disconnected
in time from its cause. Restarting Chrome first moved it onto Nix's fonts
before the sweep:

```
/nix/store/…-noto-fonts-2026.05.01/share/fonts/noto
/nix/store/…-liberation-fonts-2.1.5/share/fonts/truetype
```

### An unmanaged 218 MB, and it is not dormant

```
$ ls ~/.local/share/fonts/calango-desktop | wc -l
101
$ du -sh ~/.local/share/fonts
218M
```

Hand-copied files, no Home Manager symlinks among them, dated 2026-07-15,
namespaced under the repository this project migrated away from. They are
live: 36 of them are served by fontconfig, and

```
$ fc-match "Adwaita Sans"
/home/isutton/.local/share/fonts/calango-desktop/AdwaitaSans-Regular.ttf
```

wins over the flake's own copy at `~/.nix-profile/share/fonts/Adwaita/`. The
portal's file dialog rendered with the hand-copied one. So `adwaita-fonts` in
`home/default.nix` is currently decorative — the font that actually draws
comes from a directory neither apt nor Nix owns. Recorded, not fixed.

## Phase 3a: the gtk backend moves to Nix

Done before Phase 2 rather than after, inverting the plan's order. The whole
spec is built on shadow-then-remove, and both new shadows — the gtk portal
backend and the Nix font baseline — should be live before anything is removed.

### Adding the package would have changed nothing

Both Debian's and Nix's D-Bus activation files carry the same line:

```
SystemdService=xdg-desktop-portal-gtk.service
```

D-Bus prefers the unit over `Exec=`, and that is a unit *name* resolved
through the user manager's search path — which answered with Debian's unit at
`/usr/lib/systemd/user` (position 15) and therefore Debian's binary. The fix
is Nix's own unit at `~/.config/systemd/user` (position 5), copied verbatim
because it already carries an absolute store path.

Same defect class as spec 6's `ExecStart=fumon`: a name resolved through a
search path where the wrong provider answers.

### Two errors caught by review, both written by the controller

**The config filename was wrong.** `Hyprland-portals.conf` would never have
been read. `man 5 portals.conf`: *"DESKTOP is the desktop environment name in
lower-case"*; the binary carries `g_ascii_strdown` beside its
`%s-portals.conf` format string; the only such file on the system was
`lxqt-portals.conf`, under a desktop named `LXQt`. The declared backend
selection would have been dead on arrival, and selection would have silently
stayed accidental.

The mistake was checking `XDG_CURRENT_DESKTOP=Hyprland` and concluding the
filename followed from it — a real measurement, and an unverified inference
laid on top.

**The D-Bus activation file needed an explicit entry after all.** The spec had
argued none was required, because both service files name the same unit. That
explains which *binary* runs once D-Bus decides to activate; it says nothing
about whether D-Bus can find an activation file at all.

```
$ systemctl --user show dbus.service -p MainPID --value
3039
$ tr '\0' '\n' < /proc/3039/environ | grep XDG_DATA_DIRS
XDG_DATA_DIRS=…flatpak…:/usr/local/share/:/usr/share/
```

No `~/.nix-profile/share`. The session bus does not see the Nix profile, so
once Debian's package goes, Nix's activation file must reach `XDG_DATA_HOME`
via an `xdg.dataFile` entry — which the hyprland backend in the same file
already had, with a comment recording that it was found post-reboot and
hand-fixed.

The earlier measurement said the opposite because it read `XDG_DATA_DIRS` from
a process found by matching a name pattern, rather than from the process
systemd reports as the bus. Third instance in this spec of *a thing matching
the pattern* standing in for *the thing*.

### The gate

```
FragmentPath  /home/isutton/.config/systemd/user/xdg-desktop-portal-gtk.service
ExecStart     /nix/store/…-xdg-desktop-portal-gtk-1.15.3/libexec/xdg-desktop-portal-gtk
serving PID   /nix/store/…/libexec/.xdg-desktop-portal-gtk-wrapped
```

A real file dialog opened in Chrome and was confirmed by eye to render
correctly — fonts, sizing and icons — because a process check passes whether
or not the dialog draws like a broken stylesheet. Screenshot and screen share
both still worked through `hyprland.portal`.

The four `/usr/` mappings remaining in the portal process are read-only Debian
data caches (`gschemas.compiled`, `icon-theme.cache`, `mime.cache`), not code.

## Phase 2: the KDE installation

878 packages, after `bluez` was protected.

### The check the plan should have specified

The plan said to read the whole `Remv` list and justify anything matching
PAM, login, D-Bus, systemd, polkit or portal. That is still name-matching. At
878 packages it is also not a thing a person does reliably.

So the property was measured instead — walk every running process, resolve
every mapped file and every `exe` to its owning package, and intersect that
set with the removal list:

```
distinct in-use paths:     892
distinct packages in use:  321
in the sweep AND in use:    17
```

Eyeballing the list found `bluez`, because the name looks important. It would
not have found `geoclue-2.0`.

### bluez

```
1083 /usr/libexec/bluetooth/bluetoothd
3041 /usr/bin/mpris-proxy
bluetooth.service: active
```

Both binaries come from `bluez`, and the flake's own `bt-agent.service` runs
against that daemon. It was in the sweep only because it is marked `auto` and
its last installed reverse-dependency is `libreoffice-impress`. Protected with
`apt-mark manual bluez`; the sweep dropped from 879 to 878, with `bluez` the
only package to leave the list.

**bluez cannot move to Nix.** It runs as root from
`/usr/lib/systemd/system/bluetooth.service` — a *system* unit. Standalone Home
Manager writes `~/.config/systemd/user` only. This is a permanent apt
dependency by architecture, not by preference, and is recorded here so a later
cleanup does not re-open it.

### The other sixteen

Fifteen map only into `kwalletd6` and `kdeconnectd`, the two daemons being
deliberately removed, so they leave with them. The exceptions:

- **`geoclue-2.0`** — its only user is its own demo agent, and
  `quickshell/night-light/locate.sh` carries the comment *"Not geoclue"*; it
  uses `curl` and `jq`. Held only by `libqt5positioning5`, itself in the sweep.
- **`kimageformat6-plugins`** — also mapped by `deskflow`, which survives. It
  is **not** a declared dependency of deskflow; Qt scans its plugin directory
  at startup and maps whatever is present. The package supplies exotic image
  codecs (`avif`, `heif`, `jxl`, `psd`, `xcf`, `exr`, `raw`), which Qt
  degrades gracefully without.

### After

```
installed total:  2240   (3256 → 3118 → 2240; 1016 packages removed in all)
autoremovable:    0
failed units:     none
```

Survivors verified `ii`: `bluez`, `xdg-desktop-portal`,
`xdg-desktop-portal-gtk`, `gnome-keyring`, `fontconfig-config`,
`fonts-noto-core`, `fonts-dejavu-mono`, `deskflow`, `google-chrome-stable`,
`code`, `1password`. `bluetooth.service` still active.

### Across the reboot

```
$ who -b
system boot  2026-08-15 22:31
```

No failed units. No PAM errors from greetd — the `-auth optional` /
`-session optional` prefixes on the `pam_kwallet5.so` lines did what they
promise, and `/etc/pam.d/greetd` was never edited. Neither daemon came back.

All six user services active, including `bt-agent.service`, which is the
practical confirmation that protecting `bluez` was right. The portal unit
still resolves to `~/.config/systemd/user`, and `fc-match` still answers from
the store.

The daemon check was moved here deliberately: removing a package does not kill
its running process, so `kwalletd6` and `kdeconnectd` both survived their own
removal until the session ended. Checking before the reboot would have
reported them present and been read as a failure.

## Phase 3b: the displaced backends

Scope had shrunk before this ran: Phase 2's sweep had already taken
`xdg-desktop-portal-kde` and `kwallet6`. Two packages remained —
`xdg-desktop-portal-lxqt`, which had never been used here (`FileChooser`,
`UseIn=LXQt`), and Debian's `xdg-desktop-portal-gtk`, now redundant.

Neither was mapped by any running process. Removing them took exactly two
packages.

### After

```
apt .portal files:              gnome-keyring.portal
nix .portal files:              gtk.portal   hyprland.portal
D-Bus activation, apt:          PermissionStore, Secret
D-Bus activation, XDG_DATA_HOME: …desktop.gtk.service   …desktop.hyprland.service

gtk portal unit:  /home/isutton/.config/systemd/user/xdg-desktop-portal-gtk.service   active
serving exe:      /nix/store/…-xdg-desktop-portal-gtk-1.15.3/libexec/.xdg-desktop-portal-gtk-wrapped
/usr code mappings in it:  0
```

Those two `XDG_DATA_HOME` activation files are the Task 1 review finding doing
its job. Without them this step would have left D-Bus with no activation file
for `org.freedesktop.impl.portal.desktop.gtk`, and the first symptom would
have been Chrome unable to open a file — at the point the change was hardest
to trace back to its cause.

## Phase 4: apt's quickshell

Gate first: Nix's quickshell was MainPID 3923, a store path, zero `/usr` code
mappings, and the process answering `GetServerInformation` as
`quickshell 1.2`. Apt's `/usr/bin/qs` and `/usr/bin/quickshell` were fully
shadowed.

`quickshell` and `libcpptrace1` were repacked into `/root/pkg-archive` first —
neither has a download source. Removal took 17 packages in all.

**Nix's quickshell never restarted through any of it**: still MainPID 3923,
`NRestarts=0`, before and after. The bar, panels and notifications kept
working because the process serving them was never the one being removed.

### The in-use check had a hole, and this is where it was found

Phase 2's safety rested on a check described in this document as systematic:
walk every running process, resolve every mapped file and executable to its
owning package, intersect with the removal list.

It could only read *my own* processes.

```
processes running as root:     308
processes running as isutton:  109
```

`/proc/<pid>/maps` is unreadable for another user's process, so the check
covered about a quarter of the running system. It found `bluez` — but via
`mpris-proxy`, which runs as the user. `bluetoothd` itself, running as root,
was invisible to it. Had `bluez` had only root-owned processes, the check
would have reported it unused and it would have been swept.

The corrected method unions two sources: `/proc` maps and `exe` for readable
processes, plus the first field of `ps -eo args` for every process regardless
of owner, resolved through `dpkg -S`. That made **26 packages newly visible**,
among them `greetd`, `polkitd`, `network-manager`, `udev`, `udisks2`,
`upower`, `wpasupplicant`, `cups-daemon`, `docker-ce` and `rtkit`.

None of the 26 were in Phase 2's sweep, so its outcome stands. But it stood on
the hand-written must-not-appear list, not on the check that was presented as
replacing the need for one. The measurement that was supposed to end the
guessing had the guessing built into it.

The corrected check found exactly one in-use package in this phase's sweep:
`accountsservice`. Running, but consumed by nothing — no installed
reverse-dependency, no `org.freedesktop.Accounts` reference in `greetd` or
`tuigreet`, none in the quickshell tree — and reversible from trixie.

## Phase 5: xkbcommon back to a maintained version

Every number was re-measured rather than carried from the spec, because 1035
packages had been removed since it was written:

```
xkbcommon dependants:        27   (was 42)
strongest constraint:        >= 1.0.0   (kitty, foot, deskflow)
trixie offers:               1.7.0-2
compositor links:            /nix/store/…-libxkbcommon-1.13.1/lib/libxkbcommon.so.0.13.1
```

The compositor is immune, so the blast radius was apt applications only:
Chrome, 1Password, Bitwarden, deskflow, foot, syncthingtray.

Repacked first — `1.13.1-1~bpo13+1` exists only in `/var/lib/dpkg/status`, so
the repack is the only route back up. The simulation showed two downgrades and
no removals. Typing was tested in the affected applications, then again after
a reboot.

### The endpoint

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' | awk '$1=="ii"' | grep -c 'bpo13'
0
$ grep -rl backports /etc/apt/sources.list /etc/apt/sources.list.d/
(no output)
```

**Zero backports packages, and no backports source to reintroduce them.**

That check is worth one note. The first version of it piped `grep` into `sed`
and relied on `||` to report success, which never fired: `sed` exits 0 and
masks `grep`'s exit status, so an empty result and a broken pipeline look
identical. Counting explicitly is what actually establishes the zero. A check
that reports success by printing nothing cannot distinguish success from not
having run — the same fault as `pgrep -x fumon` in spec 6, in a new costume,
in the final verification of the spec that spent its length on it.

## Did it work?

| Question | Before | After |
|---|---|---|
| Installed packages | 3256 | **2221** — 1035 removed |
| Manually-installed | 519 | **373** |
| Backports packages | 4 | **0**, with no backports source to reintroduce them |
| `apt-get -s autoremove` | 0, then 466 after Phase 1 | **0** |
| What serves FileChooser | Debian's `xdg-desktop-portal-gtk` | Nix's, at `~/.config/systemd/user`, 0 `/usr` code mappings |
| Backend selection | accidental — `gtk.portal` won as a fallback under `UseIn=gnome` | declared in `hyprland-portals.conf` |
| Portal backends registered | 6 (gtk, kde, kwallet, lxqt, gnome-keyring, hyprland) | 3 — gtk and hyprland from Nix, gnome-keyring from apt |
| KDE daemons running | `kwalletd6`, `kdeconnectd` | none, and no KDE installed |
| `fc-match` for the three generic families | Debian's `fonts-noto-core` and `fonts-dejavu-mono` | the Nix store |
| xkbcommon | `1.13.1-1~bpo13+1`, unmaintainable | `1.7.0-2` from trixie, maintained |

Every row is a win, with one qualification worth stating: the reduction is
larger than the spec authorised. Phase 1 orphaned a 466-package language stack
the spec had explicitly placed out of scope, and the decision to sweep it was
taken mid-execution rather than at design time.

## Every defect, and who owns it

### The portal config filename would never have been read

**Owner: the spec and the plan. Caught by the Task 1 review, before it shipped.**

Covered under Phase 3a. `XDG_CURRENT_DESKTOP=Hyprland` was measured correctly;
the conclusion that the file should therefore be `Hyprland-portals.conf` was an
unverified inference laid on top of it. `man 5 portals.conf` says the name is
lower-cased, and the system's own `lxqt-portals.conf` — under a desktop named
`LXQt` — was sitting there as a worked example the whole time.

Cost if it had shipped: the declared backend selection silently absent, and
every later claim in this document about selection being "declared rather than
accidental" false.

### The gtk D-Bus activation file needed an explicit entry

**Owner: the spec. Caught by the Task 1 review.**

Also under Phase 3a. The reasoning that no `xdg.dataFile` entry was needed
explained which binary runs *once D-Bus decides to activate*, and said nothing
about whether D-Bus can find an activation file at all. The two are different
questions read by different processes under different environments.

The measurement that produced the wrong answer read `XDG_DATA_DIRS` from a
process found by matching a name pattern, rather than from the process systemd
reports as the session bus.

Cost if it had shipped: file dialogs in Chrome and Code stop opening at
Phase 3b, three phases after the cause.

### `kwallet6` was in the wrong task, and a daemon check was in the wrong step

**Owner: the plan. Caught by the pre-flight scan, before Task 1 dispatched.**

`/usr/bin/kwalletd6` comes from `kwallet6`, which the KDE autoremove sweep does
not pick up on its own — so Phase 2 would have finished claiming both KDE
daemons were gone while one remained installed. And removing a package does not
kill its running process, so the daemon-absence check could only ever pass
after the reboot, not before it.

### The plan predicted 0 autoremovable packages after Phase 1. There were 466.

**Owner: the plan. Caught by running it.**

Covered under Phase 1. The consequence was not the wrong number but the wrong
scope: Phase 2's bare `apt autoremove` would have swept a language stack the
spec had excluded, inside a task named for KDE.

### The in-use check covered a quarter of the system

**Owner: me, during execution. Caught two phases after I relied on it.**

Covered under Phase 4. The check that was introduced *specifically to stop this
project guessing at package names* could not read root-owned processes — 308 of
them against 109 readable. It found `bluez` by luck, through a user-owned
helper process.

This is the most instructive defect in the spec, because it was not inherited
from a plan or a premise. It was built during execution, in direct response to
the recurring failure, and reproduced the failure inside the fix.

### `bluez` was one command away from being swept

**Owner: the plan, which had no step for this. Caught by inspection, then confirmed by measurement.**

`bluetoothd` runs from it, `bluetooth.service` was active, and the flake's own
`bt-agent.service` runs against that daemon. It was in the sweep only because
it is marked `auto` and its last installed reverse-dependency is
`libreoffice-impress`.

**`bluez` cannot move to Nix.** It runs as root from
`/usr/lib/systemd/system/bluetooth.service` — a system unit. Standalone Home
Manager writes `~/.config/systemd/user` only. This is permanent, and it is
recorded here so a later cleanup does not re-open it.

### The final verification reported success by printing nothing

**Owner: me. Caught immediately, by re-running it differently.**

Covered under Phase 5. `grep | sed` with `|| echo "zero"`: `sed` exits 0 and
masks `grep`'s status, so an empty result and a broken pipeline are
indistinguishable. Counting explicitly is what establishes the zero.

Structurally identical to spec 6's `pgrep -x fumon`, which also could not
distinguish the two states it existed to distinguish — in the closing check of
the spec that spends its length on exactly this fault.

## The recurring defect, counted again

Spec 6 recorded five instances and named the pattern: *a check that measures a
proxy because the proxy is easier to reach than the property.* Spec 7 produced
six more, and the shape has moved again.

Spec 5's instances were in the catalogue. Spec 6's were in the verification.
Spec 7's are in **the verification of the verification** — the filename
inference on top of a correct measurement, the `/proc` walk that could not see
three-quarters of the system, and a zero established by an empty line.

The pattern that actually held every time: **a measurement was taken, and then
a conclusion was drawn that the measurement did not support.** Not laziness —
every one of these involved running a real command and reading real output. The
failure was in the step after.

What worked, consistently: checks that read a running process's own state.
`/proc/<pid>/maps`, `/proc/<pid>/cmdline`, `NRestarts`, `MainPID`, `busctl`
name ownership. Every one of those told the truth. Every check that compared a
path, a name, or an exit code eventually didn't.

## What is still true

### The apt desktop that remains

373 manually-installed packages, 2221 total. The desktop-relevant survivors:

- **The corp five**, permanently: `google-chrome-stable`, `code`, `1password`,
  `1password-cli`, `endpoint-verification`.
- **`bluez`**, permanently and for a structural reason, now marked manual.
- **`gnome-keyring`**, the live Secret provider.
- **`xdg-desktop-portal`** — the portal *frontend*, still Debian's `1.20.3`,
  now the only mixed component in the portal stack.
- **~21 GUI applications** awaiting their own spec: `firefox-esr`,
  `signal-desktop`, `bitwarden`, `kitty`, `emacs-lucid`, `thunar`,
  `pcmanfm-qt`, `virt-manager`, `displaycal`, `isoimagewriter`, `seahorse`,
  `flatseal`, `syncthingtray`, `deskflow`, `bat`, `chafa`, `yt-dlp`, `mise`,
  `sbcl`, `shellcheck`, `foot`.

`foot` on that list is worth a note: the flake provides `foot` too, and
`/usr/bin/foot` is what runs. Another shadow nobody has resolved.

### One file outside `$HOME`

```
$ ls /usr/local/share/wayland-sessions/
hyprland-nix.desktop
```

Still the only one, and `/etc/pam.d/greetd` was deliberately not edited — the
`-auth optional` / `-session optional` prefixes made the dead `pam_kwallet5.so`
lines inert, and editing a dpkg conffile would have been the worse outcome.
That decision was tested by a reboot: greetd logged in with no PAM errors.

## What the next spec inherits

**The portal frontend is now the only mixed piece.** Debian's `1.20.3` drives
two Nix backends. nixpkgs has `1.22.1`. That is a real version change, it owns
systemd units rather than a D-Bus service file alone, and it sits in the path
of every portal call including the corp applications'. It is the obvious next
spec, and it is now the *last* thing standing between the session and being
entirely Nix's.

**Audio is a strong second.** `pipewire` (3042), `pipewire-pulse` (3047) and
`wireplumber` (3046) all run as **user** services from Debian units at
UnitPath position 15 — the exact shape `home/uwsm.nix` already solves, and
Nix's `wireplumber-0.5.14` is already on the session PATH. Deferred here
because it is a migration rather than a reduction, the failure mode is "no
audio", and PipeWire's A2DP path couples to `bluez`, which stays on apt.

**The unmanaged 218 MB of fonts.** 101 hand-copied files at
`~/.local/share/fonts/calango-desktop`, live in fontconfig, shadowing the
flake's own `adwaita-fonts`. The largest artefact in `$HOME` that neither apt
nor Nix owns.

**82 dictionary packages** nobody has justified, untouched by this spec.

**119 packages in `rc` state** — removed, config files retained. Harmless, but
it is the residue of three specs of removals and nobody has looked at it.

**`/run/opengl-driver`** remains parked and unestablished.

**The rollback rule, extended again.** A previous Home Manager generation was
already not a recovery path after spec 6. It now additionally supplies the gtk
portal backend, the portal configuration, and the font baseline.
