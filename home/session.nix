{ pkgs, ... }:

let
  # Wrap the compositor itself rather than the caller. A wrapper on the
  # binary survives being launched by uwsm through a systemd unit, which a
  # wrapper on the session entry may not -- a unit does not inherit the
  # environment of whoever invoked uwsm unless uwsm exports it. Task 6
  # measures which of the two is actually needed.
  # The binary is spelled Hyprland here. nixpkgs 26.05 ships both spellings in
  # bin/, so either works; Hyprland is the one calango-desktop's DEPS table
  # probes for first.
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
