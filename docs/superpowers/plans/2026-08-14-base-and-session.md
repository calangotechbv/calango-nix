# calango-nix Base and Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Boot a stock Hyprland session from Nix on `suffer`, a Debian 13 machine, without adding `trixie-backports` for it, and without disturbing the working calango-desktop session.

**Architecture:** apt keeps everything that needs root — `nix-daemon`, greetd, PAM, Mesa, the vendor stack. A standalone Home Manager flake owns the user layer and provides the eight packages that exist only in backports today. `nixGL` supplies the GL stack that a Nix build cannot find on a foreign distribution. Testing runs under a throwaway second account on a spare VT, so the live session is never at risk until the last task.

**Tech Stack:** Nix 2.26.3 from Debian `trixie`, flakes, nixpkgs `nixos-26.05`, home-manager `release-26.05`, nixGL (`nix-community/nixGL`), Hyprland 0.55.4, uwsm 0.26.4.

**Spec:** `docs/superpowers/specs/2026-08-14-base-and-session-design.md`

## Global Constraints

- **nixpkgs is pinned to `github:NixOS/nixpkgs/nixos-26.05`.** Verified: the branch exists.
- **home-manager is pinned to `github:nix-community/home-manager/release-26.05`.** Verified: the branch exists.
- **nixGL's `nixpkgs` input MUST follow ours.** The nixGL README reports `GLIBC_2.34 not found` when they differ. This is not optional.
- **The GL wrapper is `pkgs.nixgl.nixGLIntel`.** Verified from `nixGL/flake.nix`: `nixGLIntel` is exposed as `pkgs.nixGLIntel`, outside the `auto.*` set, so it needs no `--impure`. `auto.nixGLDefault` is the NVIDIA-detecting fallback and is not used here. Both machines are AMD, and the nixGL README describes `nixGLIntel` as the "Mesa OpenGL implementation (intel, amd, nouveau, ...)".
- **The nixGL overlay attribute is `overlays.default`.** Verified from `nixGL/flake.nix`; the bare `overlay` is a deprecated alias. It exposes packages under `pkgs.nixgl.*`.
- **`~/Projects/calango-desktop` is never modified, and is never a flake input.** It is read by a person for reference only.
- **`trixie-backports` stays in `sources.list` for the whole of this plan.** Removing it belongs to spec 3.
- **The only file this project puts outside `$HOME` is `/usr/local/share/wayland-sessions/hyprland-nix.desktop`.**
- **`/etc/greetd/config.toml` is not edited.** It already scans `/usr/local/share/wayland-sessions`.
- **Stock configuration only.** No calango-desktop QML, no theme, no bar. That is spec 2.

## How to read the checks in this plan

There is no test runner here. A task's test is a command whose output you read.
Every check states the command and the exact output that counts as a pass.

Steps marked **[KEYBOARD]** need a person physically at the machine: a VT
switch, a password at a greeter, or a `sudo` prompt. An agent must stop at
those steps and ask.

---

### Task 1: Nix on the machine

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a working `nix` with flakes enabled, for every later task.

- [ ] **Step 1: Run the check that must fail**

```bash
nix --version
```

Expected: `bash: nix: command not found`

- [ ] **Step 2: Install Nix from apt** **[KEYBOARD]**

```bash
sudo apt install nix-bin nix-setup-systemd
```

Debian's `nix-setup-systemd` creates the `nix-users` group and the
`nix-daemon` socket unit. It does not add you to the group.

- [ ] **Step 3: Join the `nix-users` group** **[KEYBOARD]**

```bash
sudo usermod -aG nix-users "$USER"
```

A group change takes effect on a new login session. Do not log out of the
desktop — open a fresh VT login or use `newgrp nix-users` in the shell you
are working in.

- [ ] **Step 4: Enable flakes**

```bash
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
```

This is a user-level file on purpose. It needs no root, and it keeps the
change inside `$HOME` where the rest of this project lives.

- [ ] **Step 5: Run the check again**

```bash
nix --version
systemctl is-active nix-daemon.service
nix flake --help >/dev/null && echo "flakes ok"
```

Expected: a version at or above `2.26.3`, then `active`, then `flakes ok`.

Check `nix-daemon.service`, not `nix-daemon.socket`. Debian enables both, but
the service is `WantedBy=multi-user.target` and its `ExecStart` is
`nix-daemon --daemon`, which binds `/nix/var/nix/daemon-socket/socket`
itself. The socket unit therefore never gets to listen: it reads
`inactive (dead)` on a working machine, and `systemctl start
nix-daemon.socket` fails. Verified on `suffer`, where a 5 GB closure built
fine with the socket unit dead the whole time.

If `nix flake --help` reports an experimental-feature error, the group change
has not taken effect in this shell. Start a new login shell and repeat.

