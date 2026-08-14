# calango-nix spec 4: the rest of the user layer

Ports every remaining calango-desktop link to Nix, leaving apt nothing in the
user's home. After this, only the system layer is left: removing
`trixie-backports`, deleting the `nixtest` account, and solving the PAM problem
that blocks Nix's hyprlock.

## What specs 1-3 established that this spec depends on

- **nixGL is required for every Nix GUI application.** Four binaries have now
  needed it. Nothing in this spec draws through GL — foot uses wayland shm, lf
  is a terminal program, gammastep speaks wlr-gamma-control — so this spec
  should need no new wrapping. If something here fails to create a GL context,
  the wrapper is the first thing to reach for and the fact that it was needed
  is worth recording.
- **The source/state split.** Store trees are read-only; anything written at
  runtime lives under `~/.local/state`. `home/quickshell.nix` and
  `home/hyprland.nix` both implement it.
- **`calango.host`** is a Home Manager option carrying the hostname, resolved at
  *build* time. Spec 3 introduced it to replace `hyprland.lua`'s
  `/etc/hostname` read. This spec reuses it for foot and for GTK.
- **`Paths.qml`** is the quickshell singleton holding `stateDir`, `sourceDir`
  and `hyprStateDir`. `hyprStateDir` deliberately ignores `XDG_STATE_HOME`, so
  that quickshell writes where the compositor was told at build time to read.
- **Closures are derived, not transcribed.** Spec 2 shipped a closure table and
  it was missing six packages. Spec 3 refused to ship one and its sixteen
  packages were right first time. That is the only enumeration in three specs
  that was correct on the first attempt.

## The inventory, and where it came from

`install.sh` places twenty things through parallel `LINK_SRC`/`LINK_DST` arrays.
Reading those arrays is the authority for this spec; the file tree is not.
Three are done and one is being dropped, which leaves sixteen:

| # | Source | Destination | Status |
|---|---|---|---|
| 1 | `quickshell/` | `~/.config/quickshell` | spec 2 |
| 2 | `hypr/` | `~/.config/hypr` | spec 3 |
| 3 | `hypr/systemd/quickshell.service` | user units | spec 2 |
| 4 | `kitty/` | `~/.config/kitty` | **dropped** |
| 5 | `foot/` | `~/.config/foot` | this spec |
| 6 | `lf/` | `~/.config/lf` | this spec |
| 7 | `uwsm/` | `~/.config/uwsm` | this spec |
| 8 | `gtk/apply-gtk-theme` | `~/.local/bin/` | this spec |
| 9 | `bin/calango-open` | `~/.local/bin/` | this spec |
| 10 | `bin/code` | `~/.local/bin/` | this spec |
| 11 | `network/nm-secret-agent` | `~/.local/bin/` | this spec |
| 12 | `data/eu.calangotech.CalangoOpen.desktop` | `~/.local/share/applications/` | this spec |
| 13 | `data/code.desktop` | `~/.local/share/applications/` | this spec |
| 14 | `autostart/im-launch.desktop` | `~/.config/autostart/` | this spec |
| 15 | `autostart/org.kde.xwaylandvideobridge.desktop` | `~/.config/autostart/` | this spec |
| 16 | `pipewire/20-block-source-volume.conf` | `~/.config/pipewire/pipewire-pulse.conf.d/` | this spec |
| 17 | `hypr/systemd/quickshell.service.d/killmode.conf` | user units | this spec |
| 18 | `hypr/systemd/bt-agent.service` | user units | this spec |
| 19 | `hypr/systemd/nm-secret-agent.service` | user units | this spec |
| 20 | `hypr/systemd/night-light.service` | user units | this spec |

`install.sh` also performs four actions that are not links, and all four must be
accounted for or they will be lost silently:

- `xdg-settings set default-web-browser eu.calangotech.CalangoOpen.desktop`
- generating `foot/host.ini`, the per-host include
- `touch foot/theme-colors.ini`, because foot treats a missing `include` target
  as fatal
- writing a `.stignore` block into the Syncthing folder root

## The starting state, measured

`isutton`'s home was checked rather than assumed, and calango-desktop is **not
currently installed** there:

- `~/.config/foot`, `~/.config/lf`, `~/.config/uwsm` — absent
- `~/.local/bin` — holds `calango`, `claude`, `cl-mirror`; none of this repo's
  shims
- `~/.config/autostart` — five entries, none of them ours
- `~/.config/pipewire/pipewire-pulse.conf.d/` — exists, empty
- user units — `hypridle`, `hyprpolkitagent`, `quickshell`, `tray.target`, all
  from Home Manager; no `bt-agent`, `nm-secret-agent` or `night-light`

