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

    # The real invariant: substitution tokens (@host@, @hyprState@, ...) are
    # lowercase-alpha, so the guard can tell them apart from wpctl's
    # UPPERCASE_WITH_UNDERSCORES @DEFAULT_AUDIO_SINK@ / @DEFAULT_AUDIO_SOURCE@
    # placeholders, which [a-zA-Z]* does not match end to end. Do not widen
    # this to digits or underscores -- that would match those too and fail
    # every build.
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

  # Absolute store paths, never bare names, EXCEPT lock_cmd below -- see its
  # comment. hypridle.service has no explicit PATH, so a bare command name
  # resolves against the default unit PATH, which is exactly what lock_cmd
  # is now deliberately relying on.
  config.services.hypridle = {
    enable = true;
    settings = {
      general = {
        # TEMPORARY REVERT to Debian's hyprlock, not Nix's. Nix's hyprlock
        # links Nix's libpam, whose module directory is compiled in as
        # /nix/store/...-linux-pam-1.7.2/lib/security. That pam_unix.so
        # calls Nix's own unix_chkpwd helper to verify the password, and
        # that helper ships as -r-xr-xr-x root root -- no setuid, no setgid
        # -- so it cannot read /etc/shadow. Debian's unix_chkpwd is
        # -rwxr-sr-x root shadow, and only NixOS's /run/wrappers provides an
        # equivalent privileged copy for Nix's; nothing on Debian does.
        # Every password is therefore rejected and hyprlock asserts and
        # crashes, locking the user out until they kill the session.
        #
        # So this points at /usr/bin/hyprlock -- Debian's build, absolute
        # and explicit so it reads as deliberate rather than a leftover bare
        # name -- with no nixGLIntel: Debian's hyprlock runs against
        # Debian's Mesa, so that wrapper is not wanted here.
        #
        # --config IS wanted, though. hyprlock searches only the XDG config
        # locations (HOME, XDG_CONFIG_HOME, XDG_CONFIG_DIRS, /etc/hypr), and
        # hyprlock.conf deliberately lives under hyprState instead: the theme
        # switcher (quickshell/theme-switcher/Theme.qml) rewrites it on every
        # theme change, and that state directory is the one place Home
        # Manager and quickshell agree writers may touch. Without --config
        # there is nothing at any of hyprlock's search paths, it exits with
        # "CRIT: Config path error", and the machine silently never locks.
        # Pointing --config at hyprState keeps that directory the single
        # canonical copy, so no second, unmanaged file has to be kept in
        # sync with it by hand.
        #
        # This BLOCKS removing trixie-backports: deleting Debian's hyprlock
        # with nothing that can authenticate in its place leaves no working
        # lock screen at all. The likely real fix is the same shape as this
        # project's hyprpolkitagent-nixgl fix in home/default.nix: override
        # nixpkgs' linux-pam so its module directory is Debian's
        # /lib/x86_64-linux-gnu/security, scoped to hyprlock's closure only,
        # so Nix's pam_unix.so calls Debian's setgid unix_chkpwd instead of
        # its own.
        lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || /usr/bin/hyprlock --config ${hyprState}/hyprlock.conf";
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
