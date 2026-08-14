# calango-nix: the base and the session

Date: 2026-08-14
Status: draft, awaiting review

This is spec 1 of three. It covers the Debian base and a working Hyprland
session from Nix, with a stock configuration and none of calango-desktop's
QML. Spec 2 ports the configuration and separates state from it. Spec 3
covers the theme writers, the per-host layer, the update workflow, and the
removal of `trixie-backports`.

## Problem

calango-desktop runs on Debian 13 and needs `trixie-backports`. The
requirement is not a convenience: seven of its dependencies exist in no other
suite. Measured on `suffer` with `apt-cache madison` over all 56 Debian names
in the `DEPS` table:

| Package | trixie | trixie-backports |
|---|---|---|
| `hyprland` | — | 0.55.2 |
| `quickshell` | — | 0.3.0 |
| `hypridle` | — | 0.1.7 |
| `hyprlock` | — | 0.9.5 |
| `hyprpolkitagent` | — | 0.1.3 |
| `uwsm` | — | 0.26.4 |
| `ydotool` | — | 1.0.4 |

`xdg-desktop-portal-hyprland` 1.3.12 is backports-only too, and the `DEPS`
table does not name it.

Every other name in the table resolves in `trixie`, `trixie-updates` or
`trixie-security`.

The goal is a desktop with no backports suite, on two machines, both Debian 13
and both AMD. Debian keeps the vendor stack that has to be native: Google
endpoint-verification, docker-ce, 1Password, Google Chrome, and — already
present in `sources.list` on `suffer` — Signal and VS Code.

## The rule

> **apt owns what needs root. Nix owns everything else.**

The rule is chosen because it is the only line that does not need arguing case
by case. It also predicts the exceptions correctly: PAM, the greeter, udev
device permissions and the `nix-daemon` itself all fall on the apt side
without a special case.

## Decisions

**1. Nix comes from apt.** `nix-bin` 2.26.3 and `nix-setup-systemd` 2.26.3 are
in `trixie`. `nix-daemon` is a root service, so the rule puts it on the apt
side, and apt keeps it patched. 2.26.3 supports flakes. The upstream installer
would add a component apt knows nothing about.

**2. Home Manager, as a standalone flake.** There is no NixOS here, so the
NixOS module does not apply. Home Manager owns the user layer and nothing
else.

**3. Hyprland comes from nixpkgs 26.05.** It is 0.55.4 there, against 0.55.2 in
backports. More important than the version: `hypridle`, `hyprlock`,
`hyprpolkitagent` and `xdg-desktop-portal-hyprland` come from the same tree,
so the portal backend cannot drift from the compositor. `hyprnix` and the
`hyprwm/Hyprland` flake both build the unstable branch and want Cachix.

**4. `uwsm` starts the session, not `start-hyprland`.** The Hyprland wiki
documents `start-hyprland` for non-NixOS hosts. calango-desktop has four
systemd user units — `quickshell.service`, `night-light.service`,
`nm-secret-agent.service`, `bt-agent.service` — and all are
`WantedBy=graphical-session.target`, which `uwsm` creates. `start-hyprland`
would cost the unit model that spec 2 depends on.

**5. `nixGL` provides the GL stack, and it can stay pure.** Both machines are
AMD, so Mesa `radeonsi`. The nixGL README describes `nixGLIntel` as the "Mesa
OpenGL implementation (intel, amd, nouveau, ...)". That wrapper is not under
the `auto.` prefix, so it needs no hardware detection and no `--impure`. The
`auto.*` wrappers exist for the proprietary NVIDIA case, which does not apply
here. This is an inference from the README rather than a measurement, and
phase 2 confirms it. A pure build was not a requirement — impurity was
accepted up front — so if the inference is wrong, `auto.nixGLDefault` with
`--impure` is the fallback and nothing else in this spec changes.

**6. nixGL is pinned to the same nixpkgs as everything else.** The nixGL
README reports a `GLIBC_2.34 not found` failure and names the cause: "a
mismatch between the versions of `nixpkgs` used by `nixGL` and `program`". So
the flake overrides nixGL's `nixpkgs` input to the same 26.05 the rest of the
closure uses. This is not optional.

**7. calango-desktop is a reference, not an input.** It is read by a person,
never by the build. It keeps `install.sh`, keeps `trixie-backports`, and does
not change. The two repositories will diverge, and that is accepted.

**8. The session entry is one root-owned file.** `/home/isutton` is mode
`0700` and greetd runs as `_greetd`, so the greeter cannot read a `.desktop`
file inside a home directory. One file in `/usr/local/share/wayland-sessions`
is the whole system-side footprint of this project.

## Non-goals

- Porting calango-desktop's configuration. That is spec 2.
- Removing `trixie-backports`. That is spec 3, and it is the last step, not
  the first.
- Touching `epiphany`. It follows once `suffer` proves this.
- NixOS. Debian stays the base.
- Any change to the calango-desktop repository.

## Design

### 1. What stays on apt

- **Vendor:** Google Chrome, docker-ce, 1Password, Google endpoint-verification,
  Signal, VS Code.
