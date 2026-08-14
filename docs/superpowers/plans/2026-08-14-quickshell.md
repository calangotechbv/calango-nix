# calango-nix quickshell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run calango-desktop's quickshell from Nix on `suffer`, owned by Home
Manager, with its runtime-written state in `~/.local/state/quickshell` where
Home Manager cannot turn it read-only.

**Architecture:** The 86 source files are forked into `calango-nix/quickshell/`
and their configuration-directory references rewritten to a state directory. A
derivation puts that tree in the store; a hand-written
`systemd.user.services.quickshell` runs it with `-p`, wrapped in `nixGLIntel`
and given an explicit `PATH`. Home Manager manages the source and never the
state.

**Tech Stack:** quickshell 0.3.0, nixpkgs `nixos-26.05`, home-manager
`release-26.05`, nixGL, matugen 4.0.0, wallust 3.5.2, swaybg 1.2.2.

**Spec:** `docs/superpowers/specs/2026-08-14-quickshell-design.md`

## Global Constraints

- **State lives in `~/.local/state/quickshell`,** written as
  `${XDG_STATE_HOME:-$HOME/.local/state}/quickshell` in every shell context.
- **Home Manager manages no file under `~/.local/state/quickshell`** except
  `.keep` entries that force the directories to exist. Managing any other
  would make it a read-only store symlink and undo the whole spec.
- **The unit's `ExecStart` goes through `nixGLIntel`.** Spec 1 proved a Nix
  Qt6 application in a systemd user unit aborts on first draw without it.
- **The unit's `PATH` is explicit.** Nothing on this machine puts
  `~/.nix-profile/bin` on a unit's `PATH`.
- **`~/Projects/calango-desktop` is never modified and is never a flake
  input.** It is copied from once, by hand, in Task 1.
- **The five `dev-*.qml` files are not ported.**
- **`nodejs` is not in the runtime closure.** `common/gen-icons.js` is a
  hand-run developer tool and `common/Icons.qml` ships generated.

## How to read the checks in this plan

There is no test runner here, exactly as in spec 1's plan. A task's test is a
command whose output you read. Every check states the command and the exact
output that counts as a pass.

Steps marked **[KEYBOARD]** need a person at the machine — a login, or eyes on
a bar that either drew or did not. An agent must stop at those steps and ask.

---

### Task 1: Fork the tree

**Files:**
- Create: `quickshell/**` (86 files, copied)

**Interfaces:**
- Consumes: nothing.
- Produces: `calango-nix/quickshell/` containing the source tree with no state
  files and no `dev-*.qml`, for Task 2 to rewrite.

- [ ] **Step 1: Run the check that must fail**

```bash
cd ~/Projects/calango-nix
ls quickshell 2>&1
```

Expected: `ls: cannot access 'quickshell': No such file or directory`

- [ ] **Step 2: Copy the tree, excluding state and dev probes**

```bash
cd ~/Projects/calango-nix
rsync -a --exclude='dev-*.qml' \
  --exclude='theme.conf' \
  --exclude='wallpaper.conf' \
  --exclude='bar.conf' \
  --exclude='night-light.conf' \
  --exclude='night-light-location.conf' \
  --exclude='notification-history.json' \
  --exclude='.previous-browser' \
  --exclude='browser.json' \
  --exclude='bluetooth-adapter.conf' \
  --exclude='main-monitor.conf' \
  --exclude='theme-switcher/wallpaper-theme.json' \
  ~/Projects/calango-desktop/quickshell/ quickshell/
```

The last four excludes name files that do not exist today. They are listed so
that a machine where they *do* exist copies no state either.

- [ ] **Step 3: Check the counts**

```bash
cd ~/Projects/calango-nix
echo "files:  $(find quickshell -type f | wc -l)   want 86"
echo "dev:    $(find quickshell -name 'dev-*' | wc -l)   want 0"
echo "state:  $(find quickshell \( -name 'theme.conf' -o -name 'bar.conf' \
  -o -name '*.previous-browser' -o -name 'notification-history.json' \) | wc -l)   want 0"
echo "shell:  $(test -f quickshell/shell.qml && echo present || echo MISSING)"
```

