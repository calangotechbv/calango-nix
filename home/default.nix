{ pkgs, ... }:

let
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };

  # Qt Quick builds an OpenGL scenegraph the moment it shows its first window,
  # so a Nix Qt6 application needs the same GL wrapper the compositor needs.
  # Wrapping the compositor is not enough: a systemd user unit runs whatever
  # ExecStart names, and the home-manager module names the bare store binary.
  #
  # Unwrapped, hyprpolkitagent starts, registers with polkit, and then aborts
  # the instant it is asked to draw:
  #
  #   polkit-agent-helper-1: pam_unix(polkit-1:auth): conversation failed
  #   hyprpolkitagent.service: Main process exited, code=dumped, status=6/ABRT
  #
  # No dialog is ever presented, so PAM's conversation returns no password.
  # The cause is the same /run/opengl-driver/lib that Task 6 rung 1 hit.
  #
  # The rule is about UNITS, not about applications. An earlier version of this
  # comment said "every Nix GUI application on this machine needs the wrapper",
  # generalised from two crashes, and that is false. A session child inherits
  # the five GL variables from the compositor's own wrap -- a plain shell in
  # the session carries 5 of 5 -- while a systemd user unit inherits none of
  # them, because the user manager never carried them:
  #
  #   systemctl --user show-environment | grep -cE '^(LIBGL_DRIVERS_PATH|…)='
  #   # 0
  #
  # So the things that wrap themselves are the session, three units
  # (quickshell, hyprpolkitagent, xdg-desktop-portal-hyprland) and hyprlock --
  # which is not a unit itself, but hypridle's lock_cmd launches it and
  # hypridle IS a unit, so it inherits nothing either. A session child needs no
  # wrapper of its own. foot is the control and is Nix's
  # own counterexample: it draws through wayland shm rather than GL and needs
  # no wrapper at all (see the home.packages comment below).
  hyprpolkitagent-nixgl = pkgs.runCommand "hyprpolkitagent-nixgl" { } ''
    mkdir -p "$out/libexec"
    ln -s ${
      nixgl.wrap "hyprpolkitagent" "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
    } "$out/libexec/hyprpolkitagent"
  '';

  # Fails the build when a site outside lib/nixgl.nix spells the GL wrapper out
  # for itself. In home.packages rather than in flake.nix's checks on purpose:
  # the person who adds a wrapper is editing a module and building a
  # generation, and may never run `nix flake check`. A home.packages guard runs
  # on every generation build, which is strictly more often.
  #
  # The needle is built by concatenation, and that is not a style choice. The
  # literal `${…}` form cannot be written here: unescaped, Nix interpolates it
  # and the guard searches for an expanded store path that appears in no source
  # file, passing for ever. Escaped as `\${…}`, the source bytes of THIS file
  # contain the needle, so the guard matches itself and fails for ever. Split
  # across a `+`, the needle exists only at build time. Step 3 of this task
  # verifies that by counting.
  #
  # homeSrc is the whole home/ directory, so this rebuilds whenever any module
  # changes. It is one grep; that is the intended trade.
  nixglSingleSource =
    pkgs.runCommand "nixgl-single-source"
      {
        homeSrc = ./.;
        libSrc = ./../lib/nixgl.nix;
        needle = "$" + "{pkgs.nixgl.nixGLIntel}";
      }
      ''
        fail=0

        # A condition, not a bare command. A builder runs with errexit, and a
        # grep that matches nothing exits 1 -- which here is the PASSING case.
        if grep -rn -F -- "$needle" "$homeSrc" >&2; then
          echo "" >&2
          echo "A module above names the nixGL wrapper directly." >&2
          echo "  Every wrapper on this machine must come from lib/nixgl.nix," >&2
          echo "  which exports wrap, wrapBin and bin. Five sites spelled it" >&2
          echo "  out before spec 14 and nothing read the fifth, so changing" >&2
          echo "  the GL wrapper silently left one behind." >&2
          echo "  Use nixgl.wrap for a script, nixgl.wrapBin for a package," >&2
          echo "  or nixgl.bin if neither fits -- home/session.nix is the one" >&2
          echo "  site that needs the raw path, and it says why." >&2
          fail=1
        fi

        # The anti-vacuity anchor, the same one gui-desktop-ids,
        # no-pulseaudio-daemon and wrappedGuiApps each carry. Without it this
        # guard passes when lib/nixgl.nix has stopped naming nixGLIntel at all
        # -- at which point the check above is asserting nothing about
        # anything.
        if ! grep -q -F -- "$needle" "$libSrc"; then
          echo "lib/nixgl.nix does not name the nixGL wrapper." >&2
          echo "  The check above therefore proves nothing: it reports that" >&2
          echo "  no module names a string that nothing names. Either the" >&2
          echo "  helper moved, or this machine stopped using nixGL. Decide" >&2
          echo "  which, on purpose, and update this guard with it." >&2
          fail=1
        fi

        [ "$fail" -eq 0 ] || exit 1

        # A directory, not `touch "$out"`. home/gui-apps.nix records that a
        # file output makes pkgs.buildEnv fail with "is a file and can't be
        # merged into an environment".
        mkdir -p "$out"
      '';
