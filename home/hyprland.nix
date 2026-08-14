{ config, lib, pkgs, ... }:

let
  # The state directories these paths point at. Declared here rather than
  # inline so the module and the substitutions cannot drift apart.
  hyprState = "${config.home.homeDirectory}/.local/state/hypr";
  quickshellState = "${config.home.homeDirectory}/.local/state/quickshell";

  hyprConfig = pkgs.runCommand "hypr-config" { } ''
    cp -r ${./../hypr} "$out"
    chmod -R u+w "$out"

    substituteInPlace "$out/hyprland.lua" \
      --replace-fail '@hyprSource@'      "$out" \
      --replace-fail '@host@'            '${config.calango.host}' \
      --replace-fail '@quickshellState@' '${quickshellState}'
    # @hyprState@ appears three times, so --replace-fail's single-occurrence
    # guarantee does not apply; --replace is correct here and the count is
    # asserted immediately afterwards instead.
    substituteInPlace "$out/hyprland.lua" \
      --replace '@hyprState@' '${hyprState}'

    if grep -q '@[a-zA-Z]*@' "$out/hyprland.lua"; then
      echo "unsubstituted token left in hyprland.lua:" >&2
      grep -n '@[a-zA-Z]*@' "$out/hyprland.lua" >&2
      exit 1
    fi
  '';

  # idle-sleep.sh shells out to sleep, cat, printf, rm, test, systemctl,
  # loginctl, busctl, grep, awk and pkill. hypridle.service has no explicit
  # PATH, so each of those is a silent failure waiting to happen -- the
  # machine simply never suspends, with nothing in the journal to say why.
  idleSleepPath = lib.makeBinPath (with pkgs; [
    coreutils systemd gnugrep gawk procps
  ]);

  idleSleep = pkgs.writeShellScriptBin "idle-sleep" ''
    export PATH=${idleSleepPath}''${PATH:+:$PATH}
    exec ${config.calango.hyprConfig}/idle-sleep.sh "$@"
  '';
in
{
  options.calango = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Which hosts/<name>.lua this configuration bakes in.";
    };
    hyprConfig = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The Hyprland config tree, in the store.";
    };
  };

  config.calango.hyprConfig = hyprConfig;

  # The only thing Home Manager may own under the state directory. Anything
  # more would become a read-only store symlink, and quickshell writes all
  # four of these files at runtime.
  config.home.file.".local/state/hypr/.keep".text = "";

  # Absolute store paths, never bare names. hypridle.service has no explicit
  # PATH, so a bare `hyprlock` resolves against the default unit PATH and
  # finds Debian's /usr/bin/hyprlock -- which disappears when spec 6 removes
  # trixie-backports, taking the lock screen with it and saying nothing.
  config.services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
        before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
        after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
        }
        {
          timeout = 330;
          on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
          on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
        }
        {
          timeout = 900;
          on-timeout = "${idleSleep}/bin/idle-sleep";
          on-resume = "${idleSleep}/bin/idle-sleep --cancel";
        }
      ];
    };
  };
}