Two consequences. First, there is no collision to manage: nothing this spec
creates has to displace an existing symlink. Second, these are not parity
exercises — each one is a capability the session does not currently have.

Two of those gaps are visibly live right now:

- **`ibus-daemon` is running** (pid 142707), because `/etc/xdg/autostart/im-launch.desktop`
  exists and the `Hidden=true` stub that switches it off does not. `uwsm/env`'s
  `unset GTK_IM_MODULE QT_IM_MODULE` is missing for the same reason.
- **The default browser is `eu.calangotech.KBrowserSelector.desktop`**, a stale
  root-owned entry in `/usr/share/applications` dated May 19 — not this repo's
  handler, and not something this repo installed.

## Decisions

1. **kitty is dropped, not ported.** `hyprland.lua` already routes both SUPER+Q
   and SUPER+E to foot, which draws sixel where kitty does not. kitty survived
   in calango-desktop only for the live palette it can push over its control
   socket. Porting it costs a config tree, two theme files, a `geninclude`
   shell script and a second state file, to keep a terminal nothing launches.
   `Theme.qml`'s `applyKittyTheme` and its socket loop are deleted rather than
   rewritten. Reversible: the files remain in calango-desktop's history.

2. **GTK keeps `apply-gtk-theme`; Home Manager's `gtk.*` module stays off.**
   The module would own `~/.config/gtk-{3,4}.0/settings.ini` as read-only store
   symlinks — the exact files `apply-gtk-theme` writes. Letting the store own a
   file that something else writes is the defect that has bitten this project
   four times. Instead a `home.activation` hook runs the script at every
   `home-manager switch`, replacing `make gtk`: declarative intent, mutable
   state.

3. **The default browser is set by activation, not declared.**
   `~/.config/mimeapps.list` holds eleven associations, six of which
   (slack, bitwarden, claude-cli, signal ×2) are nothing to do with this repo.
   `xdg.mimeApps` would require transcribing all of them — an enumeration
   this project keeps getting wrong — and would freeze the file, so no
   application could ever set a default again. The hook runs `xdg-settings`
   and leaves the file writable.

4. **`.desktop` entries go to `~/.local/share/applications`, not the profile.**
   Spec 1 proved `~/.nix-profile/share` works for `wayland-sessions` via
   `XDG_DATA_DIRS`. It does not follow for MIME handling: a `.desktop` only
   receives a URL handoff if a `mimeinfo.cache` in the same directory lists it,
   and Home Manager builds no such cache for the profile's `applications`
   directory. `xdg.dataFile` plus `update-desktop-database` matches what
   `install.sh` did and is the mechanism known to work here.

5. **Both `.desktop` entries get absolute store paths in `Exec=`.**
   `Exec=calango-open %u` is a bare name today, which works only because
   `uwsm/env` puts `~/.local/bin` on the systemd user manager's PATH for
   xdg-desktop-portal to inherit. Baking the store path removes that
   dependency, and with it the main reason `uwsm/env` exists.

6. **`uwsm/env` shrinks to the input-method unset.** Its PATH block served
   `~/.local/bin`, which after decision 5 holds nothing this repo needs. The
   `unset GTK_IM_MODULE QT_IM_MODULE` block stays, and is the whole file.

7. **`killmode.conf` is folded into `quickshell.service`.** A drop-in exists to
   patch a unit you do not control. Home Manager generates this one, so
   `KillMode = "process"` goes directly on it.

8. **The Syncthing `.stignore` block is dropped.** `~/Projects` is a Syncthing
   folder and calango-nix sits inside it, so the mechanism's premise still
   holds — but its purpose does not. It existed because runtime state was
   written *into* the repo; specs 2 and 3 moved all of it to
   `~/.local/state`, and this spec adds no repo-resident state. There is
   nothing left to ignore.

9. **`bluez-tools` and `gammastep` come from nixpkgs.** Both are apt-installed
   today and both are named by bare command in their units. Absolute store
   paths are what makes a unit self-contained, and it costs two apt packages
   to remove.

## Non-goals

- **Removing `trixie-backports`.** That is the next spec, and it is still
  blocked on Nix's hyprlock failing PAM authentication against Debian's
  `/etc/shadow`. See `docs/2026-08-14-results-suffer-hyprland.md`.
- **Deleting the `nixtest` account.** It is the only safe place to test a lock
  screen, and the PAM work will need it.
- **`greetd/config.toml`.** Root-owned system configuration, not the user layer.
- **`packaging/`, `Makefile`, `install.sh`, `tests/`.** calango-desktop's own
  build and install machinery. Nix replaces it rather than porting it.