If instead it reports
`getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`,
that is the same cause with a different symptom: the socket is `0666` but its
directory is `0770 root:nix-users`, so the group is what gates access. In a
shell you cannot re-login (an agent's, for instance), prefix each command:

```bash
sg nix-users -c 'nix build ...'
```

- [ ] **Step 6: Write the README**

Create `README.md`:

````markdown
# calango-nix

A Hyprland desktop on Debian 13, where apt owns what needs root and Nix owns
everything else. Successor to `calango-desktop`, which stays as a reference
and is not an input to this build.

Specs and plans live in `docs/superpowers/`.

## Bootstrap

Nix comes from Debian, because `nix-daemon` is a root service:

```sh
sudo apt install nix-bin nix-setup-systemd
sudo usermod -aG nix-users "$USER"      # takes effect on next login
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
```

Check it:

```sh
nix --version                      # 2.26.3 or later
systemctl is-active nix-daemon.socket
```

## What apt still owns

The vendor stack (Google Chrome, docker-ce, 1Password, Google
endpoint-verification, Signal, VS Code), the login path (greetd, tuigreet),
PAM and the keyring, the system services, device-permission tools, the portal
frontend, Mesa, and `nix-bin` itself.
````

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/calango-nix
git add README.md
git commit -m "bootstrap: nix from apt, because nix-daemon is a root service"
```

---

### Task 2: The flake, with nixGL pinned to our nixpkgs

**Files:**
- Create: `flake.nix`
- Create: `flake.lock` (generated)

**Interfaces:**
- Consumes: Task 1's working `nix`.
- Produces: `homeConfigurations."nixtest@suffer"` and
  `homeConfigurations."isutton@suffer"`, each expecting the modules
  `./home/default.nix` and `./home/session.nix` to exist. `pkgs` carries the
  nixGL overlay, so `pkgs.nixgl.nixGLIntel` resolves.

- [ ] **Step 1: Write the flake**

Create `flake.nix`:

```nix
{
  description = "calango-nix: a Hyprland desktop on Debian 13";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The follows is load-bearing. nixGL's own flake pins
    # inputs.nixpkgs.url = "github:nixos/nixpkgs", and a wrapper built against
    # a different nixpkgs than the programs it wraps fails at runtime with
    # "GLIBC_2.34 not found" rather than at build time.
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, nixgl, ... }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nixgl.overlays.default ];
      };

      mkHome = username: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home/default.nix
          ./home/session.nix
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "26.05";
          }
        ];
      };
    in
    {
      homeConfigurations = {
        "nixtest@suffer" = mkHome "nixtest";
        "isutton@suffer" = mkHome "isutton";
      };
    };
}
```

- [ ] **Step 2: Create the two module files as empty stubs**

The flake names them, so it cannot evaluate until they exist. They gain
content in Tasks 4 and 5.

```bash
mkdir -p ~/Projects/calango-nix/home
printf '{ ... }:\n{\n}\n' > ~/Projects/calango-nix/home/default.nix
printf '{ ... }:\n{\n}\n' > ~/Projects/calango-nix/home/session.nix
```

- [ ] **Step 3: Lock the inputs**

```bash
cd ~/Projects/calango-nix
nix flake lock
```

This writes `flake.lock` and downloads nothing else.

`git add` the three new files first. A flake in a git repository is read
through git, and an untracked `flake.nix` is invisible to it: the failure is
`error: path '/nix/store/...-source/flake.nix' does not exist`, which does
not mention git at all. Staging is enough; the commit comes in step 6.

- [ ] **Step 4: Run the check that proves the follows**

This is the one check in the plan that catches Global Constraint 3, and it
catches it before anything is built.

```bash
cd ~/Projects/calango-nix
nix flake metadata --json \
  | python3 -c '
import json,sys
d = json.load(sys.stdin)["locks"]["nodes"]

def resolve(ref, frm="root"):
    # A node input is either a node name (a string) or a follows path (a list
    # of input names, walked from the root node). Comparing the two forms
    # directly always reports a difference, even when the follows is correct.
    if isinstance(ref, str):
        return ref
    node = "root"
    for seg in ref:
        node = resolve(d[node]["inputs"][seg], node)
    return node

ours   = resolve(d["root"]["inputs"]["nixpkgs"])
nixgl  = resolve(d["root"]["inputs"]["nixgl"])
theirs = resolve(d[nixgl]["inputs"]["nixpkgs"])
hm     = resolve(d["root"]["inputs"]["home-manager"])
hmnp   = resolve(d[hm]["inputs"]["nixpkgs"])
print("nixpkgs             :", ours)
print("nixgl.nixpkgs       :", theirs)
print("home-manager.nixpkgs:", hmnp)
print("PASS" if ours == theirs == hmnp else "FAIL -- an input has its own nixpkgs")
'
```

Expected: the last line is `PASS`, and all three node names are identical.

If it prints `FAIL`, the `inputs.nixpkgs.follows` line is missing or
misspelled. Fix it, delete `flake.lock`, and repeat step 3.

- [ ] **Step 5: Check the flake evaluates**

```bash
cd ~/Projects/calango-nix
nix flake check --no-build
```

Expected: no error. Warnings about an empty module are acceptable.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/calango-nix
git add flake.nix flake.lock home/default.nix home/session.nix
git commit -m "flake: nixpkgs 26.05, and nixGL pinned to it so glibc cannot drift"
```

