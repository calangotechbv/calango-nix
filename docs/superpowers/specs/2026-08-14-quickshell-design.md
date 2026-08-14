# calango-nix spec 2: quickshell from Nix

**Goal:** Run calango-desktop's quickshell — the bar, launcher, notifications,
OSD and panels — from Nix on `suffer`, owned by Home Manager, with its
runtime-written state somewhere Home Manager does not manage.

**Depends on:** spec 1, `docs/superpowers/specs/2026-08-14-base-and-session-design.md`,
and its results in `docs/2026-08-14-results-suffer-nix-session.md`.

## What spec 1 established that this spec depends on

Three findings, all earned the hard way, and all load-bearing here.

**A Nix GUI application does not draw without `nixGL`.** The compositor dies in
`CBackend::create()` looking for `/run/opengl-driver/lib`, a path that exists
on NixOS and nowhere else.

**Wrapping the compositor does nothing for a systemd user unit.** A unit runs
whatever `ExecStart` names. `hyprpolkitagent` was `active (running)` and still
aborted with `status=6/ABRT` the instant polkit asked it to draw, because the
home-manager module named the bare store binary. quickshell is Qt6 exactly as
that agent is, and it is started the same way.

**Nothing puts `~/.nix-profile/bin` on `PATH`.** Debian's `nix-bin` ships no
`/etc/profile.d/nix.sh`, and Home Manager's `hm-session-vars.sh` sets only
`LOCALE_ARCHIVE_2_27`. A unit therefore gets a minimal `PATH`, and every bare
command name in the QML is a runtime failure waiting to happen.

The first two mean the unit must be wrapped. The third means its `PATH` must be
explicit. Neither is optional and neither fails at build time.

## Decisions

**1. quickshell comes from nixpkgs 26.05.** It is 0.3.0 there. Verified
present before this spec was written, which retires the largest feasibility
question spec 1 left open.

**2. The tree is hand-forked into calango-nix.** The 86 source files are copied
into `calango-nix/quickshell/` and the paths edited in place. From that moment
calango-nix owns this code and calango-desktop's copy is stale.

One file is the exception and cannot be hand-edited: see "The rewrite surface"
below. `theme-switcher/wallpaper-theme/matugen/config.toml` needs a store path
that does not exist until build time, so the derivation generates it.

This was chosen over two alternatives. A build-time `substituteInPlace` with
`--replace-fail` would have kept divergence visible and auditable, the same
technique as spec 1's polkit fix. Changing calango-desktop first to honour
`$XDG_STATE_HOME` would have let both sessions share one state directory
during the migration. Both were rejected in favour of a clean ownership
transfer: calango-desktop is being retired, and neither a patch mechanism nor
an upstream fix earns its keep in a repository with a known end date.

The cost is real and is accepted: there is no mechanical signal when the two
repositories drift, and no way to tell an intentional divergence from an
accidental one.

**3. Source and state are split.** The QML lives read-only in the store. The
eleven runtime-written files move to `~/.local/state/quickshell/`.

This is forced. Home Manager links `home.file` targets as read-only
`/nix/store` symlinks, and the QML writes into its own configuration directory
through shell subprocesses:

```qml
saveProc.command = ["sh", "-c",
  'printf "%s" "$1" > "$HOME/.config/quickshell/theme.conf"', "sh", String(index)];
```

Under Home Manager every such reference fails. The alternative — a directory
half store-symlinks and half mutable files, with the QML untouched — was
rejected because it leaves state in `~/.config` and makes the directory's
ownership impossible to reason about.

**4. The unit is ours.** Home Manager has no quickshell module, so
`systemd.user.services.quickshell` is written by hand, mirroring
`calango-desktop/hypr/systemd/quickshell.service` and its reasoning, with two
changes forced by the findings above: the `ExecStart` goes through `nixGLIntel`,
and `PATH` is set explicitly.

**5. `swaybg`, not `swww`.** Spec 1 left "`swww` in nixpkgs" open. The question
dissolves on reading `wallpaper/WallpaperService.qml`, which already prefers
`swww` when present and falls back to `swaybg`, noting in its own comments that
Debian ships only the latter. `swaybg` 1.2.2 is in nixpkgs. No wrapper, no
packaging work, no open item.

**6. Nix is an upgrade for the theme switcher.** `matugen` and `wallust` are
cargo installs on Debian. nixpkgs has 4.0.0 and 3.5.2. This is the first place
where moving to Nix removes work rather than adding it.

## Non-goals

- The Hyprland configuration. `hyprland.lua` is 56KB of Hyprland's native Lua
  format and is spec 3.