Expected: `86`, `0`, `0`, `present`.

`shell.qml` is checked by name because `quickshell -p <dir>` resolves the
config through it; without it the directory is not a config at all.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/calango-nix
git add quickshell
git commit -m "quickshell: fork the tree, without the state files or the dev probes"
```

---

### Task 2: Rewrite the paths

**Files:**
- Create: `quickshell/common/Paths.qml`, `quickshell/common/qmldir`
- Modify: 8 QML files by `sed` (the shell-string form)
- Modify: `quickshell/night-light/{run,locate}.sh` (same `sed`)
- Modify: 8 QML files by hand (state reads), 3 by hand (source reads)
- Modify: `quickshell/browser/discover.py:109`
- Modify: `quickshell/theme-switcher/wallpaper-theme/wallust/wallust.toml:9`
- Modify: `quickshell/theme-switcher/wallpaper-theme/set.sh:15` (a comment)

**Interfaces:**
- Consumes: Task 1's tree.
- Produces: `Paths.stateDir` and `Paths.sourceDir`, the two singletons every
  later path in the tree resolves through; and a tree whose only remaining
  `.config/quickshell` reference is in `matugen/config.toml`, which Task 3
  generates and overwrites.

There are **thirty** references and they move in two different directions.
Twenty-four follow state to `~/.local/state`; five follow source into the
store; one is a comment. Do not reach for a single global substitution — it
is wrong for five of them, and each of those five fails as a missing file or
a read-only filesystem rather than as an error you can grep for.

- [ ] **Step 1: Run the check that must fail**

```bash
cd ~/Projects/calango-nix
echo "all forms:  $(grep -rho '\.config/quickshell' quickshell | wc -l)   want 30"
echo "shell form: $(grep -rho '\$HOME/\.config/quickshell' quickshell | wc -l)   want 13"
```

Expected: `30`, then `13`.

- [ ] **Step 2: Rewrite the 13 shell-context references**

Every one of the 13 sits inside a shell string or a shell script, so one
substitution is correct for all of them.

```bash
cd ~/Projects/calango-nix
grep -rl '\$HOME/\.config/quickshell' quickshell |
  xargs sed -i 's|\$HOME/\.config/quickshell|${XDG_STATE_HOME:-$HOME/.local/state}/quickshell|g'