---

### Task 3: The throwaway account

**Files:**
- Create: `system/README.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a user `nixtest` with home `/home/nixtest`, matching
  `homeConfigurations."nixtest@suffer"` from Task 2.

The account exists so that Tasks 4 to 8 cannot touch `isutton`'s config. It is
deleted in spec 3.

- [ ] **Step 1: Run the check that must fail**

```bash
id nixtest
```

Expected: `id: 'nixtest': no such user`

- [ ] **Step 2: Create the account** **[KEYBOARD]**

```bash
sudo adduser --gecos "calango-nix test account" nixtest
sudo usermod -aG video,input,render,nix-users nixtest
```

`video` and `render` are needed to open the DRM device. `input` is needed for
the keyboard and pointer. `nix-users` is needed to reach `nix-daemon`.

- [ ] **Step 3: Check the account can reach the seat**

```bash
id nixtest
getent passwd nixtest | cut -d: -f6
```

Expected: the groups list contains `video`, `input`, `render` and
`nix-users`; the home directory is `/home/nixtest`.

- [ ] **Step 4: Check a login on a spare VT works** **[KEYBOARD]**

Press `Ctrl+Alt+F2`. Log in as `nixtest`. Run:

```bash
loginctl show-session "$XDG_SESSION_ID" -p Type -p Active -p Seat
nix --version
```

Expected: `Type=tty`, `Active=yes`, `Seat=seat0`, and a Nix version.

Then press `Ctrl+Alt+F7` and confirm the live desktop is undisturbed.

- [ ] **Step 5: Write the system README**

Create `system/README.md`:

````markdown
# The root-owned footprint

This project puts **one** file outside `$HOME`. Everything else is Home
Manager, under the user account.

## The test account

Used by the migration only. Delete it once `isutton` has moved across.

```sh
sudo adduser --gecos "calango-nix test account" nixtest
sudo usermod -aG video,input,render,nix-users nixtest
```

`video` and `render` open the DRM device, `input` the keyboard and pointer,
`nix-users` the Nix daemon.

Undo: `sudo deluser --remove-home nixtest`

## The session entry

Added in Task 8. See that task for the file.

```sh
sudo install -Dm644 system/hyprland-nix.desktop \
  /usr/local/share/wayland-sessions/hyprland-nix.desktop
```

`/etc/greetd/config.toml` needs no edit: it already runs
`tuigreet --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions`.

Undo: `sudo rm /usr/local/share/wayland-sessions/hyprland-nix.desktop`
````

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/calango-nix
git add system/README.md
git commit -m "system: a throwaway account, so no test can reach isutton's config"
```

---

### Task 4: The package set builds

**Files:**
- Modify: `home/default.nix` (replace the stub from Task 2)

**Interfaces:**
- Consumes: `pkgs` with the nixGL overlay, from Task 2.
- Produces: `home.packages` holding `hyprland`, `uwsm`,
  `xdg-desktop-portal-hyprland`, `hyprlock`, `foot`, `adwaita-fonts`,
  `nerd-fonts.adwaita-mono`, `pkgs.nixgl.nixGLIntel`. Enables the
  home-manager modules `services.hypridle` and `services.hyprpolkitagent`,
  which bring their own packages and generate their own user units.

- [ ] **Step 1: Write the module**

Replace `home/default.nix`:

```nix
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # The eight that exist only in trixie-backports today.
    hyprland
    uwsm
    xdg-desktop-portal-hyprland
    hyprlock
    # hypridle and hyprpolkitagent arrive through their modules below.
    # ydotool is dev tier and belongs to spec 3.

    # A terminal, so the session can be used and checked. foot draws through
    # wayland shm rather than GL, which makes it a control: if foot opens and
    # a GL client does not, the fault is the GL wrapper and nothing else.
    foot

    # The GL stack. nixGLIntel is the Mesa wrapper and covers AMD; it sits
    # outside nixGL's auto.* set, so it needs no --impure.
    pkgs.nixgl.nixGLIntel

    # The three families the shell is drawn in. Named here rather than in
    # spec 2 because a missing font is indistinguishable from a broken
    # renderer, and this task is where the renderer is first tested.
    adwaita-fonts
    nerd-fonts.adwaita-mono
  ];

  # Links fonts into ~/.local/share/fonts and writes a fontconfig snippet, so
  # both Nix and Debian applications find them.
  fonts.fontconfig.enable = true;

  # A user unit that is WantedBy=graphical-session.target. Its only job in
  # spec 1 is to prove that uwsm built the target and that a unit inherited a
  # usable environment.
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
      };
      listener = [
        {
          timeout = 900;
          on-timeout = "loginctl lock-session";
        }
      ];
    };
  };

  # Qt6, and so the cheapest proof that quickshell will draw in spec 2.
  services.hyprpolkitagent.enable = true;

  programs.home-manager.enable = true;
}
```

- [ ] **Step 2: Run the check that must fail before the build**