in
{
  home.packages = with pkgs; [
    # The eight that exist only in trixie-backports today.
    hyprland
    uwsm
    xdg-desktop-portal-hyprland
    # hypridle and hyprpolkitagent arrive through their modules below.
    #
    # ydotool is deliberately absent, and not deferred. It was carried from
    # spec 1 as "dev tier, belongs to spec 3", but nothing was ever built that
    # used it: no reference in this flake, hyprland.lua, the quickshell tree
    # or ~/.config, and no keybind. What it did have was apt's ydotool.service
    # keeping a ydotoold daemon alive with /dev/uinput open -- the ability to
    # synthesise arbitrary keyboard and mouse input, for no consumer. Removed
    # outright rather than ported. `nixpkgs#ydotool` is 1.0.4, the same version
    # Debian had, if a consumer ever appears; it would also need a udev rule
    # granting the input group access to /dev/uinput, which is what apt's
    # 80-uinput.rules did and which a standalone Home Manager cannot install.

    # A terminal, so the session can be used and checked. foot draws through
    # wayland shm rather than GL, which makes it a control: if foot opens and
    # a GL client does not, the fault is the GL wrapper and nothing else.
    foot

    # notify-send, for fumon.service. It is that unit's ExecCondition, and
    # fumon calls it again at runtime to deliver the notification -- so this
    # is a hard dependency of the session scaffolding, not a convenience.
    #
    # Debian's libnotify-bin supplied it until spec 6 removed uwsm and left
    # that package an orphan, one `apt autoremove` away from stopping fumon
    # silently: a failed ExecCondition is not a failed unit, so nothing would
    # appear in --state=failed. Owning it here is what makes removing
    # libnotify-bin safe. (libnotify4, the shared library, is a separate
    # Debian package with eleven dependents and stays.)
    #
    # Unlike ExecStart=fumon -- see home/uwsm.nix -- this one resolves
    # correctly through PATH: the ExecCondition runs an absolute /bin/sh, and
    # `command -v` inside it searches the service's $PATH, where
    # ~/.nix-profile/bin precedes /usr/bin.
    libnotify

    # inotifywait and inotifywatch, as an interactive tool. Orphaned out of
    # Debian by the same uwsm removal, but on a different footing from
    # libnotify above: nothing depends on it. No installed package, and no
    # call anywhere in this repo, ~/.config or ~/.local/bin. Kept because it
    # is wanted on hand, not because anything breaks without it -- so if a
    # later cleanup wonders why this line exists, that is the whole reason.
    #
    # Note this only reaches shells that inherit the graphical session's
    # environment. A bare TTY or ssh login does not get ~/.nix-profile/bin.
    inotify-tools

    # The GTK portal backend. hyprland.portal provides only Screenshot,
    # ScreenCast and GlobalShortcuts -- every file dialog, print dialog and
    # Settings read goes through this one instead, including Chrome's and
    # Code's. Debian ships 1.15.3-1 and nixpkgs ships 1.15.3: the same
    # upstream release, with one extra interface (Wallpaper). So this is a
    # lateral move, not an upgrade.
    #
    # This line on its own changes nothing at runtime -- see the unit in
    # home/services.nix for why.
    xdg-desktop-portal-gtk

    # The portal frontend, plus xdg-document-portal and xdg-permission-store,
    # which the same package ships. Debian has 1.20.3+ds-1; the flake's pinned
    # nixpkgs has 1.20.4 -- a patch bump, re-derived from the pinned input and
    # not from `nixpkgs#`, which reports 1.22.1 and is the registry.
    #
    # As with the gtk backend, this line alone changes nothing at runtime: the
    # D-Bus activation files it brings land in ~/.nix-profile/share, which the
    # session bus does not search. The units in home/services.nix are what
    # switch each service.
    xdg-desktop-portal

    # The GL stack. nixGLIntel is the Mesa wrapper and covers AMD; it sits
    # outside nixGL's auto.* set, so it needs no --impure.
    pkgs.nixgl.nixGLIntel

    # The three families the shell is drawn in. Named here rather than in
    # spec 2 because a missing font is indistinguishable from a broken
    # renderer, and this task is where the renderer is first tested.
    adwaita-fonts
    nerd-fonts.adwaita-mono

    # The font baseline, owned here rather than inherited from Debian.
    #
    # Before this, fc-match resolved the three generic families to Debian
    # packages: sans-serif and serif to fonts-noto-core, monospace to
    # fonts-dejavu-mono. Both survive spec 7's package sweep, but only
    # incidentally -- nothing in this flake asked for them, and they are held
    # by apt reverse-dependencies that a later spec could remove. A default
    # font that exists by accident is one `apt autoremove` away from tofu in
    # every application, apt's and Nix's alike.
    #
    # This reaches Debian applications too. fontconfig is process-local, not
    # per-packaging-system: Chrome and Code read the same ~/.config/fontconfig
    # that fonts.fontconfig.enable writes below, so they see the Nix profile's
    # share/fonts. Verified before this was added -- fc-list already listed
    # Adwaita Sans and AdwaitaMono Nerd Font, which exist only in the store.
    #
    # Note this does NOT cover the two hand-copied piles under
    # ~/.local/share/fonts, neither with Home Manager symlinks among them:
    # 101 files / 164 MB of Inter and JetBrainsMono at the top level, dated
    # 2026-07-15, and 18 files / 54 MB of Adwaita under calango-desktop/,
    # dated 2026-08-01..04 (218 MB combined). Both predate the migration and
    # belong to neither apt nor Nix; they are a separate cleanup.
    noto-fonts # sans-serif and serif, plus broad script coverage
    dejavu_fonts # the family monospace currently resolves to
    liberation_ttf # Arial/Times/Courier metric substitutes, for web content

    # Not a program. A build-time assertion that rides in home.packages so it
    # runs on every generation build. See nixglSingleSource above.
    (pkgs.runCommand "nixgl-guard" { } "ln -s ${nixglSingleSource} $out")
  ];

  # Writes a fontconfig snippet (~/.config/fontconfig/conf.d/10-hm-fonts.conf)
  # pointing at the Nix profile's share/fonts. It links nothing into
  # ~/.local/share/fonts -- that directory has zero home-manager symlinks in
  # it. Because fontconfig is process-local rather than per-packaging-system,
  # both Nix and Debian applications read the same config and so find the
  # profile's fonts either way.
  fonts.fontconfig.enable = true;

  # Qt6, and so the cheapest proof that quickshell will draw in spec 2.
  services.hyprpolkitagent = {
    enable = true;
    package = hyprpolkitagent-nixgl;
  };

  programs.home-manager.enable = true;
}