```

`night-light/run.sh` lines 22 and 23 nest this inside an existing default:

```sh
CONF=${NIGHT_LIGHT_CONF:-${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/night-light.conf}
```

That is valid POSIX parameter expansion. In the QML the replacement lands
inside single- and double-quoted JavaScript strings, neither of which is a
template literal, so `${...}` stays literal text and reaches `sh` intact.

- [ ] **Step 3: Rewrite the 8 QML state reads**

These are QML string concatenation, not shell strings, so the `sed` above did
not touch them. Each is a `FileView`-style `path:` reading a state file.

Edit these eight lines by hand, and no others. A blanket `sed` is wrong here
for two reasons: the `Quickshell.env(...) + "..."` form needs parenthesising
to keep operator precedence once a fallback is introduced, and any pattern
broad enough to catch all eight also catches the four *source* references in
step 4, which must go the opposite way.

| File | Line | New right-hand side |
|---|---|---|
| `wallpaper/WallpaperService.qml` | 85 | `stateDir + "/wallpaper.conf"` |
| `bluetooth/BluetoothService.qml` | 79 | `stateDir + "/bluetooth-adapter.conf"` |
| `browser/BrowserService.qml` | 32 | `stateDir + "/browser.json"` |
| `night-light/NightLightService.qml` | 47 | `stateDir + "/night-light.conf"` |
| `night-light/NightLightService.qml` | 165 | `stateDir + "/night-light-location.conf"` |
| `common/BarSettings.qml` | 94 | `stateDir + "/bar.conf"` |
| `common/Screens.qml` | 63 | `stateDir + "/main-monitor.conf"` |
| `theme-switcher/Theme.qml` | 444 | `stateDir + "/theme-switcher/wallpaper-theme.json"` |

Define `stateDir` once, in `common/Paths.qml`, as a new singleton:

```qml
pragma Singleton
import QtQuick
import Quickshell

Singleton {
  // State: written at runtime, so it must live outside the read-only store.
  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/quickshell"

  // Source: ships in the tree, so it must resolve into the store.
  // shellDir is the directory of the running shell.qml.
  readonly property string sourceDir: Quickshell.shellDir
}
```

Register it in `common/qmldir` (create the file if the directory has none):

```
singleton Paths 1.0 Paths.qml
```

and in each of the eight files, `import "../common"` (or `"."` within
`common/`) and use `Paths.stateDir`.

One singleton rather than eight copies of the same expression: the fallback
logic is subtle enough that eight divergent copies is how one of them ends up
wrong.

- [ ] **Step 4: Rewrite the 4 QML source reads**

These want the store, not state. `Quickshell.shellDir` is the directory of the
running `shell.qml`.

| File | Line | New right-hand side |
|---|---|---|
| `browser/BrowserService.qml` | 39 | `Paths.sourceDir + "/browser/discover.py"` |
| `night-light/NightLightService.qml` | 108 | `Paths.sourceDir + "/night-light/locate.sh"` |
| `theme-switcher/Theme.qml` | 270 | `Paths.sourceDir + "/theme-switcher/wallpaper-theme/set.sh"` |
| `theme-switcher/Theme.qml` | 472 | `Paths.sourceDir + "/theme-switcher/themes.json"` |

Getting one of these backwards is the failure the spec warns about most:
pointed at state, the file simply is not there, and the feature goes quiet
with no error.

- [ ] **Step 5: Rewrite the Python path**

`browser/discover.py:109` currently reads:

```python
CONFIG_PATH = os.path.expanduser("~/.config/quickshell/browser.json")
```

Replace it with:

```python
CONFIG_PATH = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "quickshell", "browser.json")
```

`or` rather than a two-argument `get`, so that an empty `XDG_STATE_HOME`
falls back instead of producing `/quickshell/browser.json`.

- [ ] **Step 6: Rewrite the wallust target**

In `theme-switcher/wallpaper-theme/wallust/wallust.toml`, line 9:

```toml
quickshell.target = '~/.local/state/quickshell/theme-switcher/wallpaper-theme.json'
```

Leave `quickshell.template = "quickshell.json"` alone. It is relative to the
directory `set.sh` passes with `-d`, which resolves through `dirname "$0"` and
so points into the store correctly with no change.

- [ ] **Step 7: Update the stale comment**

`theme-switcher/wallpaper-theme/set.sh` line 15 documents an awws hook with
the old path. It is a comment and changes no behaviour, but leaving it would
tell the next reader the wrong thing:

```sh
#     on_change = "~/.local/state/quickshell/theme-switcher/wallpaper-theme/set.sh %w"
```

This is wrong in a second way and worth fixing properly: `set.sh` lives with
the *source*, not the state, so after this port its real path is in the
store. Write instead:

```sh
#     on_change = "<store path>/theme-switcher/wallpaper-theme/set.sh %w"
#     (find it with: systemctl --user cat quickshell | grep ExecStart)
```

- [ ] **Step 8: Run the check again**

```bash
cd ~/Projects/calango-nix
echo "remaining:      $(grep -rho '\.config/quickshell' quickshell | wc -l)   want 2"
echo "XDG_STATE_HOME: $(grep -rho 'XDG_STATE_HOME' quickshell | wc -l)   want 15"
echo "Paths.stateDir: $(grep -rho 'Paths\.stateDir' quickshell | wc -l)   want 8"
echo "Paths.sourceDir:$(grep -rho 'Paths\.sourceDir' quickshell | wc -l)   want 4"
grep -rn '\.config/quickshell' quickshell
```

Expected: `2`, `15`, `8`, `4`, then two lines — both in
`matugen/config.toml`, which Task 3 replaces wholesale.

`XDG_STATE_HOME` totals 15: 13 from the `sed`, one in `Paths.qml`, one in
`discover.py`.

Do not grep for `local/state/quickshell`. The shell substitution produces
`${XDG_STATE_HOME:-$HOME/.local/state}/quickshell`, so a `}` sits between
`state` and `/quickshell` and that pattern matches nothing even when the
rewrite is perfect.

Do not grep for `local/state/quickshell`. The substitution produces
`${XDG_STATE_HOME:-$HOME/.local/state}/quickshell`, so a `}` sits between
`state` and `/quickshell` and that pattern matches nothing even when the
rewrite is perfect. `XDG_STATE_HOME` is the reliable marker: 13 from the
`sed`, plus one in `discover.py`'s `os.environ.get`.

- [ ] **Step 9: Check the shell scripts still parse**

A `sed` across quoted strings can produce something that no longer parses.

```bash
cd ~/Projects/calango-nix
for f in quickshell/night-light/run.sh quickshell/night-light/locate.sh \
         quickshell/theme-switcher/wallpaper-theme/set.sh; do
  printf '%-56s ' "$f"; sh -n "$f" && echo OK