- **Removing VS Code from apt.** It comes from Microsoft's repository, not
  backports, so it blocks nothing. `bin/code` continues to exec
  `/usr/share/code/bin/code` by absolute path.
- **Home Manager's `gtk.*` module.** Decision 2.
- **Any change to what the configs *say*.** This is a port. foot's keybindings,
  lf's mappings and the GTK values are carried across unchanged. The only
  edits are the ones the store's read-only nature forces.

## Design

### 1. Repository layout

Config trees are forked into calango-nix the way `hypr/` and `quickshell/`
were, and each gets a focused Nix module:

```
foot/{foot.ini,hosts/{epiphany,suffer}.ini,themes/monokai-pro.ini}
lf/{lfrc,colors,icons,preview}
uwsm/env
gtk/{apply-gtk-theme,appearance.conf,hosts/{epiphany,suffer}.conf}
bin/{calango-open,code}
data/{eu.calangotech.CalangoOpen.desktop,code.desktop}
autostart/{im-launch.desktop,org.kde.xwaylandvideobridge.desktop}
pipewire/20-block-source-volume.conf
network/nm-secret-agent

home/foot.nix      foot's derivation, its state contract, its xdg.configFile
home/lf.nix        lf's derivation and previewer closure
home/gtk.nix       apply-gtk-theme, appearance values, the activation hook
home/apps.nix      shims, .desktop entries, autostart, pipewire, uwsm/env
home/services.nix  bt-agent, night-light, nm-secret-agent
```

`epiphany`'s host files are carried across even though this machine is
`suffer`. They cost nothing, and dropping them would silently make the port
lossy for the other machine.

### 2. Placement, per item

Five mechanisms, chosen per item rather than uniformly. This is the first spec
that puts Nix-owned files under `~/.config` at all: quickshell takes `-p` and
Hyprland takes `--config`, so specs 2 and 3 needed no XDG paths. Most of this
spec's consumers have no such flag.

**`home.packages`** — `apply-gtk-theme`, `calango-open`, `code`,
`nm-secret-agent`. All four land in `~/.nix-profile/bin` and are referenced by
absolute store path everywhere it matters.

**`xdg.dataFile`** — the two `.desktop` entries, per decision 4.

**`xdg.configFile`** — `foot/` and `lf/` as directory symlinks to their
derivations, plus `uwsm/env`.

**`xdg.configFile`, individual files** — the two autostart stubs and the
pipewire drop-in. `~/.config/autostart` holds five entries that are not ours
and `pipewire-pulse.conf.d` is a directory distribution packages also write
into. Linking either tree would hide their contents. `install.sh` made exactly
this point in a comment; it is repeated here because the tree-vs-file choice is
invisible in the result until something goes missing.

**`systemd.user.services`** — the three units, section 6.

**`home.activation`** — three hooks, section 7.

### 3. The state contract

Dropping kitty leaves exactly one runtime-written file in this spec's scope.
The "missing" column is the one spec 3's `hyprlock.conf` defect would have
caught, so it is here from the start:

| File | Written by | Read by | If missing |
|---|---|---|---|
| `~/.local/state/foot/theme-colors.ini` | `Theme.qml` `applyFootTheme` | `foot.ini` `include=` | **foot refuses to start** |

Because a missing include is fatal, the file must exist before foot's first
start. An empty file is a valid foot config; `install.sh` relied on the same
fact.

**It must not be created with `home.file`.** That would make it a symlink into
the store, and `Theme.qml` writes it with `printf > …`, which fails on a
read-only store path. Spec 2's `.keep` pattern does not transfer here: a
`.keep` is a store symlink whose only job is to force the parent directory into
existence, and nothing ever writes to it. This file is written on every theme
switch.

So the two halves are created differently: `home.file` seeds
`~/.local/state/foot/.keep` to create the directory, and an activation step
does the equivalent of `[ -e "$f" ] || : > "$f"` to create the file itself —
never clobbering one that already holds a palette.

There is no equivalent for lf, uwsm, GTK, autostart or pipewire: none of them
is written at runtime. `~/.config/gtk-{3,4}.0/settings.ini` and `~/.gtkrc-2.0`
*are* written at runtime, by `apply-gtk-theme` — which is exactly why decision
2 keeps them out of the store entirely rather than listing them here.

### 4. Resolved at build time

Three things `install.sh` computed at install time become build-time values,
using `calango.host`:

- **`foot/host.ini` disappears.** It exists only because foot's `include` takes
  a fixed absolute path — no glob, no environment expansion, no program to run
  — so the installer had to generate a file whose sole content pointed at
  another file. Nix substitutes `include=<store>/hosts/suffer.ini` directly
  into `foot.ini`. When the host has no `hosts/<host>.ini`, **no include line is
  emitted at all**, which is better than `install.sh`'s empty-file fallback:
  there is no file to go stale when the machine is renamed.
- **`lf`'s `set previewer ~/.config/lf/preview`** becomes the store path.
- **`gtk/hosts/<host>.conf`** is sourced at build time and the activation hook
  receives resolved values, replacing `make gtk`'s runtime sourcing.

`foot.ini`'s two other includes — `themes/monokai-pro.ini` and
`theme-colors.ini` — are substituted to the store path and the state path
respectively.

**The token guard.** Spec 3 guards substitution with
`grep -q '@[a-zA-Z]*@'` and that guard must not be broadened: `hyprland.lua`
contains `@DEFAULT_AUDIO_SINK@` and `@DEFAULT_AUDIO_SOURCE@` eight times
legitimately. The new inputs were checked for the same hazard. `foot.ini`'s
`word-delimiters` and `pipe-scrollback` lines are the near-misses and neither
contains an `@`. Any new token must be verified the same way rather than
assumed.

### 5. The cross-spec edit

Spec 2 rewrote nine path references in `quickshell/theme-switcher/Theme.qml`
and left two: the kitty write at line 334 and the foot write at line 394. It
left them correctly — those trees were still apt symlinks at the time. This
spec is what makes them wrong, so this spec fixes them:

- **Delete `applyKittyTheme` and its `kittyProc`** (decision 1), along with the
  call site and the `Process` declaration.
- **Point `applyFootTheme` at the state directory.** `Paths.qml` gains
  `footStateDir`, defined the way `hyprStateDir` is — from `HOME`, deliberately
  **not** honouring `XDG_STATE_HOME`. The reason is identical: `foot.ini`'s
  `include=` is baked at build time as a fixed absolute path, so if quickshell
  honoured `XDG_STATE_HOME` and the compositor could not, quickshell would
  write somewhere foot never reads.

The foot palette itself needs no change. Its `[colors]`-not-`[colors-dark]`
choice and its omission of a cursor colour already straddle foot 1.21 and 1.27,
and that work predates this port — both repositories carry the same comment.

`quickshell/common/qmldir` must list `Paths` already and needs no edit, but the
whole file is re-checked: spec 2 broke nine components by listing one type in a
new `qmldir`, converting an implicit directory import into an explicit
manifest.

### 6. The units

