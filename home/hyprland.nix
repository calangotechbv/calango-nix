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

  # hyprlock's static configuration. The palette is deliberately not here: the
  # quickshell theme switcher rewrites it on every theme change, so it lives in
  # state and is pulled in by the `source` below. Same split as foot -- store
  # config, state palette, store file naming the state file.
  #
  # auth:pam:module is the whole reason this file exists. hyprlock's default
  # service is "hyprlock", whose /etc/pam.d/hyprlock is `auth include login`,
  # and /etc/pam.d/login reaches pam_unix only through `@include common-auth`.
  # @include is a Debian extension that Nix's libpam does not implement --
  # measured: given /etc/pam.d/other, four @include lines and nothing else,
  # Nix's libpam attempted zero of them. Naming common-auth directly reaches
  # pam_unix through a plain `auth` line, which upstream libpam does parse.
  # Safe because hyprlock calls only pam_start and pam_authenticate
  # (src/auth/Pam.cpp:119-127) -- no pam_acct_mgmt -- so an auth-only service
  # is complete for it.
  hyprlockConfig = pkgs.writeText "hyprlock.conf" ''
    auth {
        pam {
            module = common-auth
        }
    }

    source = ${hyprState}/hyprlock.conf
  '';

  # hypridle is a systemd unit, so what it spawns inherits nothing from the
  # compositor's nixGL wrapper. Spec 3 found this the hard way: unwrapped, Nix's
  # hyprlock draws nothing and dies with
  #   CRIT: Hyprlock threw: EGL_EXT_platform_base not supported
  # Named `hyprlock` so lock_cmd's `pidof hyprlock` guard still matches.
  hyprlock-nixgl = pkgs.writeShellScriptBin "hyprlock" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel ${pkgs.hyprlock}/bin/hyprlock "$@"
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
        # Nix's hyprlock, wrapped, with the store-side config that names the PAM
        # service. The revert to /usr/bin/hyprlock that stood here since spec 3
        # is gone: flake.nix's debianPam overlay makes Nix's pam_unix call
        # Debian's setgid unix_chkpwd, so authentication works.
        #
        # The `pidof hyprlock` guard stays -- it stops a second instance when
        # the lock is already up, and matches by process name, which the wrapper
        # preserves.
        lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${hyprlock-nixgl}/bin/hyprlock --config ${hyprlockConfig}";
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

  config.home.packages = [ hyprlock-nixgl ];

  # hyprlock's `source` treats a missing target as an error, so this file must
  # exist before the first lock. The theme switcher creates it on its first
  # theme apply, which is not soon enough on a fresh machine.
  #
  # Deliberately NOT suffixed with `|| true`, matching home/foot.nix's
  # equivalent hook and for the same reason: if this cannot run, the screen
  # will not lock, and a switch that fails loudly leaves the previous
  # generation working.
  config.home.activation.hyprlockConf =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e ${lib.escapeShellArg "${hyprState}/hyprlock.conf"} ]; then
        run mkdir -p ${lib.escapeShellArg hyprState}
        run touch ${lib.escapeShellArg "${hyprState}/hyprlock.conf"}
      fi
    '';
}
