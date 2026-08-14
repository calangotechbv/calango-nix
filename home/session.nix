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

  # uwsm resolves a compositor by desktop entry, and hyprland's own
  # hyprland.desktop runs bin/start-hyprland -- unwrapped. On a foreign
  # distribution that entry cannot work: Task 6 rung 1 showed the unwrapped
  # binary dying with
  #     MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so
  #     CBackend::create() failed!
  # because Nix's Mesa looks in /run/opengl-driver/lib, a path that exists on
  # NixOS and nowhere else. So the session needs an entry of its own whose
  # Exec is the wrapper. It is added beside hyprland.desktop rather than
  # replacing it, so the unwrapped entry stays available for comparison.
  hyprland-nixgl-session = pkgs.runCommand "hyprland-nixgl-session" { } ''
    mkdir -p "$out/share/wayland-sessions"
    cat > "$out/share/wayland-sessions/hyprland-nixgl.desktop" <<EOF
    [Desktop Entry]
    Name=Hyprland (Nix)
    Comment=calango-nix, wrapped in nixGLIntel
    Exec=${hyprland-nixgl}/bin/hyprland-nixgl
    TryExec=${hyprland-nixgl}/bin/hyprland-nixgl
    DesktopNames=Hyprland
    Type=Application
    EOF
  '';
in
{
  home.packages = [ hyprland-nixgl hyprland-nixgl-session ];

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