- **Nix itself:** `nix-bin`, `nix-setup-systemd`.
- **The login path:** `greetd` 0.10.3, `tuigreet` 0.9.1, both in `trixie`.
- **PAM and the keyring:** `libpam-gnome-keyring`, `gnome-keyring`. A PAM
  module is loaded into a Debian process by Debian's `libpam`, so it must come
  from the same C library.
- **System services:** NetworkManager, pipewire, wireplumber, polkitd, upower,
  power-profiles-daemon, bluez.
- **Device permissions:** `brightnessctl`, `ddcutil`. Both depend on a udev
  rule and a group.
- **The portal frontend:** `xdg-desktop-portal` 1.20.3. nixpkgs carries 1.20.4,
  so the frontend and the Nix backend stay in the same series.
- **Mesa 25.0.7 and the kernel.**

### 2. What Nix provides in this spec

Deliberately minimal. Spec 1 proves a session boots; it does not furnish one.

| Package | nixpkgs 26.05 | Why it is here |
|---|---|---|
| `hyprland` | 0.55.4 | the compositor |
| `uwsm` | 0.26.4 | starts the session, creates `graphical-session.target` |
| `xdg-desktop-portal-hyprland` | 1.3.12 | screencast and file dialogs |
| `hypridle` | 0.1.7 | proves a user unit runs under the Nix session |
| `hyprlock` | 0.9.5 | the lock screen `hypridle` calls |
| `hyprpolkitagent` | 0.1.3 | proves a Qt6 application from Nix draws |
| `nixGLIntel` | — | the GL stack |
| `foot` | 1.27.0 | a terminal, so the session can be used and checked |
| `adwaita-fonts` | 50.0 | the sans and mono families spec 2 needs |
| `nerd-fonts.adwaita-mono` | 3.4.0 | the glyph font the bar needs |

`hyprpolkitagent` earns its place beyond parity: it is Qt6, and quickshell is
Qt6. If it draws, spec 2's main risk is already retired.

`ydotool` is deferred to spec 3. It is `dev` tier and nothing at runtime uses
it.

### 3. Repository layout

```
~/Projects/calango-nix/
  flake.nix              inputs: nixpkgs 26.05, home-manager, nixgl
  flake.lock
  home/
    default.nix          the package set
    session.nix          the nixGL wrapper and the uwsm entry
  system/
    hyprland-nix.desktop the session entry, installed by hand
    README.md            the two root commands, and how to undo them
  docs/superpowers/specs/
  README.md
```

`system/` is the only directory whose contents leave `$HOME`, and it holds one
file. Keeping it visible is the point: a reader can see the whole root-owned
footprint without reading any Nix.

### 4. The flake, in sketch

Not the implementation. It fixes the two things that are easy to get wrong —
the nixGL input override, and the fact that Home Manager is standalone.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";   # decision 6
    };
  };
  # outputs.homeConfigurations."<user>@<host>"
}
```

`inputs.nixpkgs.follows` on nixGL is what prevents the glibc mismatch. Without
it, nixGL builds against its own pinned nixpkgs and the wrapper fails at
runtime rather than at build time.

### 5. How nixGL wraps

`nixGL` sets library search paths in the environment of the process it wraps.
Children inherit that environment. So wrapping the compositor at the session
entry should cover the compositor and everything it launches, including the
systemd user units, because `uwsm` imports the environment into the user
manager.

**That claim is the single most important thing this spec must verify, and it
is not yet verified.** Phase 2 tests it directly. If it turns out that
children do not inherit a usable GL environment, the fallback is to wrap each
GL consumer individually, which is one extra line per unit and no change to
the design.

### 6. The session entry

The apt entry on `suffer` reads:

```
Exec=uwsm start -e -D Hyprland hyprland.desktop
```

`uwsm` resolves the compositor from a desktop entry name, so the Nix profile's
`share/wayland-sessions` must be on `XDG_DATA_DIRS` when `uwsm` runs. The new
entry therefore starts a login shell, so that the profile is on the path
before `uwsm` is reached:

```
[Desktop Entry]
Name=Hyprland (Nix)
Comment=calango-nix
Type=Application
DesktopNames=Hyprland
Exec=/bin/sh -lc 'exec "$HOME/.nix-profile/bin/uwsm" start -e -D Hyprland hyprland.desktop'
```

`Exec` resolves `$HOME` after login, which is required: greetd runs as
`_greetd` and cannot read inside a `0700` home directory before authentication.

It is installed by hand:

```sh
sudo install -Dm644 system/hyprland-nix.desktop \
  /usr/local/share/wayland-sessions/hyprland-nix.desktop