- The terminals, `lf`, and the GTK theming. Spec 4.
- `night-light.service`, `nm-secret-agent.service`, `bt-agent.service`. Spec 5.
- Removing `trixie-backports` and deleting `nixtest`. Spec 6.
- Any change to the calango-desktop repository. Unchanged from spec 1, and
  reaffirmed by decision 2.

## Design

### 1. Repository layout

```
~/Projects/calango-nix/
  quickshell/            86 source files, forked from calango-desktop
    shell.qml
    bar/ network/ settings/ clipboard/ osd/ bluetooth/ …
    theme-switcher/wallpaper-theme/{matugen,wallust}/
    night-light/{locate.sh,run.sh}
    browser/discover.py
    wallpaper/generate-abstract.py
  home/
    quickshell.nix       the derivation, the unit, the runtime closure
```

The five `dev-*.qml` files are not ported. They are development probes, they
are `dev` tier in calango-desktop's own terms, and nothing at runtime loads
them.

### 2. The state contract

Eleven files, of which seven exist today. Home Manager manages **none** of
them; managing one would make it a read-only symlink and reintroduce the
problem this spec exists to solve.

| File | Present | Written by |
|---|---|---|
| `theme.conf` | yes | theme switcher |
| `wallpaper.conf` | yes | wallpaper service |
| `bar.conf` | yes | bar settings |
| `night-light.conf` | yes | night-light panel |
| `night-light-location.conf` | yes | `night-light/locate.sh` |
| `notification-history.json` | yes | notification service |
| `.previous-browser` | yes | browser selector |
| `theme-switcher/wallpaper-theme.json` | no | theme switcher |
| `bluetooth-adapter.conf` | no | bluetooth panel |
| `main-monitor.conf` | no | monitor settings |
| `browser.json` | no | browser selector |

Home Manager's only involvement is ensuring the directory and its
`theme-switcher/` subdirectory exist, through `.keep` entries that force real
parent directories. The QML writes with a bare `printf > path` and never
calls `mkdir`, so a missing directory is a silent failure rather than an
error.

The seven existing files are seeded once, as a step in the implementation
plan. Not an activation script: activation runs on every switch, and a
seed-if-absent guard is a silent no-op indistinguishable from a working one.
A plan step can be checked once and seen to have worked.

Rebuilds and rollbacks move the QML and never touch state. That is the design
working, not a gap in it.

### 3. The rewrite surface

Seventeen live references, in four languages, across twelve files. Counting
only the QML would miss seven of them, and each miss is a silent write
failure rather than an error.

| Form | Count | Where |
|---|---|---|
| `$HOME/.config/quickshell` | 13 | 6 QML files, `night-light/{locate,run}.sh` |
| `~/.config/quickshell` | 4 | `browser/discover.py`, `matugen/config.toml` ×2, `wallust/wallust.toml` |
| `~/.config/quickshell` in a comment | 1 | `theme-switcher/wallpaper-theme/set.sh` |

The QML references break down as `theme-switcher/Theme.qml` ×4,
`notifications/NotificationService.qml` ×2, and one each in
`bluetooth/BluetoothService.qml`, `common/BarSettings.qml`,
`common/Screens.qml` and `wallpaper/WallpaperService.qml`.

Two of these are not our code's paths at all. `matugen` and `wallust` are
third-party binaries reading their own TOML, so no amount of QML editing
reaches them:

```toml
# matugen/config.toml
input_path  = '~/.config/quickshell/theme-switcher/wallpaper-theme/matugen/template.json'
output_path = '~/.config/quickshell/theme-switcher/wallpaper-theme.json'
```

**The split is not one-directional, and this file proves it.** `input_path`
reads a template that is source, so it must follow the source into the store.
`output_path` writes the generated theme, so it must follow state to
`~/.local/state`. Two lines apart, in the same file, pointing opposite ways.

Because the store path is not known until build time, this file cannot be
hand-edited the way the rest of the tree is. The derivation generates it,
interpolating its own `$out`. `wallust.toml`'s `quickshell.target` writes to
the same state file and is a plain edit.

### 4. The unit, in sketch

Not the implementation. It fixes the two things spec 1 proved are easy to get
wrong.

```nix
systemd.user.services.quickshell = {
  Unit = {
    Description = "Quickshell shell";
    PartOf = [ "graphical-session.target" ];
    After = [ "graphical-session.target" ];
    ConditionEnvironment = "WAYLAND_DISPLAY";
  };
  Service = {
    ExecStart = "${nixglWrap "quickshell" "${pkgs.quickshell}/bin/quickshell"} -p ${config}";
    Environment = [ "PATH=${lib.makeBinPath runtimeDeps}" ];
    Restart = "on-failure";
    RestartSec = 2;
    Slice = "app.slice";
  };
  Install.WantedBy = [ "graphical-session.target" ];
};
```

