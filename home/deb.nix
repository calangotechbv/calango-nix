# Declarative control over the Debian side, through a package apt understands.
#
# This flake has crossed the apt boundary fifteen times and could never STATE
# anything about it. Twenty-two packages were `apt-mark manual` for reasons that
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

  # guards = [ noStorePaths ]: the guard rides as an INPUT of the built
  # package, not merely a sibling in home.packages. `nix build .#calangoDeb`
  # never evaluates home.packages at all -- proven by placing a store path in
  # the manifest and observing the activation build fail while calangoDeb
  # still wrote a .deb containing it -- so a guard that lives only in
  # home.packages protects the path that is never used to produce the
  # installable artifact. Passing it here forces Nix to build noStorePaths
  # before it can build debPackage, on both paths.
  config.calango.debPackage = deb.build {
    inherit manifest manifestFile;
    inherit (cfg) version;
    guards = [ noStorePaths ];
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
  };

  config.calango.deb.ban = {
    # These two are unlike every other entry here, and the reasons have to say
    # so. The other 19 mean "the Nix side owns this now". These mean "removed
    # deliberately, and nothing replaces them" -- a reader who generalises from
    # the rest will look for the Nix flatpak and not find one.
    flatpak = "Removed deliberately in spec 17, and nothing here replaces it. Slack was the last flatpak and moved to its own .deb; org.gnome.Snapshot, the other one, was removed on 2026-08-17. The sandbox is not wanted back: the session exports five nixGL variables that name paths a flatpak namespace does not contain, so every flatpak application needed a per-application override to undo them. Note gnome-software-plugin-flatpak, plasma-discover-backend-flatpak, flatpak-builder and podman-toolbox all Depend on flatpak, so installing any of them would propose removing this metapackage instead.";
    flatseal = "Removed deliberately in spec 17, with flatpak. It edits flatpak permissions and there is no flatpak. It was in keep until then, for being absent from nixpkgs -- which was a reason to keep it only while flatpak existed. It is also why the removal had to be ordered: this metapackage Depends on flatseal and flatseal Depends on flatpak, so removing flatpak removes this metapackage too, orphaning all 22 keeps in one step.";
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
    xdg-desktop-portal = "Nix's. Until spec 17 this reason also recorded that flatpak Recommends it (not Depends) with the recommendation sitting unsatisfied, and that Conflicts only fails loudly when the package is named explicitly -- on the recommends-processing path apt silently leaves it uninstalled instead. Both were verified with apt-get -s install, and both are now historical: flatpak is gone and banned. The general lesson is not: an unsatisfied Recommends against a Conflicts is silent.";
    xdg-desktop-portal-hyprland = "Nix's, and the backend half of the pair above.";
    hyprland = "Nix's. The compositor is launched through lib/nixgl.nix's wrapper.";
    quickshell = "Owned by Nix, and the session tray host: it holds org.kde.StatusNotifierWatcher and org.kde.StatusNotifierHost-* on the session bus.";
    pulseaudio = "Never wanted. flake.nix's no-pulseaudio-daemon check exists to stop the Nix side gaining a daemon; this stops the apt side.";
    pulseaudio-utils = "Nix's, through home/audio.nix's pulseaudioClients, which supplies pactl and withholds the daemon deliberately.";
  };

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

  config.home.packages = [
    # Not a program. A build-time assertion that rides in home.packages so it
    # runs on every generation build -- strictly more often than
    # `nix flake check`. Same shape as home/default.nix's nixgl-guard.
    (pkgs.runCommand "calango-deb-guard" { } "ln -s ${noStorePaths} $out")
  ];

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
