# Glue `.deb` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Debian metapackage from this flake so the Debian side of the machine can be declared in Nix — which packages must stay, which must never come back, which ufw profiles and system files the Nix side needs Debian to own.

**Architecture:** `lib/deb.nix` is a pure function that turns a manifest into a `.deb`, mirroring `lib/nixgl.nix`. `home/deb.nix` declares a `calango.deb.*` option namespace that any module contributes to, assembles the merged manifest, and warns at switch time when the installed package is stale. `flake.nix` exposes the result as `packages.x86_64-linux.calangoDeb`. Nix builds, apt installs, dpkg enforces; no privileged step ever runs inside a switch.

**Tech Stack:** Nix flakes, standalone Home Manager `release-26.05`, `pkgs.dpkg` 1.23.7, Debian 13 `dpkg` 1.22.22, `ufw` 0.36.2.

**Spec:** `docs/superpowers/specs/2026-08-18-apt-glue-deb-design.md`

## Global Constraints

- Wrap **every** `nix` and `home-manager` invocation: `sg nix-users -c '...'`. A bare `nix` fails on the daemon socket directory and reads as a broken install.
- **No agent runs a privileged command.** No `apt`, `apt-get`, `dpkg`, `apt-mark`, `ufw` or `flatpak` mutation. No `systemctl start/stop/restart/enable/disable/daemon-reload`. No `home-manager switch`. No `reboot`. Never run the activation script without `DRY_RUN=1`. Read-only probes (`apt-get -s`, `dpkg-query`, `dpkg-deb`, `apt-cache`) are allowed and used throughout.
- `grep` in the interactive shell is a **ugrep-backed function** that silently returns `0` for a pattern containing `${`, even on a file that holds it. Use `/usr/bin/grep`, with `-F` for a literal, whenever a count is load-bearing. Inside a Nix builder the shell is the real one and this does not apply.
- Never read a package version from `nixpkgs#<pkg>` — that reads the flake registry (nixpkgs-unstable), not this flake's pinned input.
- **A flake build does not see untracked files.** `git add` any newly created file before building anything that must observe it, or a mutation test will appear to pass while testing nothing.
- Inside a Nix builder, `set -e` and `pipefail` are on. Put a `grep` whose zero-match case is the passing case in a **condition** (`if grep -q …; then`), never in a bare command or a command substitution.
- No path containing `.superpowers/` may appear in any committed file. Scratch probe expressions go outside the repository tree.
- The package name is `calango-desktop`. The maintainer is `Igor Sutton <igor.sutton@calangotech.eu>`.
- Every commit message ends with the two trailers used in this repo:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn`.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/deb.nix` | **create.** Pure `{ pkgs }` function. `build` turns a manifest into a `.deb` derivation; `driftCheck` turns a manifest into a comparison script. Knows `dpkg-deb`, knows nothing about this machine. |
| `home/deb.nix` | **create.** The `calango.deb.*` options, the entries with no natural owner, the merged manifest, `config.calango.debPackage`, the four guards, and the activation hook. |
| `flake.nix` | **modify.** Bind `self`, compute the version, add `./home/deb.nix` to the module list, pass `calango.deb.version`, expose `packages.${system}.calangoDeb`. |
| `home/audio.nix` | **modify.** Contribute `rtkit` and the nine `libpipewire-0.3-modules` packages to `calango.deb.keep`. |
| `home/syncthing.nix` | **modify.** Contribute the ufw profile and the two syncthing bans. |
| `home/session.nix` | **modify.** Contribute the greetd session file. |
| `CLAUDE.md` | **modify.** The four mechanism traps this work discovered. |

---

## Task 1: `lib/deb.nix` — the builder and the drift script

**Files:**
- Create: `lib/deb.nix`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `build = { manifest, manifestFile, version }: derivation` — output is a **directory** containing `calango-desktop_${version}_all.deb`.
  - `driftCheck = { manifestFile, banned }: derivation` — a `writeShellScript`. `banned` is a list of strings. Argument `$1` overrides the installed-manifest path, defaulting to `/usr/share/calango-desktop/manifest.json`.
  - `manifest` is an attrset with exactly the keys `keep`, `ban`, `ufwProfiles`, `files`; `keep` and `ban` are `attrsOf str` (package → reason), `ufwProfiles` and `files` are `attrsOf str` (name/path → content).

- [ ] **Step 1: Create `lib/deb.nix`**