```bash
cd ~/Projects/calango-nix
ls result 2>&1
```

Expected: `ls: cannot access 'result': No such file or directory`

- [ ] **Step 3: Build the activation package**

```bash
cd ~/Projects/calango-nix
nix build .#homeConfigurations."nixtest@suffer".activationPackage
```

Expected: a `result` symlink into `/nix/store`. This downloads a large
closure and takes time. It does not change the running system.

If `nerd-fonts.adwaita-mono` fails to resolve, the attribute path changed
between releases. Find the right one with
`nix search nixpkgs nerd-fonts adwaita` and correct the module.

- [ ] **Step 4: Check the versions in the closure**

```bash
cd ~/Projects/calango-nix
nix path-info -r ./result \
  | grep -oP '(?<=/nix/store/[a-z0-9]{32}-)(xdg-desktop-portal-hyprland|hyprland|hypridle|hyprlock|uwsm|foot)-[0-9][^/]*$' \
  | sort -u
```

The lookbehind anchors the name immediately after the store hash, so a
package cannot match inside another package's name. Without it,
`xdg-desktop-portal-hyprland-1.3.12` also matches a search for `hyprland`,
and the check silently reports the portal's version as the compositor's. The
alternation lists the long name first for the same reason.

Expected, from the spec's table: `hyprland-0.55.4`, `uwsm-0.26.4`,
`hyprlock-0.9.5`, `foot-1.27.0`, `xdg-desktop-portal-hyprland-1.3.12`.

A different patch version is fine and worth noting. A different minor version
means the pin moved, and you should say so before continuing.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/calango-nix
git add home/default.nix
git commit -m "home: the eight backports refugees, a terminal, the fonts and the GL wrapper"
```

---

### Task 5: A minimal Hyprland configuration and the wrapped compositor

**Files:**
- Modify: `home/session.nix` (replace the stub from Task 2)

**Interfaces:**
- Consumes: `pkgs.nixgl.nixGLIntel` and `pkgs.hyprland` from Task 4.
- Produces: an executable `hyprland-nixgl` on `PATH`, which runs Hyprland
  under the GL wrapper; and `~/.config/hypr/hyprland.conf`, a minimal
  configuration with `SUPER+Q` bound to `foot`.

Hyprland writes a default configuration on first launch if none exists, and
that default binds `SUPER+Q` to `kitty`, which this project does not install.
So the configuration is supplied rather than left to the default.

- [ ] **Step 1: Write the module**

Replace `home/session.nix`:

```nix
{ pkgs, lib, ... }:

let
  # Wrap the compositor itself rather than the caller. A wrapper on the
  # binary survives being launched by uwsm through a systemd unit, which a
  # wrapper on the session entry may not -- a unit does not inherit the
  # environment of whoever invoked uwsm unless uwsm exports it. Task 6
  # measures which of the two is actually needed.
  # The binary is spelled Hyprland here. calango-desktop's DEPS table probes
  # both "Hyprland" and "hyprland" because upstream has renamed it between
  # versions, so check before trusting this:
  #     ls "$(nix build --no-link --print-out-paths nixpkgs#hyprland)/bin"
  # and correct the spelling if 26.05 disagrees.
  hyprland-nixgl = pkgs.writeShellScriptBin "hyprland-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel ${pkgs.hyprland}/bin/Hyprland "$@"
  '';
in
{
  home.packages = [ hyprland-nixgl ];

  # Minimal, deliberately. The real configuration is spec 2.
  home.file.".config/hypr/hyprland.conf".text = ''
    monitor = , preferred, auto, 1

    $mod = SUPER
    $terminal = foot

    bind = $mod, Q, exec, $terminal
    bind = $mod, C, killactive
    bind = $mod, M, exit

    # No keyboard layout is set here. suffer's real layout arrives with the
    # rest of the configuration in spec 2; the default is us.

    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
    }
  '';
}
```

- [ ] **Step 2: Rebuild**

```bash
cd ~/Projects/calango-nix
nix build .#homeConfigurations."nixtest@suffer".activationPackage
```

Expected: builds without error.

- [ ] **Step 3: Check the wrapper script says what it should**

```bash
cat "$(find ./result -name hyprland-nixgl -type f | head -1)"
```

Expected: a two-line shell script whose `exec` line names a `nixGLIntel`
store path followed by a `hyprland` store path.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/calango-nix
git add home/session.nix
git commit -m "session: wrap the compositor, not the caller, and bind a terminal that exists"
```

---

### Task 6: The first session, and which GL rung it needs

**Files:**
- Create: `docs/2026-08-14-results-suffer-nix-session.md`

**Interfaces:**
- Consumes: everything from Tasks 1 to 5.
- Produces: a recorded answer to the spec's open item "Is `nixGL` needed at
  all?", and the decision about where the wrapper goes.

This task is the one that can fail in a way that changes the design. It runs
a ladder of three rungs and stops at the first that works.

- [ ] **Step 1: Activate Home Manager as `nixtest`** **[KEYBOARD]**

