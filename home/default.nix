{ pkgs, ... }:

let
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
  # This generalises: every Nix GUI application on this machine needs the
  # wrapper, quickshell in spec 2 included. Only the compositor was in spec 1's
  # sights, which is why it took a crash to notice.
  nixglWrap =
    name: exe:
    pkgs.writeShellScript name ''
      exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel ${exe} "$@"
    '';

  hyprpolkitagent-nixgl = pkgs.runCommand "hyprpolkitagent-nixgl" { } ''
    mkdir -p "$out/libexec"
    ln -s ${
      nixglWrap "hyprpolkitagent" "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
    } "$out/libexec/hyprpolkitagent"
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
