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
    # ydotool is dev tier and belongs to spec 3.

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

  # Qt6, and so the cheapest proof that quickshell will draw in spec 2.
  services.hyprpolkitagent = {
    enable = true;
    package = hyprpolkitagent-nixgl;
  };

  programs.home-manager.enable = true;
}