`Ctrl+Alt+F2`, log in as `nixtest`, then:

```bash
git clone /home/isutton/Projects/calango-nix ~/calango-nix 2>/dev/null \
  || echo "clone by hand if /home/isutton is 0700"
cd ~/calango-nix
nix run home-manager/release-26.05 -- switch --flake .#nixtest@suffer
```

`/home/isutton` is mode `0700`, so the clone will fail. If it does, copy the
repository across with `sudo`, or push it to a path both accounts can read.
Record which you did.

Before any of that, give `nixtest` its own flakes setting. Task 1 step 4 wrote
`~/.config/nix/nix.conf`, and that file is per-user: without it the first
command here fails with `experimental Nix feature 'nix-command' is disabled`.

```bash
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
```

This stays a hand-written file rather than becoming `nix.settings` in
`home/default.nix`, and deliberately. Home Manager is invoked *through* a
flake, so the setting has to exist before Home Manager can run at all —
managing it from inside would be circular. It would also collide on the way
in: Home Manager refuses to overwrite a file it does not own, so a machine
that already has the hand-written copy would fail activation with
`Existing file '/home/…/.config/nix/nix.conf' would be clobbered`.

Expected: `Activating ...` lines, ending without error.

- [ ] **Step 2: Check the profile carries what it should**

```bash
ls ~/.nix-profile/bin/ | grep -iE '^(hyprland|uwsm|foot|hyprlock|nixGLIntel|hyprland-nixgl)$'
ls ~/.nix-profile/share/wayland-sessions/
```

Expected: all six binaries, and `hyprland.desktop` in the sessions directory.

The match is case-insensitive on purpose. The compositor's binary has been
spelled both `Hyprland` and `hyprland` across versions, which is why
calango-desktop's `DEPS` table probes for both. Note which spelling 26.05
uses, and make Task 5's wrapper agree with it.
`hyprland.desktop` is what `uwsm` resolves the compositor by, so its absence
stops Task 8 before it starts.

- [ ] **Step 3: Rung 1 — no wrapper at all**

Still on `tty2`, as `nixtest`:

```bash
Hyprland 2>~/rung1.log
```

Read `~/rung1.log` afterwards.

- **If Hyprland draws:** `nixGL` is unnecessary on this hardware. Record it.
  This contradicts the upstream wiki, which says a Nix Hyprland "won't be
  able to find graphics drivers", so it is worth stating loudly.
- **If it fails with `libGL error` or `failed to load driver`:** expected.
  Go to rung 2.

Leave Hyprland with `SUPER+M`.

- [ ] **Step 4: Rung 2 — the wrapped compositor**

```bash
hyprland-nixgl 2>~/rung2.log
```

Expected: Hyprland draws a bare desktop. `SUPER+Q` opens `foot`. `SUPER+M`
exits.

If `foot` opens but Hyprland did not draw, the fault is GL and not the
session. If neither appears, read `~/rung2.log` before going on.

- [ ] **Step 5: Rung 3 — under uwsm, which is how it will really start**

```bash
XDG_DATA_DIRS="$HOME/.nix-profile/share:$XDG_DATA_DIRS" \
  uwsm start -e -D Hyprland hyprland.desktop
```

Expected: the same desktop.

This is the rung that matters, because it is what the session entry in Task 8
runs. It also tests the claim in the spec's section 5 — that a wrapper
survives `uwsm` putting the compositor into a systemd unit.

`hyprland.desktop` comes from the Nix profile, which is why `XDG_DATA_DIRS`
is set on the command line here. Task 8 gets it from the login shell instead.

- [ ] **Step 6: Record the answer**

Create `docs/2026-08-14-results-suffer-nix-session.md`. Fill in what actually
happened; do not copy an expected result.

````markdown
# suffer: a Nix Hyprland on Debian 13

Date: 2026-08-14
Hardware: AMD Phoenix3 [1002:1900], Mesa 25.0.7 from Debian trixie.

## Does it need nixGL?

| Rung | Command | Result |
|---|---|---|
| 1 | `Hyprland` | |
| 2 | `hyprland-nixgl` | |
| 3 | `uwsm start -e -D Hyprland hyprland.desktop` | |

Answer:

## What the logs said

```
(paste the first error from rung1.log, if any)
```

## The repository copy

`/home/isutton` is 0700, so `nixtest` cannot clone from it. What was done
instead:
````

- [ ] **Step 7: Return to the live session and confirm it is undamaged** **[KEYBOARD]**

`Ctrl+Alt+F7`. Confirm the calango-desktop session still runs, the bar draws,
and `SUPER+Q` opens a terminal.

- [ ] **Step 8: Commit**

```bash
cd ~/Projects/calango-nix
git add docs/2026-08-14-results-suffer-nix-session.md
git commit -m "results: which GL rung a Nix Hyprland needs on an AMD Debian box"
```

---

### Task 7: The four proofs the session is real

**Files:**
- Modify: `docs/2026-08-14-results-suffer-nix-session.md`