All four `Install.WantedBy = [ "graphical-session.target" ]`. Home Manager
writes the `graphical-session.target.wants` links from that, which retires
`install.sh`'s closing `systemctl --user enable quickshell.service
bt-agent.service night-light.service` — a hand-maintained list that spec 1's
symlink census already caught omitting `nm-secret-agent`. The list cannot drift
from the units again because there is no longer a list.

**`bt-agent`** — `ExecStart` becomes `${pkgs.bluez-tools}/bin/bt-agent -c
NoInputNoOutput`. Today it is a bare name resolving to apt's copy.

**`night-light`** — runs `run.sh` from the quickshell store path. Its PATH
covers gammastep, `systemctl`, and the coreutils and sed the script uses.
It does **not** need curl or jq: `locate.sh` is spawned by quickshell
(`NightLightService.qml:108`), not by `run.sh`, so its geolocation closure
belongs to `quickshell.service`. Spec 2 already placed `curl` and `jq` there
with comments naming `locate.sh`. Putting them in the unit with "night-light"
in its name would look right and leave geolocation silently broken.
`ConditionEnvironment=WAYLAND_DISPLAY` is retained.

**`nm-secret-agent`** — the only real engineering here. It is a PyGObject
program importing `NM 1.0`, `Secret 1` and `GLib`, so it needs
`python3.withPackages [ pygobject3 ]` and a `GI_TYPELIB_PATH`. Both typelibs
were confirmed present in this flake's nixpkgs before the spec was written:
`networkmanager-1.56.0` ships `NM-1.0.typelib` and `libsecret-0.21.7` ships
`Secret-1.typelib`. The unit's `Documentation=` currently points into
`%h/Projects/calango-desktop/docs/`; it is repointed at this repository.

It also requires a working secret service — the login keyring created with
seahorse during spec 1, after `secret-tool store` hung against a missing
default collection. That is a precondition to assert in verification, not
something to discover through a wifi connection failing with what the panel
reports as a wrong password.

**`quickshell.service`** gains `KillMode = "process"` (decision 7).

### 7. The activation hooks

Four, and every one of them must be non-fatal. A failing `home.activation`
block aborts `home-manager switch`, which would make a missing optional tool
break the whole configuration rather than skip a step.

- **foot's state file**, per section 3: create
  `~/.local/state/foot/theme-colors.ini` if it does not already exist. This one
  is load-bearing rather than cosmetic — without it foot does not start at all.

- **GTK.** Runs `apply-gtk-theme` with the resolved `appearance.conf` values.
  The script needs `gsettings`; Nix's `glib` build requires
  `GSETTINGS_SCHEMA_DIR` pointing at `gsettings-desktop-schemas` to resolve
  `org.gnome.desktop.interface`. Nix's copy is preferred for self-containment —
  both write the same dconf database — with `/usr/bin/gsettings` as the
  documented fallback if the schema versions disagree. `xrdb` is optional in
  the script and stays optional.
- **Default browser.** `xdg-settings set default-web-browser
  eu.calangotech.CalangoOpen.desktop`, recording the previous value first, as
  `install.sh` did. This is what displaces the stale `KBrowserSelector` entry.
- **`update-desktop-database`** against `~/.local/share/applications`, without
  which the entry from the previous hook is not discoverable.

### 8. Deriving the closures

The rule from spec 3 applies unchanged, and this spec deliberately ships **no
closure table**. The implementation derives each list by reading the scripts,
over-inclusively first and then classified by hand. Four closures are needed:

- `lf`'s previewer and `lfrc`
- `apply-gtk-theme`
- `calango-open`
- `night-light.service`

Spec 3 recorded a fifth static-extraction failure mode while doing this: bare
function-parameter words with no shell-operator prefix are invisible to a
grep-based extractor, which is how `lf` and `sh` were found only by reading the
file. Expect the extractor to be wrong and read the files.

`calango-open` needs specific care. It references
`$HOME/.config/quickshell/browser/discover.py`, which is now a store path, and
it calls `qs` — which needs `QS_CONFIG_PATH` to reach the running instance, the
defect that left every `qs ipc call` bind dead from spec 2 until spec 3 found
it. A shim invoked by the portal does not inherit the compositor's environment,
so it must not assume that variable is set.

### 9. Verification

Everything except the units and the autostart stubs can be checked in the
running session. Budget **one logout**.

Live:

- `foot --print-pid` starts with the new config; `foot -c` is not used, so this
  also proves `~/.config/foot` resolves
- a theme switch writes `~/.local/state/foot/theme-colors.ini` and a **newly
  opened** foot shows the palette (foot has no config reload; existing windows
  keep their colours by design, not by fault)
- `lf` starts and its previewer renders an image, a PDF and a text file —
  covering chafa, pdftoppm and bat in one pass
- `apply-gtk-theme --check` reports the pinned values
- `xdg-settings get default-web-browser` returns
  `eu.calangotech.CalangoOpen.desktop`, and clicking a link from a non-Nix
  application reaches the picker
- `code` typed in a terminal resolves to the shim, and the shim's absolute exec
  target exists
- `systemctl --user start` each of the three new units and read the journal

After logout:

- `ibus-daemon` is **not** running, and `systemctl --user show-environment`
  contains neither `GTK_IM_MODULE` nor `QT_IM_MODULE`
- the three units are active under `graphical-session.target`
- `pactl` shows the chrome source-volume quirk applied
- zero `command not found` in the journal after real use — the gate spec 3 used

Two version jumps get an explicit check rather than an assumption: **lf 34 → 41**
and **foot 1.21 → 1.27**. Both are major moves onto config files written for
the older release.

## Open items

- **The GTK activation hook runs on every switch.** If `apply-gtk-theme` is
  slow or noisy this becomes irritating quickly. Making it conditional on the
  values having changed is a refinement, not a requirement, and is deliberately
  not designed here.
- **`org.kde.xwaylandvideobridge.desktop` is a no-op on `suffer`.** There is no
  `/etc/xdg/autostart` entry for it on this machine, so the stub disables
  nothing. It is ported for `epiphany`'s benefit and because dropping it would
  make the port quietly lossy.
- **Nix's `gsettings` versus Debian's** is decided but not proven. Both write
  the same dconf database and the six keys involved are old and stable, but
  `gsettings-desktop-schemas-50.1` is not the version Debian 13 ships.
- **`bluez-tools` in nixpkgs is `0-unstable-2020-10-24`.** That is upstream's
  actual state rather than a packaging lapse — Debian's
  `2.0~20170911.0.7cb788c-4+b1` is a snapshot of the same stalled project — but
  the two are different snapshots. If `bt-agent` misbehaves, keeping apt's copy
  is the fallback and costs one apt package.