```

**`/etc/greetd/config.toml` needs no change.** It already runs
`tuigreet --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions`,
and the second directory does not yet exist. Undo is `sudo rm` of that one
file.

### 7. Environment and discovery

Three things must be visible to processes started outside the Nix profile.
All three hang off `XDG_DATA_DIRS`, and all three are set by `uwsm` before
`graphical-session.target` is reached:

1. **The portal backend.** `xdg-desktop-portal` (apt) reads
   `share/xdg-desktop-portal/portals/*.portal` from every entry in
   `XDG_DATA_DIRS`. The Nix backend ships its file inside the profile.
2. **D-Bus activation.** The session bus reads `share/dbus-1/services` from
   `XDG_DATA_DIRS` when it starts. `uwsm` calls
   `dbus-update-activation-environment`, which is the standard answer, but the
   ordering against `dbus.socket` in the user manager is a real hazard and
   phase 2 checks it.
3. **Fonts.** Home Manager's `fonts.fontconfig.enable` links fonts into
   `~/.local/share/fonts` and writes a fontconfig snippet. Both Nix and Debian
   applications then find the three families.

## Verification

Four phases, on `suffer`. Phases 1 to 3 leave the working desktop exactly as
it is today; the choice between the two setups is not made until phase 4.

Two facts on `suffer` make this safe, and both are already true:
`/usr/local/share/wayland-sessions` is in the greeter's `--sessions` list and
does not exist; and `tty1` is deliberately left to a getty, described in
`greetd/config.toml` as "the rescue console this change most needs". greetd
holds VT7.

### Phase 1 — build only

`sudo apt install nix-bin nix-setup-systemd`, add the account to the
`nix-users` group, then `nix build` the flake.

Passes when: the closure builds, and `~/.config` is unchanged. Nothing enters
the running session.

### Phase 2 — a session on a spare VT, as a second user

Create `nixtest`. Log in on `tty2`, run `home-manager switch`, then start the
session by hand. `$HOME` is separate, so nothing `install.sh` linked under
`isutton` is ever in play. `/nix` is shared, so the account costs no disk.

Passes when all of:

1. Hyprland draws, and `foot` opens in it.
2. `hyprpolkitagent` runs and draws a dialog — the Qt6 proof.
3. `systemctl --user status hypridle` is active, which proves `uwsm` built
   `graphical-session.target` and that a unit inherited a usable environment.
4. `busctl --user list` shows `org.freedesktop.impl.portal.desktop.hyprland`
   as activatable.
5. `Ctrl+Alt+F7` returns to the live apt session, and it is undamaged.

Failure at any point costs nothing: log out of `tty2`.

### Phase 3 — the greeter offers both

Install the one `.desktop` file. Log out of the apt session and log back in,
choosing each entry in turn.

Passes when: both sessions appear in `tuigreet`, both start, and the login
keyring unlocks in the Nix one. The keyring is worth naming because it is the
failure that is silent — `/etc/pam.d/greetd` references
`pam_gnome_keyring.so` with a leading `-`, so a broken keyring produces no
error anywhere. Check it with `secret-tool`, not by looking.

Undo: `sudo rm` the file.

### Phase 4 — port `isutton`

The first step with real risk, because it is the first collision. Read
`install.sh:99-150` for the exact map. It links **six directories** —
`quickshell`, `hypr`, `kitty`, `foot`, `lf`, `uwsm` under `$XDG_CONFIG_HOME` —
and **14 individual files**, of which five are the systemd user units:

```
$UNITS/quickshell.service          $UNITS/nm-secret-agent.service
$UNITS/quickshell.service.d/killmode.conf
$UNITS/bt-agent.service            $UNITS/night-light.service
```

Home Manager wants to own both sets. The units matter more than the
directories: Home Manager generates units into
`~/.config/systemd/user`, which is where those five symlinks already point.

Two of the 14 also reach outside `$HOME` in effect rather than in path —
`$BIN/code` shadows `/usr/bin/code`, and `data/code.desktop` replaces the
vendor VS Code entry. Both are restored by `--uninstall`.

Order: `./install.sh --uninstall` first, which unlinks all 20 and restores the
browser handler it recorded; then `home-manager switch`.

Reverse: re-run `./install.sh`.

Passes when: `ls -la ~/.config/systemd/user` shows no dangling link into the
calango-desktop checkout, and `home-manager switch` reports no collision.

Phase 4 is the boundary of this spec. What `isutton` gets at the end of it is
a stock Hyprland, not the calango desktop. Spec 2 is what makes it usable.

## Open items

- **Does `swww` exist in nixpkgs?** Two probes of the `search.nixos.org`
  backend found no `swww` attribute. `swaybg` 1.2.2 is there, and `swaybg` is
  what calango-desktop's `either` row actually installs. This belongs to spec
  2 and does not block spec 1.
- **Is `nixGL` needed at all?** Upstream states a Nix Hyprland "won't be able
  to find graphics drivers" outside NixOS. Phase 2 costs one command to test
  the unwrapped case first, and the answer is worth writing down.
- **Vulkan.** `nixGLIntel` covers OpenGL. Qt Quick can be driven onto Vulkan
  through `QSG_RHI_BACKEND`, and quickshell is Qt Quick. If spec 2 needs it,
  `nixVulkanIntel` is the matching wrapper. Nothing in spec 1 needs it.
- **The `nix-users` group.** Debian's `nix-setup-systemd` creates it; whether
  a new login is required before `nix build` works is unverified.