**Interfaces:**
- Consumes: a running session from Task 6, started at whichever rung worked.
- Produces: evidence that Qt6 draws, that a user unit runs, and that the
  portal is reachable — the three things spec 2 depends on.

Run all four inside the session, from a `foot` window opened with `SUPER+Q`.

- [ ] **Step 1: Qt6 draws**

```bash
systemctl --user status hyprpolkitagent.service --no-pager
pkexec true
```

Expected: the unit is `active (running)`, and `pkexec` raises a graphical
password dialog rather than falling back to the terminal.

This is the cheapest available proof that quickshell will draw in spec 2,
because both are Qt6 on the same Nix Qt.

- [ ] **Step 2: a user unit inherited a working environment**

```bash
systemctl --user is-active graphical-session.target
systemctl --user is-active hypridle.service
systemctl --user show-environment | grep -E 'XDG_DATA_DIRS|WAYLAND_DISPLAY'
```

Expected: both `active`; `WAYLAND_DISPLAY` is set; `XDG_DATA_DIRS` contains a
path under `/home/nixtest/.nix-profile`.

`graphical-session.target` being active is what proves `uwsm` did its job.
calango-desktop's four units all hang off it, so spec 2 fails without this.

- [ ] **Step 3: the portal backend is reachable**

```bash
busctl --user list | grep -i portal
```

Expected: a line for `org.freedesktop.impl.portal.desktop.hyprland`.

If it is missing, the Nix backend's `.portal` file is not on the
`XDG_DATA_DIRS` that `xdg-desktop-portal` saw when it started. Check with:

```bash
ls ~/.nix-profile/share/xdg-desktop-portal/portals/
```

- [ ] **Step 4: the fonts resolve**

```bash
fc-match "Adwaita Sans"
fc-match "AdwaitaMono Nerd Font"
```

Expected: each names a file under `~/.local/share/fonts` or `/nix/store`, not
a fallback such as `DejaVuSans.ttf`.

A silent fallback here would look in spec 2 like a broken shell layout, so it
is worth catching now.

- [ ] **Step 5: Append the results**

Add to `docs/2026-08-14-results-suffer-nix-session.md`:

````markdown
## The four proofs

| Check | Command | Result |
|---|---|---|
| Qt6 draws | `pkexec true` | |
| graphical-session.target | `systemctl --user is-active graphical-session.target` | |
| a unit runs | `systemctl --user is-active hypridle.service` | |
| portal reachable | `busctl --user list \| grep portal` | |
| fonts resolve | `fc-match "Adwaita Sans"` | |
````

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/calango-nix
git add docs/2026-08-14-results-suffer-nix-session.md
git commit -m "results: Qt6, the session target, the portal and the fonts"
```

---

### Task 8: The greeter offers both sessions

**Files:**
- Create: `system/hyprland-nix.desktop`
- Modify: `system/README.md`

**Interfaces:**
- Consumes: a session proven to start in Task 6, at rung 3.
- Produces: a third entry in `tuigreet`, and a login path that does not
  involve a VT or a shell.

- [ ] **Step 1: Run the check that must fail**

```bash
ls /usr/local/share/wayland-sessions/ 2>&1
```

Expected: `No such file or directory`. This directory is already in the
greeter's `--sessions` list and has never existed.

- [ ] **Step 2: Write the entry**

Create `system/hyprland-nix.desktop`:

```
[Desktop Entry]
Name=Hyprland (Nix)
Comment=calango-nix
Type=Application
DesktopNames=Hyprland
Exec=/bin/sh -lc 'exec "$HOME/.nix-profile/bin/uwsm" start -e -D Hyprland hyprland.desktop'
```

Three things about that `Exec` line, all deliberate:

- It matches the apt entry on this machine, which reads
  `Exec=uwsm start -e -D Hyprland hyprland.desktop`.
- `$HOME` is resolved after login. greetd runs as `_greetd` and cannot read
  inside `/home/isutton`, which is mode `0700`, so no absolute path into a
  home directory can be written here.
- `sh -lc` starts a login shell, so the Nix profile is on `PATH` and
  `XDG_DATA_DIRS` before `uwsm` looks for `hyprland.desktop`.

- [ ] **Step 3: Install it** **[KEYBOARD]**

```bash
cd ~/Projects/calango-nix
sudo install -Dm644 system/hyprland-nix.desktop \
  /usr/local/share/wayland-sessions/hyprland-nix.desktop
```

- [ ] **Step 4: Check the greeter lists three sessions** **[KEYBOARD]**

Log out of the live desktop. At `tuigreet`, open the session picker.

Expected: `Hyprland`, `Hyprland (uwsm-managed)` and `Hyprland (Nix)`.

The first two are the apt entries and must still be there. If they are gone,
stop: something has changed `/etc/greetd/config.toml`, which this plan does
not do.

- [ ] **Step 5: Log in as `nixtest` through the greeter** **[KEYBOARD]**

Choose `Hyprland (Nix)`. Log in as `nixtest`.

Expected: the same bare desktop as Task 6, reached with no VT and no shell.

- [ ] **Step 6: Check the keyring, which fails silently**

In a `foot` window:

```bash
systemctl --user is-active gnome-keyring-daemon 2>/dev/null; \
  secret-tool store --label=probe calango probe <<<'x' && \
  secret-tool lookup calango probe