done
python3 -m py_compile quickshell/browser/discover.py && echo "discover.py OK"
```

Expected: `OK` three times, then `discover.py OK`.

- [ ] **Step 10: Commit**

```bash
cd ~/Projects/calango-nix
git add quickshell
git commit -m "quickshell: point every write at the state directory, not the config one"
```

---

### Task 3: The derivation

**Files:**
- Create: `home/quickshell.nix`
- Modify: `flake.nix` — add `./home/quickshell.nix` to `mkHome`'s module list

**Interfaces:**
- Consumes: Task 2's tree; `pkgs.nixgl.nixGLIntel` from spec 1.
- Produces: `config.calango.quickshellConfig`, a store path containing
  `shell.qml` at its root, for Task 5's `ExecStart` to name.

- [ ] **Step 1: Write the module**

Create `home/quickshell.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  # matugen reads its own TOML and cannot expand $dir the way set.sh does, so
  # input_path has to be an absolute store path -- which is not known until
  # this derivation is being built. That is why this one file is generated
  # rather than forked. Note the two lines point opposite ways on purpose:
  # the template is source and lives in the store, the output is state.
  quickshellConfig = pkgs.runCommand "quickshell-config" { } ''
    cp -r ${./../quickshell} "$out"
    chmod -R u+w "$out"

    cat > "$out/theme-switcher/wallpaper-theme/matugen/config.toml" <<EOF
    # Generated by home/quickshell.nix. See that file for why.
    [config]

    [templates.quickshell]
    input_path = '$out/theme-switcher/wallpaper-theme/matugen/template.json'
    output_path = '~/.local/state/quickshell/theme-switcher/wallpaper-theme.json'
    EOF
  '';
in
{
  options.calango.quickshellConfig = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The quickshell config tree, in the store.";
  };

  config.calango.quickshellConfig = quickshellConfig;
}
```

- [ ] **Step 2: Add the module to the flake**

In `flake.nix`, inside `mkHome`'s `modules` list, after `./home/session.nix`:

```nix
          ./home/quickshell.nix
```

- [ ] **Step 3: Build it**

```bash
cd ~/Projects/calango-nix
git add home/quickshell.nix flake.nix
nix build --no-link --print-out-paths \
  .#homeConfigurations."isutton@suffer".config.calango.quickshellConfig
