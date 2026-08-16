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