```

Expected: `x` comes back.

This check is here because it is the one failure with no symptom.
`/etc/pam.d/greetd` references `pam_gnome_keyring.so` with a leading `-`,
which PAM defines as "skip without complaint if the module is missing". A
broken keyring produces no error anywhere — saved passwords simply come back
empty, hours later. Do not check this by looking at the screen.

Clean up: `secret-tool clear calango probe`.

- [ ] **Step 7: Log back into the apt session and confirm it is unharmed** **[KEYBOARD]**

Log out. Choose `Hyprland (uwsm-managed)`. Log in as `isutton`.

Expected: the full calango-desktop session, exactly as before.

- [ ] **Step 8: Record the undo in the system README**

Append to `system/README.md`:

````markdown
## Undo, in full

```sh
sudo rm /usr/local/share/wayland-sessions/hyprland-nix.desktop
sudo deluser --remove-home nixtest
```

That is the whole root-owned footprint. Everything else lives in `$HOME` and
`/nix`.
````

- [ ] **Step 9: Commit**

```bash
cd ~/Projects/calango-nix
git add system/hyprland-nix.desktop system/README.md
git commit -m "greeter: a third session entry, and no edit to greetd's config"
```

---

### Task 9: Port `isutton`

**Files:**
- Modify: `docs/2026-08-14-results-suffer-nix-session.md`

**Interfaces:**
- Consumes: `homeConfigurations."isutton@suffer"` from Task 2, and a session
  proven end to end in Task 8.
- Produces: `isutton` logging into the Nix session. The apt session stays in
  the greeter as a fallback, and `trixie-backports` stays in `sources.list`.

This is the first task with real risk, because it is the first collision.
Read `~/Projects/calango-desktop/install.sh:99-150` for the exact map.
`install.sh` links **six directories** — `quickshell`, `hypr`, `kitty`,
`foot`, `lf`, `uwsm` under `$XDG_CONFIG_HOME` — and **14 individual files**,
five of which are systemd user units in `~/.config/systemd/user`. Home
Manager writes its own units to that same directory.

- [ ] **Step 0: Predict the collisions before changing anything**

The clobber in step 4 is the only part of this task that cannot simply be
undone, so find it in advance. This is read-only and needs no session.

```bash
cd ~/Projects/calango-nix
nix build --out-link result-isutton .#homeConfigurations."isutton@suffer".activationPackage
find -L result-isutton/home-files \( -type f -o -type l \) | sed 's|result-isutton/home-files/||' |
  while read -r f; do
    t="$HOME/$f"
    [ -e "$t" ] || [ -L "$t" ] || continue
    if [ -L "$t" ]; then printf '%-56s SYMLINK -> %s\n' "$f" "$(readlink "$t")"
    else printf '%-56s REGULAR FILE\n' "$f"; fi
  done
```

`home-files/` is the exact tree Home Manager will link into `$HOME`, so
anything this prints is a file activation would refuse to overwrite.

On `suffer` it printed one line, `.config/hypr/hypridle.conf`, and that one
is not a real collision: `~/.config/hypr` is a symlink into the
calango-desktop checkout, so `readlink -f` resolves the file to
`~/Projects/calango-desktop/hypr/hypridle.conf` and step 2 removes the path
along with the symlink. Run this again after step 2 and it should print
nothing.

Note also that calango-desktop's compositor config is `hyprland.lua`, not
`hyprland.conf`, so `home/session.nix` does not collide with it either.

This step exists because `nixtest` cannot stand in for it. A throwaway account
has none of the dotfiles that make step 4 risky, so rehearsing there proves
nothing about the collision surface. Predicting it does.

- [ ] **Step 1: Record what is linked now**

```bash
find ~/.config ~/.local/share/applications ~/.local/bin -maxdepth 4 -type l \
  -lname '*calango-desktop*' 2>/dev/null | sort | tee ~/pre-port-links.txt | wc -l
```

Expected: 24 lines. Keep the file; step 4 compares against it.

`-maxdepth 4`, not 3. Two of install.sh's 20 destinations sit four levels
below `~/.config` — `systemd/user/quickshell.service.d/killmode.conf` and
`pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf` — so a depth-3
search finds 19 and reads as a missing link when nothing is missing.

The other four are not install.sh's at all, and they are the reason this step
matters. `systemctl --user enable` wrote them:

```
~/.config/systemd/user/graphical-session.target.wants/
  bt-agent.service        -> ~/Projects/calango-desktop/hypr/systemd/bt-agent.service
  night-light.service     -> ~/Projects/calango-desktop/hypr/systemd/night-light.service
  nm-secret-agent.service -> ~/Projects/calango-desktop/hypr/systemd/nm-secret-agent.service
  quickshell.service      -> ~/Projects/calango-desktop/hypr/systemd/quickshell.service