```

Expected: a `/nix/store/...-quickshell-config` path.

If `nix` reports a daemon-socket permission error, the shell lacks the
`nix-users` group; prefix with `sg nix-users -c '...'`.

- [ ] **Step 4: Check the generated matugen config points both ways**

```bash
cd ~/Projects/calango-nix
Q=$(nix build --no-link --print-out-paths \
  .#homeConfigurations."isutton@suffer".config.calango.quickshellConfig)
cat "$Q/theme-switcher/wallpaper-theme/matugen/config.toml"
test -f "$Q/shell.qml" && echo "shell.qml at root: yes"
test -f "$Q/theme-switcher/wallpaper-theme/matugen/template.json" && echo "template present: yes"
```

Expected: `input_path` is an absolute `/nix/store/...` path that exists,
`output_path` is under `~/.local/state`, then both `yes` lines.

This is the check that catches the mistake the spec warns about — an
`input_path` left pointing at `~/.config` reads a file that is not there, and
matugen fails only when someone generates a wallpaper theme.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/calango-nix
git add home/quickshell.nix flake.nix
git commit -m "quickshell: a store tree, with matugen's config generated for its store path"
```

---

### Task 4: The state directory, and seeding it

**Files:**
- Modify: `home/quickshell.nix`

**Interfaces:**
- Consumes: Task 3's module.
- Produces: `~/.local/state/quickshell/` and
  `~/.local/state/quickshell/theme-switcher/`, both real directories, holding
  the seven files that exist today.

- [ ] **Step 1: Run the check that must fail**

```bash
ls ~/.local/state/quickshell 2>&1
```

Expected: `ls: cannot access ...: No such file or directory`

- [ ] **Step 2: Add the directory guarantees**

In `home/quickshell.nix`, add to the `config` attribute set:

```nix
  # The only thing Home Manager may own under the state directory. A .keep
  # forces the parent to be created as a real directory; anything more would
  # make a state file a read-only store symlink, which is the failure this
  # whole spec exists to avoid.
  #
  # The directories must exist before quickshell writes: every write is a bare
  # `printf > path` with no mkdir, and a missing directory fails silently.
  config.home.file = {
    ".local/state/quickshell/.keep".text = "";
    ".local/state/quickshell/theme-switcher/.keep".text = "";
  };
```

Add this as a sibling attribute of the `config.calango.quickshellConfig` line
Task 3 wrote. That module has no `config = { ... }` block, so there is nothing
to merge into — two `config.<something>` attributes at the same level is the
correct shape.

- [ ] **Step 3: Build and check the links**

```bash
cd ~/Projects/calango-nix
nix build --out-link result-isutton \
  .#homeConfigurations."isutton@suffer".activationPackage
find -L result-isutton/home-files/.local -type f | sort
```

Expected: exactly the two `.keep` paths and nothing else under
`.local/state/quickshell`.

- [ ] **Step 4: Seed the seven existing files**

Once, by hand. Not an activation script: activation runs on every switch, and
a seed-if-absent guard is a silent no-op indistinguishable from a working one.

```bash
mkdir -p ~/.local/state/quickshell/theme-switcher
cd ~/Projects/calango-desktop/quickshell
for f in theme.conf wallpaper.conf bar.conf night-light.conf \
         night-light-location.conf notification-history.json .previous-browser; do
  cp -n "$f" ~/.local/state/quickshell/"$f"
done
```

`cp -n` so that re-running this step cannot overwrite state written since.

- [ ] **Step 5: Check the seed landed intact**

```bash
cd ~/.local/state/quickshell
for f in theme.conf wallpaper.conf bar.conf night-light.conf \
         night-light-location.conf notification-history.json .previous-browser; do
  printf '%-30s %s\n' "$f" "$(cat "$f" 2>&1 | head -c 60)"
done
```

Expected, from the state as recorded on 2026-08-14:

```
theme.conf                     206
wallpaper.conf                 /home/isutton/Pictures/Wallpapers/monokai-pro-aurora.png
bar.conf                       opacity=0 pill-opacity=0.25 blur=1
night-light.conf               mode=auto temp=3000
night-light-location.conf      -23.6261 -46.7917
notification-history.json      []
.previous-browser              eu.calangotech.KBrowserSelector.desktop
```

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/calango-nix
git add home/quickshell.nix
git commit -m "quickshell: guarantee the state directories, and nothing else inside them"
```

---

### Task 5: The unit

**Files:**
- Modify: `home/quickshell.nix`

**Interfaces:**
- Consumes: `config.calango.quickshellConfig` from Task 3;
  `pkgs.nixgl.nixGLIntel`.
- Produces: `~/.config/systemd/user/quickshell.service`, wrapped and with an
  explicit `PATH`.

- [ ] **Step 1: Add the runtime closure and the unit**

In `home/quickshell.nix`, extend the `let` block:

```nix
  # Everything the QML invokes by bare name. A systemd user unit gets a
  # minimal PATH and nothing on this machine adds the Nix profile to it, so
  # each of these is a runtime failure if omitted -- and a silent one: the
  # feature simply stops working, with no error anywhere.
  runtimeDeps = with pkgs; [
    brightnessctl                                 # OSD, brightness keys
    cliphist                                      # clipboard picker
    wl-clipboard                                  # clipboard picker
    swaybg                                        # wallpaper
    glib                                          # gsettings
    libnotify                                     # notifications
    jq                                            # theme switcher, night light
    matugen                                       # wallpaper-derived theming
    wallust                                       # the matugen fallback
    curl                                          # night-light geolocation
    hyprland                                      # hyprctl
    systemd                                       # systemctl
    bash coreutils                                # sh, cat
    (python3.withPackages (ps: [ ps.pillow ]))    # wallpaper/generate-abstract.py
  ];

  # Qt Quick builds its scenegraph on first window show. Unwrapped, this unit
  # would reach "active (running)" and then abort with status=6/ABRT the
  # moment the bar tried to map -- exactly what hyprpolkitagent did in spec 1.
  quickshell-nixgl = pkgs.writeShellScript "quickshell-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
      ${pkgs.quickshell}/bin/quickshell "$@"
  '';
```

and add to `config`:

```nix
  config.systemd.user.services.quickshell = {
    Unit = {
      Description = "Quickshell shell";
      Documentation = "https://quickshell.outfoxxed.me";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # Carried over from calango-desktop's unit. Under uwsm the race this
      # once guarded cannot happen, and it stays as a statement of what the
      # unit needs rather than as a guard.
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "simple";
      ExecStart = "${quickshell-nixgl} -p ${config.calango.quickshellConfig}";
      Environment = [ "PATH=${lib.makeBinPath runtimeDeps}" ];
      Restart = "on-failure";
      RestartSec = 2;
      Slice = "app.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
```

There is deliberately no `ExecReload`. quickshell watches its own QML and
reloads in place — though from a store path nothing will ever change under it,
so a rebuild plus `systemctl --user restart quickshell` is the update path.

- [ ] **Step 2: Build and read the unit back**

```bash
cd ~/Projects/calango-nix
nix build --out-link result-isutton \
  .#homeConfigurations."isutton@suffer".activationPackage
cat result-isutton/home-files/.config/systemd/user/quickshell.service
```

Expected: an `ExecStart` naming a `quickshell-nixgl` script and a
`quickshell-config` store path, and a `PATH=` listing roughly fourteen store
`bin` directories.

- [ ] **Step 3: Check the wrapper wraps**

```bash
cd ~/Projects/calango-nix
sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' \
  result-isutton/home-files/.config/systemd/user/quickshell.service | xargs cat
```

Expected: a two-line script whose `exec` names `nixGLIntel` and then
`quickshell`.

- [ ] **Step 4: Check every runtime command resolves on that PATH**

This is the check that catches the second failure mode before it can be
mistaken for a broken feature.

```bash
cd ~/Projects/calango-nix
P=$(sed -n 's/^Environment=PATH=//p' \
  result-isutton/home-files/.config/systemd/user/quickshell.service)
for c in brightnessctl cliphist wl-copy swaybg gsettings notify-send jq \
         matugen wallust curl hyprctl systemctl sh cat python3; do
  printf '%-14s %s\n' "$c" "$(PATH="$P" command -v "$c" || echo MISSING)"
done
```

Expected: a store path for every one, and no `MISSING`.

- [ ] **Step 5: Check pillow is in that python**

```bash
cd ~/Projects/calango-nix
P=$(sed -n 's/^Environment=PATH=//p' \
  result-isutton/home-files/.config/systemd/user/quickshell.service)
PATH="$P" python3 -c 'import PIL; print("pillow", PIL.__version__)'
```

Expected: a version. A bare `python3` would import nothing and fail only when
someone generates an abstract wallpaper.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/calango-nix
git add home/quickshell.nix
git commit -m "quickshell: the unit, wrapped in nixGL and with an explicit PATH"
```

---

### Task 6: Activate, and prove it drew

**Files:**
- none

**Interfaces:**
- Consumes: Tasks 3 to 5.
- Produces: a running bar, and the evidence that it mapped a surface.

- [ ] **Step 1: Activate**

```bash
cd ~/Projects/calango-nix
nix run home-manager/release-26.05 -- switch --flake .#isutton@suffer
```

Expected: activation completes, with `quickshell.service` among the started
units. A `would be clobbered` error names a file that already exists; move it
aside rather than deleting it, and record which.

- [ ] **Step 2: Log into the Nix session** **[KEYBOARD]**

Log out, choose `Hyprland (Nix)`, log in as `isutton`.

- [ ] **Step 3: Check the unit is up**

```bash
systemctl --user is-active quickshell.service
systemctl --user show quickshell.service -p ExecMainStatus -p NRestarts
```

Expected: `active`, `ExecMainStatus=0`, `NRestarts=0`.

A climbing `NRestarts` with `Restart=on-failure` means it is crash-looping —
go to step 5 before anything else.

- [ ] **Step 4: Check it actually drew**

```bash
hyprctl layers | grep -i quickshell
```

Expected: at least one layer-shell surface named for quickshell.

**This is the check that matters.** Spec 1's lesson was that `active
(running)` proved nothing about `hyprpolkitagent`, which was up and still
aborted the instant it tried to render. The bar is a `wlr-layer-shell`
surface, so it appears here only if it truly mapped.

- [ ] **Step 5: If it did not draw, read the log**

```bash
journalctl --user -u quickshell -b --no-pager | tail -40
```

- `code=dumped, status=6/ABRT` with no GL message: the nixGL wrapper is not
  in `ExecStart`. Re-check Task 5 step 3.
- `MESA-LOADER` or `/run/opengl-driver`: same cause, stated outright.
- A QML error naming a missing import or file: the fork is incomplete;
  re-check Task 1 step 3's count of 86.

- [ ] **Step 6: Commit nothing; this task changes no files**

Record the outcome in Task 8.

---

### Task 7: The three failure modes that do not crash

**Files:**
- none

**Interfaces:**
- Consumes: a drawing bar from Task 6.
- Produces: evidence for the state contract and the runtime closure.

Run all of these inside the session, from a terminal opened in it.

- [ ] **Step 1: State persists — the silent one**

```bash
cat ~/.local/state/quickshell/theme.conf
```

Note the value. Now change the theme through the shell's own interface, then:

```bash
cat ~/.local/state/quickshell/theme.conf
```

Expected: the value changed.

This is the most important check in the plan and the easiest to skip, because
nothing errors when it fails. `printf > path` into a missing directory writes
nothing and says nothing; the theme appears to change, and reverts at the next
restart. It is the same shape as spec 1's keyring probe. Reading the file back
is the only way to see it.

- [ ] **Step 2: Nothing is still writing to the old location**

```bash
ls ~/.config/quickshell 2>&1
```

Expected: `No such file or directory`. If that directory has reappeared, a
path was missed in Task 2 — find it with
`grep -rn '\.config/quickshell' ~/Projects/calango-nix/quickshell`.

- [ ] **Step 3: The runtime closure, exercised**

Each of these fails silently rather than loudly if its command is off `PATH`:

```bash
systemctl --user show-environment | grep -q WAYLAND_DISPLAY && echo "display ok"
```

Then, through the interface: press the brightness keys and confirm the OSD
moves; open the clipboard picker and confirm it lists history; open the
network and bluetooth panels and confirm they populate.

- [ ] **Step 4: The theme generator, which uses the store-path config**

```bash
WALLPAPER_THEME_TOOL=matugen \
  "$(systemctl --user show quickshell.service -p ExecStart --value |
     sed 's/.*-p \([^ ;]*\).*/\1/')/theme-switcher/wallpaper-theme/set.sh" \
  "$(cat ~/.local/state/quickshell/wallpaper.conf)"
cat ~/.local/state/quickshell/theme-switcher/wallpaper-theme.json | head -5
```

Expected: the command exits 0 and the JSON file exists with palette content.

This exercises the one file the derivation generates. A failure naming
`input_path` means matugen's config still points at `~/.config`; a failure
about a read-only file system means `output_path` was left pointing into the
store.

- [ ] **Step 5: Confirm the partial features are inert, not broken**

The spec predicts four features arrive incomplete. Confirm each behaves as
predicted rather than erroring:

```bash
ls ~/.local/state/quickshell/.previous-browser   # browser selector: writes, no handler
systemctl --user is-active night-light.service   # expect: inactive/not-found
systemctl --user is-active bt-agent.service      # expect: inactive/not-found
ls ~/.config/hypr/theme-borders.conf 2>&1        # expect: no such file
```

Expected: the browser file exists; both units are absent; `theme-borders.conf`
does not exist. Themes apply to quickshell and not to the compositor, which is
spec 3's job.

---

### Task 8: Record the results

**Files:**
- Create: `docs/2026-08-14-results-suffer-quickshell.md`

**Interfaces:**
- Consumes: Tasks 6 and 7.
- Produces: the record spec 3 reads before porting the Hyprland config.

- [ ] **Step 1: Write the results document**

Create `docs/2026-08-14-results-suffer-quickshell.md`. Fill in what actually
happened; do not copy an expected result.

````markdown
# suffer: quickshell from Nix

Date: 2026-08-14
Session: Hyprland (Nix), isutton.

## Did it draw?

| Check | Command | Result |
|---|---|---|
| unit up | `systemctl --user is-active quickshell.service` | |
| restarts | `systemctl --user show -p NRestarts` | |
| **drew** | `hyprctl layers \| grep -i quickshell` | |

## The state contract

| Check | Result |
|---|---|
| theme change persists to `~/.local/state` | |
| `~/.config/quickshell` stays absent | |
| `wallpaper-theme.json` generated by `set.sh` | |

## The runtime closure

Which of the fourteen commands were actually exercised, and which were taken
on trust from `command -v`:

## Partial features, as predicted by the spec

| Feature | Predicted | Observed |
|---|---|---|
| browser selector | writes state, no handler until spec 4 | |
| night light | no schedule until spec 5 | |
| theming beyond quickshell | compositor and terminals unthemed until specs 3 and 4 | |
| bluetooth pairing | no agent until spec 5 | |

## Surprises

````

- [ ] **Step 2: Commit**

```bash
cd ~/Projects/calango-nix
git add docs/2026-08-14-results-suffer-quickshell.md
git commit -m "results: quickshell from Nix, and whether the state split held"
```

---

## Where this plan stops

quickshell runs from Nix, drawing, with its state in `~/.local/state` and its
source in the store. The compositor, the terminals and three systemd units are
still unported, so themes stop at the bar and the night-light schedule does not
run.

Spec 3 takes `hyprland.lua`. Spec 4 takes the terminals, `lf` and the GTK
theming. Spec 5 takes the three remaining units. Spec 6 removes
`trixie-backports` and deletes `nixtest`.

## Open items this plan does not close

- **`geoclue` versus `curl` in `night-light/locate.sh`.** Which path `suffer`
  takes is unknown and matters only when spec 5 makes the schedule run.
- **wallust writing into its `-d` directory.** `set.sh` passes a store path,
  and whether wallust wants to write a cache there is untested — Task 7 step 4
  exercises matugen, the default, not the fallback. Force it with
  `WALLPAPER_THEME_TOOL=wallust` to find out.
- **Icon regeneration.** `common/gen-icons.js` is ported but needs `@mdi/svg`
  7.4.47, which is not vendored. Regenerating means fetching that package and
  `nix run nixpkgs#nodejs`.
