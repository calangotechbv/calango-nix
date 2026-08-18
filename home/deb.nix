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
    xdg-desktop-portal = "Nix's. flatpak Recommends this (not Depends) and the recommendation currently sits unsatisfied, so a recommends-processing install would restore Debian's frontend to shadow Nix's. Conflicts makes that fail loudly instead.";
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