```

They point *absolutely into the calango-desktop checkout*, bypassing the
links in `~/.config/systemd/user` entirely. `install.sh --uninstall` does not
know about them, so it will not remove them, and because the checkout stays
they will not dangle either. See step 3.

- [ ] **Step 2: Unlink calango-desktop**

```bash
cd ~/Projects/calango-desktop
./install.sh --uninstall
```

This unlinks all 20 and restores the default browser handler it recorded when
it was installed. It does not touch the repository checkout, so nothing is
lost.

- [ ] **Step 3: Check nothing is left behind**

```bash
find ~/.config ~/.local/share/applications ~/.local/bin -maxdepth 4 -type l \
  -lname '*calango-desktop*' 2>/dev/null
find ~/.config/systemd/user -xtype l 2>/dev/null
```

Expected: the four `graphical-session.target.wants` links and nothing else,
then no output. The second command finds dangling symlinks, which is the
failure mode that would make `home-manager switch` fail in a confusing way.

Then disable the four, which is what actually removes them:

```bash
systemctl --user disable quickshell.service night-light.service \
  nm-secret-agent.service bt-agent.service
find ~/.config ~/.local/share/applications ~/.local/bin -maxdepth 4 -type l \
  -lname '*calango-desktop*' 2>/dev/null | wc -l
```

Expected: `0`.

Do not skip this. `graphical-session.target` is the target `uwsm` creates, so
leaving the four enabled means the Nix session starts calango-desktop's
quickshell, night-light, nm-secret-agent and bt-agent out of the old checkout
— which is precisely the "no calango-desktop QML, no theme, no bar" that
Global Constraint 8 rules out of spec 1, and it would arrive looking like a
half-working desktop rather than a mistake. `--uninstall` does not do it,
because it never created these links.

- [ ] **Step 4: Activate Home Manager for `isutton`**

```bash
cd ~/Projects/calango-nix
nix run home-manager/release-26.05 -- switch --flake .#isutton@suffer
```

Expected: activation completes with no `Existing file ... would be clobbered`
error.

If it does report a clobber, the named file is one `install.sh --uninstall`
did not own. Move it aside, do not delete it, and record which file it was —
that is information spec 2 needs.

- [ ] **Step 5: Log into the Nix session as `isutton`** **[KEYBOARD]**

Log out. Choose `Hyprland (Nix)`. Log in as `isutton`.

Expected: the bare desktop from Task 6. **Not** the calango desktop — there
is no bar, no theme and no launcher. That is the correct result for spec 1,
and spec 2 is what fills it in.

- [ ] **Step 6: Check the fallback still works** **[KEYBOARD]**

Log out. Choose `Hyprland (uwsm-managed)`. Log in as `isutton`.

Expected: a Hyprland with no calango configuration, because the symlinks were
removed in step 2. To get the old desktop back in full:

```bash
cd ~/Projects/calango-desktop && ./install.sh
```

State plainly in the results document that from this task onward, the apt
session is a bare compositor rather than the old desktop, unless `install.sh`
is run again. That is the real cost of step 2 and it should not be a surprise
later.

- [ ] **Step 7: Append the results**

Add to `docs/2026-08-14-results-suffer-nix-session.md`:

````markdown
## Porting isutton

- Symlinks before `--uninstall`:      (count)
- Symlinks after:                     (count)
- Dangling links in systemd/user:     (count)
- Clobber errors from home-manager:   (list, or none)
- Nix session as isutton:             (result)
- apt session as isutton:             (result — bare, unless install.sh is re-run)
````

- [ ] **Step 8: Commit**

```bash
cd ~/Projects/calango-nix
git add docs/2026-08-14-results-suffer-nix-session.md
git commit -m "port: isutton onto the Nix session, with the apt one still in the greeter"
```

---

## Where this plan stops

At the end of Task 9, `isutton` logs into a stock Hyprland from Nix, on a
Debian 13 machine, with `trixie-backports` still configured and the apt
session still offered by the greeter.

There is no bar, no launcher, no theme, no notifications and no keybinds
beyond three. That is the intended result.

Spec 2 ports the configuration and moves the 19 runtime-written files out of
`~/.config`. Spec 3 removes `trixie-backports`, deletes `nixtest`, and adds
the update and rollback workflow.

## Open items this plan does not close

- **`swww` in nixpkgs.** Two probes of the `search.nixos.org` backend found
  no such attribute. `swaybg` 1.2.2 is there and is what calango-desktop's
  `either` row installs. Spec 2's problem.
- **Vulkan.** `nixGLIntel` covers OpenGL. Qt Quick can be driven onto Vulkan
  through `QSG_RHI_BACKEND`, and quickshell is Qt Quick. If spec 2 needs it,
  `nixVulkanIntel` is the matching wrapper, exposed by the same overlay.
- **How `nixtest` gets the repository.** `/home/isutton` is mode `0700`, so a
  clone across accounts fails. Task 6 step 1 records whatever was done
  instead. Task 9 makes the question moot.