```nix
# The one place that knows how to turn a declaration into a Debian package.
#
# A plain Nix function, NOT a Home Manager module -- the same shape and for the
# same reason as lib/nixgl.nix: flake.nix lists its modules one by one, so a
# file absent from that list is visibly not one.
#
# Two exports, and they are separate because of how each is TESTED. `build`
# produces an artifact an agent can inspect with dpkg-deb. `driftCheck`
# produces a script an agent can RUN. The comparison deliberately does not live
# inline in the activation hook: the activation script only runs under
# DRY_RUN=1 for anyone but the user, and DRY_RUN=1 makes `run` echo its
# argument instead of executing it -- so an inline body could never be executed
# by an implementer or a reviewer, and a guard nobody can run is a guard nobody
# can prove able to fail. This project has shipped three of those.
{ pkgs }:

let
  inherit (pkgs) lib;

  # Debian relationship fields are comma-separated. Sorted so the control file
  # is a function of the SET, not of attribute insertion order -- Nix already
  # stores attrsets sorted, but saying so here keeps the property local.
  field = name: names:
    lib.optionalString (names != [ ])
      "${name}: ${lib.concatStringsSep ", " (lib.sort (a: b: a < b) names)}\n";

  # A Debian extended description: every line prefixed with one space, and an
  # empty line spelled " .". A reason written as a multi-line Nix string would
  # otherwise inject a bare newline and truncate the field, so flatten first.
  descLine = s:
    " " + lib.concatStringsSep " "
      (lib.filter (x: x != "" ) (lib.splitString " "
        (lib.replaceStrings [ "\n" "\t" ] [ " " " " ] s)));

  reasonLines = attrs:
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList (n: why: descLine " * ${n}: ${why}") attrs);

  # Built by concatenation, the same idiom home/default.nix uses for the nixgl
  # needle. Written into the indented string directly this needs
  # `'''${db:Status-Abbrev}'` -- correct, unreadable, and exactly the kind of
  # thing a later editor "fixes" into a format string that silently returns
  # empty for every package.
  statusFmt = "$" + "{db:Status-Abbrev}";
in
{
  build =
    { manifest, manifestFile, version }:
    let
      control = ''
        Package: calango-desktop
        Version: ${version}
        Architecture: all
        Maintainer: Igor Sutton <igor.sutton@calangotech.eu>
        Section: metapackages
        Priority: optional
      ''
      + field "Depends" (builtins.attrNames manifest.keep)
      + field "Conflicts" (builtins.attrNames manifest.ban)
      + ''
        Description: calango-nix glue for the Debian side
         Declares the Debian packages this machine must keep, the ones it must
         not have, and the files and ufw profiles the Nix side needs Debian to
         own. Generated by calango-nix; do not edit by hand.
         .
         Depends is not decoration. It is what replaces `apt-mark manual` for
         these packages: a dependency of a manually-installed package cannot be
         taken by autoremove, and unlike a mark it carries its reason.
         .
         Kept:
        ${reasonLines manifest.keep}
         .
         Refused, because the Nix side owns them now:
        ${reasonLines manifest.ban}
      '';

      # Only /etc entries may be conffiles, per Debian policy. The ufw profiles
      # are the only /etc payload this package has.
      conffiles =
        lib.concatMapStrings (n: "/etc/ufw/applications.d/${n}\n")
          (builtins.attrNames manifest.ufwProfiles);
    in
    pkgs.runCommand "calango-desktop-${version}"
      {
        inherit control conffiles;
        passAsFile = [ "control" "conffiles" ];
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p pkg/DEBIAN pkg/usr/share/calango-desktop
        cp "$controlPath" pkg/DEBIAN/control
        cp ${manifestFile} pkg/usr/share/calango-desktop/manifest.json

        ${lib.optionalString (manifest.ufwProfiles != { }) ''
          mkdir -p pkg/etc/ufw/applications.d
          cp "$conffilesPath" pkg/DEBIAN/conffiles
        ''}
        ${lib.concatStrings (lib.mapAttrsToList (n: body: ''
          cp ${pkgs.writeText "ufw-profile-${n}" body} pkg/etc/ufw/applications.d/${n}
        '') manifest.ufwProfiles)}

        ${lib.concatStrings (lib.mapAttrsToList (path: body: ''
          mkdir -p "pkg/$(dirname ${path})"
          cp ${pkgs.writeText "debfile-${baseNameOf path}" body} "pkg/${path}"
        '') manifest.files)}

        # Reproducibility: with every mtime pinned, the archive is a function
        # of content alone. Proven by `nix build --rebuild`, step 4 of this task.
        #
        # Nix's stdenv sets SOURCE_DATE_EPOCH to 315532800, which is
        # 1980-01-01 UTC, and that is the only reason the timestamps read 1980.
        # dpkg-deb clamps NOTHING -- an earlier version of this comment said it
        # imposed a 1980 floor, which is a ZIP/FAT behaviour misattributed to
        # tar. Measured by reading a tar member's mtime with Python tarfile:
        # plain `@0` really does produce 0.
        #
        # chmod BEFORE touch: `cp` out of the store leaves files mode 444, and
        # the permission bits go into the archive exactly as they are here.
        chmod -R u+w,go-w pkg
        find pkg -exec touch -h -d @''${SOURCE_DATE_EPOCH:-0} {} +

        # $out is a DIRECTORY, not the file. apt needs a path ending in .deb
        # with a package-shaped name; a bare-file output gives ./result, which
        # `apt install` rejects.
        mkdir -p "$out"
        dpkg-deb --root-owner-group -Zxz --build pkg \
          "$out/calango-desktop_${version}_all.deb"
      '';

  driftCheck =
    { manifestFile, banned }:
    pkgs.writeShellScript "calango-deb-drift" ''
      want=${manifestFile}
      installed="''${1:-/usr/share/calango-desktop/manifest.json}"

      # Three outcomes, not two. A missing file makes `cmp` fail, so a check
      # that only asked "did cmp succeed" would report a package that was NEVER
      # INSTALLED identically to one that is merely stale. CLAUDE.md: a check
      # for a file's absence proves nothing unless you know every state the
      # file could be in. Spec 15 shipped exactly that mistake.
      if [ ! -e "$installed" ]; then
        echo "apt: calango-desktop is not installed." >&2
        echo "  The keep set is held only by apt-mark flags, and the ufw" >&2
        echo "  profiles and session entry this flake declares are absent." >&2
        echo "    sg nix-users -c 'nix build .#calangoDeb'" >&2
        echo "    sudo apt install ./result/calango-desktop_*_all.deb" >&2
      elif ! cmp -s "$installed" "$want"; then
        echo "apt: calango-desktop is out of date." >&2
        echo "  The declaration in this flake differs from the one the" >&2
        echo "  installed package was built from." >&2
        echo "    sg nix-users -c 'nix build .#calangoDeb'" >&2
        echo "    sudo apt install ./result/calango-desktop_*_all.deb" >&2
      fi

      # A banned package that is installed blocks the install outright, via
      # Conflicts. Report it here rather than letting apt be the first to say
      # so, because at that point the message names the metapackage and not
      # the thing that is actually wrong.
      for p in ${lib.concatStringsSep " " banned}; do
        if [ "$(dpkg-query -W -f='${statusFmt}' "$p" 2>/dev/null)" = "ii " ]; then
          echo "apt: $p is installed and this flake declares it banned." >&2
          echo "  calango-desktop Conflicts with it, so apt will refuse to" >&2
          echo "  install the metapackage until it is removed." >&2
        fi
      done

      exit 0
    '';
}
```

- [ ] **Step 2: Track the file, or every later test proves nothing**

```bash
git add lib/deb.nix
```

A flake build of a dirty tree does not see untracked additions. Skipping this makes the next step build an older tree and report success.

- [ ] **Step 3: Build a probe package from a fixture manifest**

Write this **outside the repository** so it is never committed:

```bash
cat > /tmp/deb-probe.nix <<'EOF'
let
  flake = builtins.getFlake "git+file:///home/isutton/Projects/calango-nix";
  pkgs  = flake.homeConfigurations."isutton@suffer".pkgs;
  deb   = import /home/isutton/Projects/calango-nix/lib/deb.nix { inherit pkgs; };
  manifest = {
    keep = { libffado2 = "a hard Depends of libpipewire-0.3-modules"; };
    ban  = { syncthing = "migrated to Nix in spec 15"; };
    ufwProfiles.calango = "[calango-syncthing]\nports=22000|21027/udp\n";
    files."usr/share/calango-desktop/probe.txt" = "probe\n";
  };
  manifestFile = pkgs.writeText "m.json" (builtins.toJSON manifest);
in {
  pkg   = deb.build { inherit manifest manifestFile; version = "0.1"; };
  drift = deb.driftCheck { inherit manifestFile; banned = [ "syncthing" "bash" ]; };
  inherit manifestFile;
}
EOF
sg nix-users -c 'nix build --no-link --print-out-paths --impure -f /tmp/deb-probe.nix pkg'
```

Expected: a store path. If eval fails, the error names the offending expression.

- [ ] **Step 4: Prove the package is well-formed and reproducible**

```bash
P=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure -f /tmp/deb-probe.nix pkg')
ls -1 "$P"                                            # calango-desktop_0.1_all.deb, and only that
/usr/bin/dpkg-deb --info     "$P"/*.deb
/usr/bin/dpkg-deb --contents "$P"/*.deb
/usr/bin/dpkg-deb --field    "$P"/*.deb Depends Conflicts
sg nix-users -c 'nix build --no-link --impure --rebuild -f /tmp/deb-probe.nix pkg'
```

Expected: `$out` holds exactly one file, named `calango-desktop_0.1_all.deb`. `--info` shows `Depends: libffado2`, `Conflicts: syncthing`, and an extended description containing both reasons. `--contents` lists `root/root` ownership, `./etc/ufw/applications.d/calango`, `./usr/share/calango-desktop/manifest.json` and `./usr/share/calango-desktop/probe.txt`. `--rebuild` passes with no diff — that is the reproducibility proof.

**On the timestamps.** They come from `SOURCE_DATE_EPOCH`, which Nix's stdenv
sets to `315532800` — 1980-01-01 UTC. `dpkg-deb --contents` renders in **local
time**, so on this machine (UTC-3) that prints `1979-12-31 21:00`, not
`1980-01-01`. Read it under `TZ=UTC` if you want the unambiguous value, or read
the tar member's `mtime` out of `data.tar.xz` directly with Python `tarfile`,
which is the only reading that depends on no formatter at all. Do **not**
describe any of this as dpkg-deb clamping to a floor: it does not clamp, and
with a plain `@0` the recorded mtime really is `0`.

- [ ] **Step 5: Prove apt accepts it**

```bash
apt-get -s install "$P"/*.deb
```

Expected: `Inst calango-desktop`, `0 upgraded, 1 newly installed, 0 to remove`. This is a simulation and needs no privileges.

- [ ] **Step 6: Run all three branches of the drift script**

```bash
D=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure -f /tmp/deb-probe.nix drift')
M=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure -f /tmp/deb-probe.nix manifestFile')

echo "--- not installed:"; "$D" /tmp/definitely-absent-manifest.json
echo "--- current:";       "$D" "$M"
sed 's/spec 15/spec 99/' "$M" > /tmp/stale.json
echo "--- stale:";         "$D" /tmp/stale.json
```

Expected, in order:

| case | drift line | banned line |
|---|---|---|
| not installed | `apt: calango-desktop is not installed.` | present |
| current | **none** | present |
| stale | `apt: calango-desktop is out of date.` | present |

`bash` is `ii` on this machine and the fixture bans it on purpose, so
`apt: bash is installed and this flake declares it banned.` appears in **all
three** runs — that is the banned-package branch proving it can fire, and it is
why the "current" case is not silent overall. `syncthing` is `rc`, not `ii`, so
it must **not** appear: a banned package that is merely removed is not a
finding. Each run must exit `0`.

- [ ] **Step 7: Commit**

```bash
git add lib/deb.nix
git commit -F - <<'EOF'
deb: a pure builder for the Debian glue package

lib/deb.nix, the same shape as lib/nixgl.nix: a plain function, not a
module. `build` turns a manifest into a .deb; `driftCheck` turns one
into a script that compares the installed manifest against it.

The comparison is a script rather than an inline activation body
because the activation script only runs under DRY_RUN=1 for anyone but
the user, where `run` echoes instead of executing. An inline body could
never be exercised by an implementer or a reviewer, and this project
has shipped three guards that could not fail.

$out is a directory, not the file: apt needs a path ending in .deb with
a package-shaped name, and a bare-file output yields ./result.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
EOF
```

---

## Task 2: `home/deb.nix` and the flake wiring

**Files:**
- Create: `home/deb.nix`
- Modify: `flake.nix:22` (outputs signature), `flake.nix:132-155` (module list and inline module), and the outputs attrset

**Interfaces:**
- Consumes: `lib/deb.nix`'s `build` and `driftCheck` from Task 1, with the exact argument names given there.
- Produces:
  - options `calango.deb.{version,keep,ban,ufwProfiles,files}` and read-only `calango.debPackage`
  - `packages.x86_64-linux.calangoDeb`
  - the activation hook `calangoDebDrift`

- [ ] **Step 1: Create `home/deb.nix`**

```nix
# Declarative control over the Debian side, through a package apt understands.
#
# This flake has crossed the apt boundary fifteen times and could never STATE
# anything about it. Twenty-two packages are `apt-mark manual` for reasons that
# live only in CLAUDE.md, and libpipewire-0.3-modules has zero reverse
# dependencies -- a flag and a paragraph are the whole of what keeps nine
# packages away from autoremove.
#
# A .deb's control fields are a declarative manifest and apt already enforces
# them. Nix builds, apt installs, dpkg enforces. There is deliberately no
# sudoers rule and no polkit action: `sudo -n` requires a password here, and
# this project already declined the same shape for pam_gnome_keyring.
#
# The option namespace exists so a reason can live beside the thing that needs
# it -- home/syncthing.nix declares its own ufw profile and its own bans.
# `attrsOf` merges by key, so two modules claiming one package with different
# reasons is a module-system error, which is the right outcome: it makes
# someone decide.
{ config, lib, pkgs, ... }:

let
  deb = import ./../lib/deb.nix { inherit pkgs; };
  cfg = config.calango.deb;

  manifest = {
    inherit (cfg) keep ban ufwProfiles files;
  };

  # One store path, read by both consumers. builtins.toJSON is deterministic
  # here because Nix stores attribute sets sorted, so the same declaration
  # always serialises to the same bytes.
  #
  # The VERSION is deliberately not in the manifest. It moves with every
  # commit; the declaration does not. Including it would make every commit
  # register as drift.
  manifestFile =
    pkgs.writeText "calango-deb-manifest.json" (builtins.toJSON manifest);
in
{
  options.calango.deb = {
    version = lib.mkOption {
      type = lib.types.str;
      description = "Debian version field. flake.nix derives it from the git state.";
    };
    keep = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Package name -> why it must stay. Becomes Depends.";
    };
    ban = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Package name -> why it must not return. Becomes Conflicts.";
    };
    ufwProfiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "File name under /etc/ufw/applications.d -> its content.";
    };
    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "Path relative to / -> file content. Content, never a path.";
    };
  };

  options.calango.debPackage = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The built .deb, in a directory. flake.nix exposes it.";
  };

  config.calango.debPackage = deb.build {
    inherit manifest manifestFile;
    inherit (cfg) version;
  };

  # Entries with no natural owner. Anything a specific module is responsible
  # for belongs in that module instead -- see home/audio.nix, home/session.nix
  # and home/syncthing.nix.
  config.calango.deb.keep = {
    bluez = "bluetoothd runs from /usr/lib/systemd/system/bluetooth.service, a system unit, and standalone Home Manager writes only ~/.config/systemd/user. Permanent by architecture.";
    gnome-keyring = "Serves org.freedesktop.secrets and backs org.freedesktop.impl.portal.Secret, which hyprland-portals.conf names. nixpkgs' package ships no systemd units and no D-Bus activation files, so all five artifacts would have to be hand-authored.";
    libpam-gnome-keyring = "pam_gnome_keyring.so is in /etc/pam.d/greetd and is the auto-unlock path. Using nixpkgs' copy would point a root-owned login file at the Nix store, and a garbage collection would then break login -- the one failure this project will not accept.";
    ufw = "This package ships ufw application profiles and depends on ufw's own dpkg trigger, interest-noawait /etc/ufw/applications.d, to load them.";
    cups = "Printing. The job applet and the add-a-printer GUI were removed in spec 12 on purpose; cupsd was not.";
    google-chrome-stable = "Corp set, permanently apt. nixpkgs cannot supply it either way: the package is unfree, and flake.nix imports nixpkgs with overlays but no config, so allowUnfree would be a decision taken on its own merits.";
    code = "Corp set, permanently apt. Debian is the freshest source for it, which inverts this project's usual direction.";
    "1password" = "Corp set, permanently apt, and load-bearing well beyond its own window: ~/.ssh/config sets IdentityAgent ~/.1password/agent.sock for github.com, so this agent holds the SSH keys -- which is why Debian's ssh-agent and gcr-ssh-agent serve none here.";

    # NOTE: no reason string below may contain the literal Nix store path
    # prefix. Every reason is serialised into manifest.json, which the
    # noStorePaths guard greps -- so a reason that merely TALKS about store
    # paths fails the build. Say "the Nix store" in prose instead. This cost a
    # clean build once, in preflight.
    "1password-cli" = "Corp set, permanently apt. Pairs with the 1password desktop agent above.";
    endpoint-verification = "Corp set, permanently apt. A managed-device agent; there is no Nix equivalent and there should not be one.";
    flatseal = "Absent from nixpkgs, and really a flatpak.";
    fresh-editor = "nixpkgs has 0.3.6 against Debian's 0.4.7, so moving it would be a downgrade.";
  };

  config.calango.deb.ban = {
    lf = "Nix's, as of spec 14. apt's copy shadowed it on PATH and was the machine's only source of lf completions until home/lf.nix stopped using writeShellScriptBin.";
    signal-desktop = "Nix's, as of spec 13. Note the .desktop id differs between the trees: nixpkgs ships signal.desktop where Debian ships signal-desktop.desktop.";
    bitwarden = "Nix's, as of spec 13, through the bitwarden-desktop attribute.";
    gammastep = "Nix's, entirely, as of spec 10. It was a two-provenance split before that: the unit ran 2.0.11 while a shell got Debian's 2.0.9.";
    gammastep-indicator = "Nix's, with the same provenance history as gammastep.";
    foot = "Nix's. Debian's unit was enabled by two root-owned links and had been running a 1.21.0 server for months while every terminal on screen was Nix's 1.27.0.";
    fumon = "Nix's, as of spec 6, which is where the mixed-provenance shadow was first found.";
    hypridle = "Nix's, through services.hypridle.";
    hyprpolkitagent = "Nix's, through services.hyprpolkitagent.";
    pipewire = "Nix's. Note this is the DAEMON; libpipewire-0.3-modules is kept, because it fills the module directory of Debian's client library for Debian-linked clients.";
    wireplumber = "Nix's. It resolves scripts through XDG_DATA_DIRS, so a Nix wireplumber would happily execute Debian's Lua scripts -- home/audio.nix pins it with WIREPLUMBER_DATA_DIR.";
    xdg-desktop-portal = "Nix's. flatpak Recommends this (not Depends) and the recommendation currently sits unsatisfied. Conflicts only fails loudly when the package is named explicitly; on the recommends-processing path (e.g. installing libglib2.0-tests) apt silently leaves xdg-desktop-portal uninstalled instead, with no warning -- verified both ways with apt-get -s install.";
    xdg-desktop-portal-hyprland = "Nix's, and the backend half of the pair above.";
    hyprland = "Nix's. The compositor is launched through lib/nixgl.nix's wrapper.";
    quickshell = "Owned by Nix, and the session tray host: it holds org.kde.StatusNotifierWatcher and org.kde.StatusNotifierHost-* on the session bus.";
    pulseaudio = "Never wanted. flake.nix's no-pulseaudio-daemon check exists to stop the Nix side gaining a daemon; this stops the apt side.";
    pulseaudio-utils = "Nix's, through home/audio.nix's pulseaudioClients, which supplies pactl and withholds the daemon deliberately.";
  };

  # Non-fatal, for the reason home/apt-hygiene.nix records at length: this is
  # apt's state, not this flake's, and a switch must never abort over it.
  #
  # `|| true` is defensive rather than load-bearing. The body runs in a child
  # process, and shell options are not inherited across an exec -- `activate`
  # sets -eu and pipefail for itself, and does not export SHELLOPTS. The clause
  # is kept because it costs nothing and is correct if this is ever inlined.
  config.home.activation.calangoDebDrift =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${deb.driftCheck {
        inherit manifestFile;
        banned = builtins.attrNames cfg.ban;
      }} || true
    '';
}
```

- [ ] **Step 2: Track it before building anything**

```bash
git add home/deb.nix
```

- [ ] **Step 3: Wire it into `flake.nix` — the outputs signature**

`flake.nix:22` currently reads:

```nix
  outputs = { nixpkgs, home-manager, nixgl, ... }:
```

Change it to bind `self`:

```nix
  outputs = { self, nixpkgs, home-manager, nixgl, ... }:
```

- [ ] **Step 4: Add the module and pass the version**

In `mkHome`'s module list, after `./home/syncthing.nix`, add `./home/deb.nix`. Then in the inline module that already sets `calango.host`, add the version:

```nix
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "26.05";
            calango.host = hostname;

            # A dirty build must never outrank a committed one: 0.0+dirty…
            # sorts below 0.<revCount>, verified with dpkg --compare-versions.
            # revCount and rev are absent for a dirty tree; lastModifiedDate is
            # not, which is what makes the fallback expressible at all.
            calango.deb.version =
              if self ? revCount
              then "0.${toString self.revCount}"
              else "0.0+dirty${self.lastModifiedDate}";
          }
```

- [ ] **Step 5: Expose the package**

In the outputs attrset, beside `homeConfigurations`, add:

```nix
      packages.${system}.calangoDeb = suffer.config.calango.debPackage;
```

- [ ] **Step 6: Build it and read what it says**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb'
P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
ls -1 "$P"
/usr/bin/dpkg-deb --field "$P"/*.deb Package Version Depends Conflicts
/usr/bin/dpkg-deb --info "$P"/*.deb | head -40
```

Expected: one `.deb`, `Package: calango-desktop`, a `Version` of the form `0.<N>` (the tree is committed at this point) or `0.0+dirty<14 digits>`, `Depends` listing the 12 central keeps in sorted order, `Conflicts` listing the 17 central bans.

- [ ] **Step 7: Verify the counts rather than eyeballing them**

```bash
/usr/bin/dpkg-deb --field "$P"/*.deb Depends   | tr ',' '\n' | /usr/bin/grep -c .   # 12
/usr/bin/dpkg-deb --field "$P"/*.deb Conflicts | tr ',' '\n' | /usr/bin/grep -c .   # 17
apt-get -s install "$P"/*.deb | tail -5
```

Expected: `12`, `17`, and a simulation ending `0 upgraded, 1 newly installed, 0 to remove`.

- [ ] **Step 8: Verify the drift hook is wired and reports "not installed"**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
/usr/bin/grep -c 'calango-deb-drift' "$A/activate"      # 1
S=$(/usr/bin/grep -o '/nix/store/[a-z0-9]*-calango-deb-drift' "$A/activate" | head -1)
"$S"
```

Expected: the count is `1`; running the script prints `apt: calango-desktop is not installed.` and exits `0`. The package genuinely is not installed at this point, so this is the real state and not a fixture.

- [ ] **Step 9: `nix flake check` still passes**

```bash
sg nix-users -c 'nix flake check' 2>&1 | tail -3
```

Expected: `running 3 flake checks...` and exit 0. Adding a `packages` output must not disturb the existing three.

- [ ] **Step 10: Commit**

```bash
git add home/deb.nix flake.nix
git commit -F - <<'EOF'
deb: declare the Debian side, and build a package that enforces it

home/deb.nix adds a calango.deb.* option namespace any module can
contribute to, and carries the entries with no natural owner: twelve
keeps and seventeen bans, each with the sentence that justifies it.

Depends replaces `apt-mark manual` for the keep set. A mark is a flag
whose reason lives in a markdown file; a dependency is structural and
carries the reason in the control file. libpipewire-0.3-modules has
zero reverse dependencies today.

The version comes from the flake's git state, and a dirty build sorts
below any committed one -- verified with dpkg --compare-versions -- so
an installed artifact always traces to a commit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
EOF
```

---

## Task 3: The four guards, each proven by mutation

**Files:**
- Modify: `home/deb.nix`

**Interfaces:**
- Consumes: the options and `manifest` binding from Task 2.
- Produces: three `assertions` entries and one `runCommand` in `home.packages`.

Every mutation must be applied to a **tracked** file and confirmed by a count **before** the build runs. A mutation that did not land produces a passing build that looks like a proof.

- [ ] **Step 1: Add the three assertions**

Insert into `home/deb.nix`'s `config`, after the `ban` block:

```nix
  # Three assertions rather than a runCommand: these read merged OPTION
  # VALUES, and a derivation inside the generation cannot inspect the
  # generation it belongs to. home/syncthing.nix established the shape.
  config.assertions = [
    {
      # The anti-vacuity anchor every guard in this flake carries. Without it
      # the package builds with an empty Depends and the whole mechanism
      # asserts nothing about anything, silently.
      assertion = cfg.keep != { };
      message = ''
        calango.deb.keep is empty, so the generated package would carry no
        Depends at all and would protect nothing from autoremove. Either the
        declarations were lost or every module stopped contributing. Decide
        which, on purpose.
      '';
    }
    {
      assertion = lib.intersectLists (builtins.attrNames cfg.keep) (builtins.attrNames cfg.ban) == [ ];
      message = ''
        A package is in both calango.deb.keep and calango.deb.ban: ${
          lib.concatStringsSep ", "
            (lib.intersectLists (builtins.attrNames cfg.keep) (builtins.attrNames cfg.ban))
        }.
        Depends and Conflicts naming the same package makes an uninstallable
        package. Note pipewire and libpipewire-0.3-modules are DIFFERENT
        packages and being on opposite sides is correct; check you have not
        confused them.
      '';
    }
    {
      # The wrapExemptions idiom: a name in a table must be typed by a person
      # who then has to write the sentence beside it. An empty reason is a
      # name nobody had to justify.
      assertion =
        lib.all (s: lib.trim s != "")
          (lib.attrValues cfg.keep ++ lib.attrValues cfg.ban);
      message = ''
        An entry in calango.deb.keep or calango.deb.ban has an empty reason.
        The reason is the point: it ships in the package's own extended
        description, which is the only place anyone reading `apt show
        calango-desktop` will find out why the entry exists.
      '';
    }
  ];
```

`lib.trim` is a recent nixpkgs addition, so check it exists rather than
assuming — and check it with a predicate that answers yes or no, not by reading
an error message:

```bash
sg nix-users -c 'nix eval .#homeConfigurations."isutton@suffer".pkgs.lib --apply "l: l ? trim"'
```

Expected `true`. If it prints `false`, replace `lib.trim s != ""` with
`lib.replaceStrings [ " " "\n" "\t" ] [ "" "" "" ] s != ""`, which needs no
library function that might not be there.

- [ ] **Step 2: Add the payload guard**

In `home/deb.nix`'s `let` block, after `manifestFile`:

```nix
  # A root-owned file must never name /nix/store. That is the pam_gnome_keyring
  # hazard this project declined: if the path is garbage-collected the file
  # points at nothing, and unlike everything else here the failure is not
  # recoverable from a running desktop.
  #
  # The needle is built by concatenation, exactly as home/default.nix's
  # nixglSingleSource is, and for the same reason: written plainly the guard's
  # own source contains it and fails for ever.
  noStorePaths =
    pkgs.runCommand "calango-deb-no-store-paths"
      {
        inherit manifestFile;
        needle = "/nix" + "/store";
      }
      ''
        # A condition, not a bare command: a builder runs with errexit, and a
        # grep that matches nothing exits 1 -- which here is the PASSING case.
        if grep -n -F -- "$needle" "$manifestFile" >&2; then
          echo "" >&2
          echo "The deb manifest names a /nix/store path." >&2
          echo "  calango.deb.files and calango.deb.ufwProfiles take file" >&2
          echo "  CONTENT, never a path. A path put in the manifest is both" >&2
          echo "  non-reproducible and, once installed, a root-owned file" >&2
          echo "  referencing the store -- which breaks when that path is" >&2
          echo "  garbage-collected. Read the file in Nix and pass its text:" >&2
          echo "    files.\"usr/share/x\" = builtins.readFile ./x;" >&2
          exit 1
        fi
        mkdir -p "$out"
      '';
```

and add it to `home.packages`:

```nix
  config.home.packages = [
    # Not a program. A build-time assertion that rides in home.packages so it
    # runs on every generation build -- strictly more often than
    # `nix flake check`. Same shape as home/default.nix's nixgl-guard.
    (pkgs.runCommand "calango-deb-guard" { } "ln -s ${noStorePaths} $out")
  ];
```

A directory output, not `touch "$out"`: `home/gui-apps.nix` records that a file output makes `pkgs.buildEnv` fail with "is a file and can't be merged into an environment".

- [ ] **Step 3: Confirm the clean build passes**

```bash
git add home/deb.nix
sg nix-users -c 'nix build --no-link .#calangoDeb' && echo "clean build OK"
```

- [ ] **Step 4: Mutation 1 — the vacuity anchor**

**REPLACE the existing definition. Do not add a second one.** Two earlier
versions of this mutation were wrong in two different ways, and both turned the
build red without ever reaching the guard:

| attempted mutation | how it fails | why that proves nothing |
|---|---|---|
| `keep = lib.mkForce {} // { … }` | Nix type error | never evaluates `assertions` |
| a second `config.calango.deb.keep = …` line | Nix duplicate-attribute error | a *language* error, raised before the module system runs |

Both were caught only because an implementer declined to read "the build
failed" as "the guard fired". That distinction is the entire point of this task.

The `keep` block opens with a line that is exactly
`  config.calango.deb.keep = {`, ends with a line that is exactly `  };`, and
contains no nested `  };`, so replacing its whole span is safe:

```bash
cp home/deb.nix /tmp/deb.nix.bak
python3 - <<'MUT'
import io
p = 'home/deb.nix'
s = io.open(p, encoding='utf-8').read()
open_tok  = '  config.calango.deb.keep = {'
close_tok = '\n  };\n'
start = s.index(open_tok)
end   = s.index(close_tok, start) + len(close_tok)
s = s[:start] + '  config.calango.deb.keep = lib.mkForce { };\n' + s[end:]
io.open(p, 'w', encoding='utf-8').write(s)
MUT
/usr/bin/grep -c 'config.calango.deb.keep = lib.mkForce { };' home/deb.nix   # 1
/usr/bin/grep -c 'bluez = "bluetoothd runs from' home/deb.nix                # 0
sg nix-users -c 'nix build --no-link .#calangoDeb' 2>&1 | tail -8
cp /tmp/deb.nix.bak home/deb.nix
git diff --stat home/deb.nix   # must be empty
```

**Both counts are required and they check different things.** The first proves
the forcing definition landed; the second proves the original block is really
gone rather than the new line merely prepended — which is precisely the
condition whose absence produced the duplicate-attribute error above.

Expected: counts `1` and `0`, and the build **fails with the assertion's own
message**, beginning `calango.deb.keep is empty`. A duplicate-attribute error,
a type error, or any other Nix failure means the guard is still unproven — do
not record it as passing.

`lib.mkForce` carries priority 50 against a normal definition's 100, so this
mutation stays valid after Task 4 adds `calango.deb.keep` entries from
`home/audio.nix`: the force still wins and `cfg.keep` really evaluates to `{ }`.


- [ ] **Step 5: Mutation 2 — keep and ban intersecting**

```bash
cp home/deb.nix /tmp/deb.nix.bak
python3 - <<'MUT'
import io; p='home/deb.nix'; s=io.open(p,encoding='utf-8').read()
old = '    bluez = "bluetoothd runs from'
assert s.count(old)==1
io.open(p,'w',encoding='utf-8').write(s.replace(old, '    lf = "deliberate contradiction, mutation test";\n' + old))
MUT
/usr/bin/grep -c 'deliberate contradiction' home/deb.nix    # 1
sg nix-users -c 'nix build --no-link .#calangoDeb' 2>&1 | tail -8
cp /tmp/deb.nix.bak home/deb.nix
```

Expected: build fails, and the message names `lf` — `lf` is already in `ban`, so adding it to `keep` is the contradiction.

- [ ] **Step 6: Mutation 3 — an empty reason**

`flatseal` is the target because its reason is the one central entry with no
apostrophe in it. An apostrophe inside a single-quoted Python string inside a
shell heredoc is three levels of quoting to get right, for no gain.

```bash
cp home/deb.nix /tmp/deb.nix.bak
python3 - <<'MUT'
import io; p='home/deb.nix'; s=io.open(p,encoding='utf-8').read()
old = '    flatseal = "Absent from nixpkgs, and really a flatpak.";'
assert s.count(old)==1
io.open(p,'w',encoding='utf-8').write(s.replace(old, '    flatseal = "";'))
MUT
/usr/bin/grep -c 'flatseal = "";' home/deb.nix       # 1
sg nix-users -c 'nix build --no-link .#calangoDeb' 2>&1 | tail -6
cp /tmp/deb.nix.bak home/deb.nix
```

Expected: build fails naming an empty reason.

- [ ] **Step 7: Mutation 4 — a store path in the payload**

```bash
cp home/deb.nix /tmp/deb.nix.bak
python3 - <<'MUT'
import io; p='home/deb.nix'; s=io.open(p,encoding='utf-8').read()
old = '  config.calango.deb.ban = {'
assert s.count(old)==1
new = ('  config.calango.deb.files."usr/share/calango-desktop/mutation.txt" =\n'
       '    "${pkgs.bash}/bin/bash\\n";\n\n' + old)
io.open(p,'w',encoding='utf-8').write(s.replace(old, new))
MUT
/usr/bin/grep -c 'mutation.txt' home/deb.nix         # 1
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -8
cp /tmp/deb.nix.bak home/deb.nix
```

Expected: the build **fails** with `The deb manifest names a /nix/store path.` Note this builds the **activation package**, not `.#calangoDeb` — the guard rides in `home.packages`, so `.#calangoDeb` alone would not evaluate it. Getting this target wrong makes the mutation appear to pass.

- [ ] **Step 8: Confirm the tree is back to clean and green**

```bash
git diff --stat home/deb.nix          # must be empty
sg nix-users -c 'nix build --no-link .#calangoDeb' && echo OK
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' && echo OK
```

- [ ] **Step 9: Commit**

```bash
git add home/deb.nix
git commit -F - <<'EOF'
deb: four guards, each proven by mutation

Three assertions -- non-empty keep, keep and ban disjoint, every entry
carries a reason -- and one runCommand that fails the build if the
manifest names a /nix/store path.

assertions rather than runCommand for the first three because they read
merged option values, and a derivation inside the generation cannot
inspect the generation it belongs to.

The store-path guard is the pam_gnome_keyring hazard in a new place: a
root-owned file pointing into the store breaks unrecoverably when that
path is collected. Its needle is built by concatenation so the guard's
own source cannot satisfy it.

Each mutation was confirmed by a count before its build ran. The
store-path mutation must be built as the activationPackage, not as
.#calangoDeb -- the guard rides in home.packages.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
EOF
```

---

## Task 4: Module contributions

**Files:**
- Modify: `home/audio.nix` (add to the outer attrset that begins at line 357)
- Modify: `home/syncthing.nix` (add to the outer attrset that begins at line 22)
- Modify: `home/session.nix` (add to the outer attrset that begins at line 146)

**Interfaces:**
- Consumes: the `calango.deb.{keep,ban,ufwProfiles,files}` options from Task 2.
- Produces: keep grows from 12 to 22, ban from 17 to 19, one ufw profile, one file.

These are three small edits of the same shape. Each puts a declaration in the module that owns the reason, which is the entire point of the option namespace.

- [ ] **Step 1: `home/audio.nix` — rtkit and the nine**

Add to the outer attrset (the one starting at line 357, alongside `home.packages`):

```nix
  # apt packages this audio stack needs Debian to keep. Nine of the ten fill
  # the compiled-in module directory of DEBIAN's libpipewire-0.3.so, which is a
  # dependency no in-use check can ever see: a plugin directory is not
  # something apt models, and nothing holds a mapping on it until a plugin is
  # loaded. Every automated check clears all nine, because nothing that needs
  # them was running. That is exactly why they are declared rather than
  # measured.
  # NOTE: an attribute name containing a dot followed by a digit MUST be
  # quoted -- `libpipewire-0.3-modules` unquoted is a Nix parse error, because
  # `0.3` lexes as a float inside an attribute path. The `+` names below were
  # quoted from the start and the digit ones were not, which is the whole trap:
  # they look equally awkward and only some of them are.
  calango.deb.keep = {
    rtkit = "rtkit-daemon runs from /usr/lib/systemd/system/rtkit-daemon.service, a system unit, and standalone Home Manager writes only ~/.config/systemd/user. It grants pipewire's data-loop.0 thread SCHED_RR priority 20, measured under Nix's pipewire.";
    "libpipewire-0.3-modules" = "Fills the compiled-in module directory of DEBIAN's libpipewire-0.3.so, /usr/lib/x86_64-linux-gnu/pipewire-0.3, with 44 .so files. That client library is kept installed by libfluidsynth3 and qemu-system-gui, and a Debian-linked PipeWire client -- a qemu VM's audio device, in practice -- loads its protocol and client-node modules from there. Nix's pipewire has its own closure and is unaffected. It has zero reverse dependencies, so nothing but this declaration holds it.";
    libffado2 = "A hard Depends of libpipewire-0.3-modules.";
    "libroc0.4" = "A hard Depends of libpipewire-0.3-modules.";
    "libconfig++11" = "In libffado2's dependency chain.";
    "libglibmm-2.4-1t64" = "In libffado2's dependency chain.";
    "libxml++2.6-2v5" = "In libffado2's dependency chain.";
    "libsigc++-2.0-0v5" = "In libglibmm-2.4-1t64's and libxml++2.6-2v5's dependency chain.";
    libopenfec1 = "In libroc0.4's dependency chain.";
    libspeexdsp1 = "In libroc0.4's dependency chain.";
  };
```

- [ ] **Step 2: `home/syncthing.nix` — the ufw profile and the two bans**

Add to the outer attrset (starting at line 22), after the `services.syncthing.tray` block and before `assertions`:

```nix
  # The firewall vocabulary for the daemon above.
  #
  # The file is named `calango`, not `syncthing`, and the profile inside it is
  # `calango-syncthing`, not `syncthing`. Debian's syncthing package is `rc`,
  # and dpkg still records it owning /etc/ufw/applications.d/syncthing while in
  # that state -- shipping the same path would need a conffile handover between
  # packages, and shipping the same profile NAME would collide in ufw's own
  # namespace with the one that file defines.
  #
  # No postinst is needed and none is written: ufw already declares
  # `interest-noawait /etc/ufw/applications.d`, and its postinst's triggered)
  # branch runs `ufw app update all`. dpkg fires it for us.
  #
  # A profile is not a rule. `ufw app update` refreshes profiles and any rule
  # already citing them; it never creates one. `sudo ufw allow calango-syncthing`
  # stays a deliberate human act -- which is just as well, since
  # /etc/ufw/user.rules is 0640 root:root and nothing here could verify a rule.
  #
  # No GUI entry, deliberately: 8384 listens on 127.0.0.1 only, measured with
  # `ss -lntup`. Shipping a profile for it would invite opening a shut port.
  calango.deb.ufwProfiles.calango = ''
    [calango-syncthing]
    title=Syncthing (calango-nix)
    description=Syncthing sync protocol and local discovery
    ports=22000|21027/udp
  '';

  calango.deb.ban = {
    syncthing = "Nix's, as of spec 15: syncthing 2.1.2 through services.syncthing. Debian's 1.29.5 cannot read the upgraded config.xml, which went version 37 to 52.";
    syncthingtray = "Nix's, as of spec 15. Debian's build embeds Qt WebEngine for its web GUI, which was 186 MB of the 288 MB the migration reclaimed; Nix's does not.";
  };
```

- [ ] **Step 3: `home/session.nix` — the greetd session entry**

Add to the outer attrset at line 146, alongside `home.packages`:

```nix
  # The greetd session entry, which has been root-owned, hand-created and
  # covered by no mechanism since the flake began -- `dpkg -S` finds no owner.
  #
  # /usr/share, not /usr/local/share: Debian policy forbids a package writing
  # to /usr/local, and /etc/greetd/config.toml passes
  # --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions,
  # so greetd searches both. /usr/share/wayland-sessions does not currently
  # exist.
  #
  # This does NOT remove the existing /usr/local copy. Until someone does,
  # tuigreet shows two identical entries -- cosmetic and visible, against the
  # alternative of a login path that depends on an untested file.
  #
  # It names no /nix/store path, deliberately and verifiably: it reaches Nix
  # through $HOME/.nix-profile. home/deb.nix's noStorePaths guard fails the
  # build if that ever changes, because a root-owned file naming the store
  # breaks unrecoverably when the path is collected.
  calango.deb.files."usr/share/wayland-sessions/hyprland-nix.desktop" = ''
    [Desktop Entry]
    Name=Hyprland (Nix)
    Comment=calango-nix
    Type=Application
    DesktopNames=Hyprland
    Exec=/bin/sh -lc 'export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"; exec "$HOME/.nix-profile/bin/uwsm" start -e -D Hyprland hyprland-nixgl.desktop'
  '';
```

The `''${XDG_DATA_DIRS:-…}` spelling is the Nix escape for a literal `${`. Step 5 verifies the built file matches the live one byte for byte, which is what catches a mis-escape.

- [ ] **Step 4: Build and check the counts moved as predicted**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb'
P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
/usr/bin/dpkg-deb --field "$P"/*.deb Depends   | tr ',' '\n' | /usr/bin/grep -c .   # 22
/usr/bin/dpkg-deb --field "$P"/*.deb Conflicts | tr ',' '\n' | /usr/bin/grep -c .   # 19
/usr/bin/dpkg-deb --contents "$P"/*.deb
```

Expected: `22` and `19`, and the contents list `./etc/ufw/applications.d/calango`, `./usr/share/wayland-sessions/hyprland-nix.desktop`, `./usr/share/calango-desktop/manifest.json`.

- [ ] **Step 5: Prove the session entry is byte-identical to the live one**

```bash
mkdir -p /tmp/debx && /usr/bin/dpkg-deb -x "$P"/*.deb /tmp/debx
diff /tmp/debx/usr/share/wayland-sessions/hyprland-nix.desktop \
     /usr/local/share/wayland-sessions/hyprland-nix.desktop && echo "IDENTICAL"
/usr/bin/grep -c '/nix/store' /tmp/debx/usr/share/wayland-sessions/hyprland-nix.desktop
```

Expected: `IDENTICAL`, and a store-path count of `0`. A difference here means the escaping in step 3 is wrong; fix it rather than accepting a file that only looks similar. This is the login path.

- [ ] **Step 6: Verify every declared name actually exists in apt**

```bash
for p in $(/usr/bin/dpkg-deb --field "$P"/*.deb Depends | tr ',' '\n' | tr -d ' '); do
  c=$(apt-cache policy "$p" 2>/dev/null | /usr/bin/grep -m1 -c 'Candidate:')
  [ "$c" = "1" ] || echo "NO CANDIDATE: $p"
done
echo "done"
```

Expected: no `NO CANDIDATE` lines. A name apt cannot resolve makes the package uninstallable, and the error at install time names the metapackage rather than the typo.

- [ ] **Step 7: Simulate the install and confirm it still resolves**

```bash
apt-get -s install "$P"/*.deb | tail -6
sg nix-users -c 'nix flake check' 2>&1 | tail -3
```

Expected: `0 upgraded, 1 newly installed, 0 to remove`, and three flake checks passing.

- [ ] **Step 8: Commit**

```bash
git add home/audio.nix home/syncthing.nix home/session.nix
git commit -F - <<'EOF'
deb: let modules declare their own apt needs

home/audio.nix takes rtkit and the nine libpipewire-0.3-modules
packages; home/syncthing.nix takes its ufw profile and its two bans;
home/session.nix takes the greetd entry. Keep goes 12 to 22, ban 17
to 19.

This is the point of the option namespace: the reason lives beside the
thing that needs it, and attrsOf merges by key, so two modules claiming
one package is a module-system error rather than a silent last-wins.

The ufw file is named `calango` and its profile `calango-syncthing`,
because dpkg still records the rc syncthing package owning
/etc/ufw/applications.d/syncthing and shipping either the same path or
the same profile name would collide.

The session entry goes to /usr/share, not /usr/local: policy forbids
the latter and greetd searches both. It is byte-identical to the
hand-made file, which is checked rather than assumed -- it is the
login path.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
EOF
```

---

## Task 5: `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: nothing. Documents what Tasks 1-4 established.
- Produces: nothing other tasks read.

Only what is true **now**, before installation. Everything about the installed state belongs in the results document, which is written after the user installs.

- [ ] **Step 1: Add an entry to "Tools that answer a different question than the one asked"**

Place it after the `Package presence` entry:

```markdown
**An `rc` package still owns its conffiles, and `dpkg -S` says so.**

```sh
dpkg -S /etc/ufw/applications.d/syncthing
# syncthing: /etc/ufw/applications.d/syncthing   <- syncthing is rc, not ii
```

So a new package cannot simply ship a path a removed package's conffile
occupies: dpkg refuses to unpack it without a `Replaces:`, and a conffile
handover between packages is fiddly enough that `home/syncthing.nix` sidesteps
it entirely with a distinct filename. "The package is gone" and "the path is
free" are different questions.
```

- [ ] **Step 2: Add an entry to "Mechanisms that are not what they look like"**

```markdown
**`ufw` already has the integration point, so a `postinst` calling
`ufw reload` is the wrong answer.**

```sh
cat /var/lib/dpkg/info/ufw.triggers
# interest-noawait /etc/ufw/applications.d
sed -n '137,138p' /var/lib/dpkg/info/ufw.postinst
#     triggered)
#         ufw app update all || echo "Processing ufw triggers failed. Ignoring."
```

Dropping a file into that directory makes dpkg fire ufw's own trigger. A
package shipping ufw profiles needs no maintainer script at all — only
`Depends: ufw`, so the trigger's owner is guaranteed present.

And a profile is not a rule. `ufw app update` refreshes profiles and any rule
already citing them; it never creates one. Nothing in this flake can verify a
rule either — `/etc/ufw/user.rules` is `0640 root:root`, and `nft` and
`iptables` both refuse an unprivileged read — so `ufw allow` stays a human act
by necessity, not by preference.
```

- [ ] **Step 3: Add a second entry to the same section**

```markdown
**A Nix-built `.deb` must have a directory as `$out`, and needs no `fakeroot`.**
Both were measured while building `lib/deb.nix`:

```sh
P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
ls -1 "$P"
# calango-desktop_0.251_all.deb        <- $out is a DIRECTORY holding the .deb
sg nix-users -c 'nix build --no-link --rebuild .#calangoDeb'
# checking outputs of '/nix/store/...-calango-desktop-0.251.drv'
#                                      <- no mismatch, exit 0: bit-reproducible
/usr/bin/dpkg-deb -c "$P"/*.deb | sed -n '1,2p'
# drwxr-xr-x root/root 0 1979-12-31 21:00 ./
# drwxr-xr-x root/root 0 1979-12-31 21:00 ./etc/
/usr/bin/grep -c fakeroot lib/deb.nix
# 0                                    <- fakeroot is never invoked at all
```

The version moves with every commit, so the exact number above will not match
what you get; everything else will.

`dpkg-deb --root-owner-group` alone gives `root/root` ownership, so `fakeroot`
buys nothing — and the count above is better evidence than comparing two builds
would be, because it shows the builder never reaches for it in the first place. And `$out` must be a **directory** containing
`calango-desktop_<version>_all.deb`: apt requires a path ending in `.deb` with
a package-shaped name, and a bare-file output yields `./result`, which
`apt install` rejects. The build succeeds either way; only the install fails.
```

- [ ] **Step 4: Add the version-ordering note to the same section**

```markdown
**A dirty flake build cannot express a Debian version that outranks a clean
one, and that is the point.** `self.rev` and `self.revCount` are absent for a
dirty tree while `self.lastModifiedDate` is not, which is what makes the
fallback expressible:

```sh
dpkg --compare-versions 0.0+dirty20260818153504 lt 0.239   # true
dpkg --compare-versions 0.239 lt 0.240                     # true
```

So `0.0+dirty<date>` always sorts below `0.<revCount>` and apt refuses to
install a dirty build over a committed one. An artifact installed into the
system with root should trace to a commit. `dpkg -i` remains the escape hatch
for deliberate testing.
```

- [ ] **Step 5: Update the "one file outside `$HOME`" standing fact**

The current entry reads:

```markdown
- **One file outside `$HOME`:** `/usr/local/share/wayland-sessions/hyprland-nix.desktop`,
  root-owned, hand-created, covered by no Nix module. greetd needs it and
  nothing else supplies it.
```

Replace it with:

```markdown
- **One file outside `$HOME`, and the flake can now declare it — but has not
  yet installed it.** `/usr/local/share/wayland-sessions/hyprland-nix.desktop`
  is still root-owned, hand-created and owned by no package; `dpkg -S` finds
  nothing. `home/session.nix` declares its content as
  `calango.deb.files."usr/share/wayland-sessions/hyprland-nix.desktop"`, so
  `calango-desktop` will own a byte-identical copy in the policy-correct
  directory once it is installed. `/etc/greetd/config.toml` passes
  `--sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions`,
  so greetd searches both; `/usr/share/wayland-sessions` does not exist today.
  Until someone deletes the `/usr/local` copy — after confirming a login
  against the new one — tuigreet will show two identical entries. Do not
  delete it first: this is the login path.
```

- [ ] **Step 6: Add the new module and helper to the guard enumeration**

`CLAUDE.md` opens by insisting guards are enumerated by syntax and never by a
remembered list. Two of its counts move, so re-derive rather than edit by hand:

```bash
/usr/bin/grep -n 'home.packages' home/*.nix
/usr/bin/grep -n 'assertions' home/*.nix
```

Update the sentences that quote those counts to the numbers these commands
now print, and add one clause noting that `home/deb.nix` contributes both a
`home.packages` guard (`noStorePaths`) and three `assertions`.

- [ ] **Step 7: Verify the document still describes reality**

```bash
/usr/bin/grep -c 'calango-desktop' CLAUDE.md          # at least 3
ls -1 docs/*results-suffer-*.md | wc -l               # 15, unchanged
/usr/bin/grep -c 'Fifteen specs' CLAUDE.md            # 1, unchanged
```

Expected: the spec count does **not** move. This work has no results document
yet — that comes after the user installs the package.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs: the four traps the glue-deb work found

An rc package still owns its conffiles, so "the package is gone" and
"the path is free" are different questions. ufw already declares
interest-noawait on /etc/ufw/applications.d, so a package shipping
profiles needs no maintainer script -- and a profile is not a rule.
A Nix-built deb needs a directory as $out and no fakeroot. And a dirty
flake build cannot express a version that outranks a clean one, which
is deliberate.

The "one file outside $HOME" standing fact is updated to say the flake
now declares it and has not yet installed it -- the /usr/local copy is
still the live one, and deleting it before a login is confirmed would
break the login path.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
EOF
```

---

## After the plan: the user's steps

None of these may be run by an agent. They are listed so the close-out knows
what to verify.

1. `sudo apt install ./result/calango-desktop_*_all.deb`
2. **The central claim, still unproven.** That `Depends:` protects the keep set
   has been reasoned from apt's documented behaviour, not measured here:

   ```sh
   sudo apt-mark auto libffado2
   apt-get -s autoremove | grep libffado2      # expect: proposed for removal
   sudo apt install ./result/calango-desktop_*_all.deb
   apt-get -s autoremove | grep libffado2      # expect: no longer proposed
   sudo apt-mark manual libffado2              # restore
   ```

   `apt-get -s` is a simulation throughout, so nothing is removed at any point.
3. `ufw app info calango-syncthing` — proves the dpkg trigger fired.
4. A login against the new session entry, before the `/usr/local` copy is
   removed.
5. `home-manager switch`, then confirm the drift hook has gone quiet.