`-p` takes a QML file or a config directory and is the documented way to run a
config from outside `$XDG_CONFIG_HOME`; `QS_CONFIG_PATH` is the equivalent
environment variable. The `nixglWrap` helper already exists in
`home/default.nix`, added for `hyprpolkitagent`.

`ConditionEnvironment=WAYLAND_DISPLAY` is carried over deliberately. The
original unit's comments explain at length that under `uwsm` the race it once
guarded against cannot happen, and that it remains as a statement of what the
unit needs. That reasoning holds here.

### 5. Runtime closure

Everything the QML invokes, by bare name, and therefore everything that must
be on the unit's `PATH`.

| Package | Version | Used by |
|---|---|---|
| `quickshell` | 0.3.0 | the shell |
| `brightnessctl` | 0.5.1 | OSD, brightness keys |
| `cliphist` | 0.7.0 | clipboard picker |
| `wl-clipboard` | 2.3.0 | clipboard picker |
| `swaybg` | 1.2.2 | wallpaper |
| `glib` | 2.88.1 | `gsettings` |
| `libnotify` | 0.8.8 | notifications |
| `jq` | 1.8.2 | theme switcher, night light |
| `matugen` | 4.0.0 | wallpaper-derived theming |
| `wallust` | 3.5.2 | wallpaper-derived theming |
| `curl` | 8.21.0 | night-light geolocation |
| `python3` + `pillow` | 3.13.14 | `wallpaper/generate-abstract.py` |
| `hyprland` | 0.55.4 | `hyprctl`, already in the profile |
| `systemd`, `sh` | — | from the system |

`python3` must be `python3.withPackages (ps: [ ps.pillow ])`. The abstract
wallpaper generator imports `PIL`, and a bare `python3` fails only when
someone generates a wallpaper.

### 6. Verification

The rule this spec inherits from spec 1: **started is not drew**. A unit
reporting `active (running)` proved nothing about `hyprpolkitagent` and proves
nothing here.

The positive signal is layer-shell. The bar is a `wlr-layer-shell` surface, so
it appears in `hyprctl layers` only if it actually mapped:

```sh
hyprctl layers | grep -i quickshell
```

Four failure modes, each checked differently because each fails differently.

| Mode | How it fails | Check |
|---|---|---|
| `nixGL` missing | `ABRT` on first draw; unit "active" then gone | `hyprctl layers` empty, `status` shows `code=dumped` |
| `PATH` incomplete | no crash; features silently dead | exercise brightness keys and the clipboard picker |
| state dir missing | `printf >` fails **invisibly** | change theme in the UI, then read `~/.local/state/quickshell/theme.conf` |
| QML import error | shell starts, panels missing | `journalctl --user -u quickshell` |

The third matters most. It is the same shape as spec 1's keyring probe:
nothing errors, the setting simply does not persist, and the symptom arrives
days later as a rebuild that appears to have reverted your theme. Reading the
file back is the only way to see it.

Testing is on `isutton` directly rather than `nixtest`. The session is proven
end to end, quickshell needs a person's eyes to judge, and rollback is a
previous generation's `activate` with state untouched by design. `nixtest`
remains as a control.

## Features that arrive partially

Consequences of scoping this spec to quickshell alone. Named here so they are
recognised as boundaries rather than diagnosed as bugs.

- **Browser selector.** quickshell writes `.previous-browser` and
  `browser.json`, but `calango-open` and the `.desktop` entries that consume
  them are spec 4. Expect selection to be inert; the plan verifies this rather
  than assuming it.
- **Night light.** The panel, `night-light/{locate.sh,run.sh}` and both state
  files come over. `night-light.service` is spec 5, so the schedule does not
  run on its own.
- **Theme switcher.** It writes `hypr/theme-borders.conf`,
  `kitty/theme-colors.conf` and `foot/theme-colors.ini`. Those three targets
  belong to specs 3 and 4. Themes will apply to quickshell and not yet to the
  compositor or the terminals.
- **Bluetooth panel.** Present and able to talk to `bluetoothctl`, but
  `bt-agent.service` is spec 5, so pairing that needs an agent will not
  complete.

## Open items

- **`common/gen-icons.js` needs `nodejs`.** Whether it runs at build time or
  runtime is not yet established. If runtime, `nodejs` 24.18.1 joins the
  closure; if build time, its output is generated into the derivation and
  `nodejs` does not ship.
- **`geoclue`** appears in `night-light/locate.sh` alongside `curl`. Which
  path is actually taken on `suffer` is unknown, and matters only when spec 5
  makes the schedule run.
- **XWayland is software-rendered** in this session, from spec 1's rung 2 log.
  quickshell is Wayland-native so it is unaffected, but any X11 client it
  launches will be slow.
