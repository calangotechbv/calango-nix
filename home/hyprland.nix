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

  # hyprlock's static configuration -- and the split is lopsided, so read the
  # sizes rather than assuming symmetry with foot. This store file carries
  # exactly one thing: the `auth` block below. The ENTIRE visual configuration
  # -- `general`, `animations`, `background`, `input-field` and two `label`
  # blocks, 66 lines as measured -- lives in the state file named by the `source` at the bottom, because
  # the quickshell theme switcher rewrites all of it on every theme change and
  # the store is read-only. So: store file = the PAM service name, state file =
  # everything the user actually sees.
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
  #
  # The name matters, but not for the reason an earlier draft of this comment
  # gave. It is NOT what makes lock_cmd's `pidof hyprlock` guard match: this
  # script execs away immediately, so it is never a process pidof can see --
  # the guard matches because pidof sees the final exec'd real hyprlock, which
  # is named `hyprlock` whatever this wrapper is called. What the name does do
  # is put `hyprlock` on ~/.nix-profile/bin, via writeShellScriptBin plus the
  # home.packages entry below, so an interactive `hyprlock` and the session
  # menu's Lock both reach the wrapped build rather than a bare one.
  #
  # And a bare `hyprlock`, with no --config, is a trap. Its default PAM
  # service is "hyprlock" -> /etc/pam.d/hyprlock -> `auth include login` ->
  # /etc/pam.d/login, which reaches pam_unix only through
  # `@include common-auth`. @include is a Debian extension Nix's libpam does
  # not implement (measured: zero of four @include lines attempted), so
  # pam_unix never loads and EVERY password is rejected -- an unlock-proof
  # lock screen. That is survivable today only because no hyprlock config
  # exists at any XDG path, so hyprlock falls back to built-in defaults and
  # there is nothing to make the bare invocation look supported. Do not create
  # ~/.config/hypr/hyprlock.conf; the store config named by --config below is
  # the only one that carries the working PAM service.
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

  # Absolute store paths, never bare names -- no exceptions. hypridle.service
  # has no explicit PATH, so a bare command name resolves against the default
  # unit PATH and silently picks up whatever apt happens to have installed, or
  # nothing at all.
  #
  # lock_cmd looks like a counterexample and is not: `pidof`, `hyprlock` and
  # the config are all ${...} store paths there, and the one bare `hyprlock`
  # token is pidof's ARGUMENT -- a process-name to match, not a command to
  # resolve. Nothing in this file relies on the default unit PATH.
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

  # Seeds the state file hyprlockConfig's `source` names, for the fresh-machine
  # case where the theme switcher has not yet written it.
  #
  # This is cosmetic, and the earlier version of this comment claimed otherwise
  # on two counts, both measured false:
  #
  #   1. It is NOT true that a missing `source` target stops the screen
  #      locking. hyprlock 0.9.5 against a config whose source target is absent
  #      logs `source= globbing error: found no match`, then `Config has errors
  #      ... Proceeding ignoring faulty entries`, and carries on. An error
  #      MESSAGE, not a fatal error. Without this file the screen still locks,
  #      just from hyprlock's built-in defaults.
  #   2. It is NOT true that a loud failure here leaves the previous generation
  #      working. The generated activate order is writeBoundary ->
  #      linkGeneration -> desktopDatabase -> defaultBrowser -> footThemeColors
  #      -> gtkAppearance -> hyprlockConf -> installPackages -> reloadSystemd.
  #      This hook runs AFTER linkGeneration, so aborting here leaves config
  #      symlinks already swapped, the profile not installed and systemd not
  #      reloaded -- a half-applied state, which is worse than either end.
  #
  # The hook stays, because hyprlock's built-in defaults render no input field
  # and an empty state file beats that. But it is `|| warnEcho`, not fatal:
  # home/foot.nix's hook is fatal for a reason that genuinely holds there
  # (foot's `include=` really does refuse to start on a missing target); that
  # reason does not hold here, and a cosmetic step must not be able to abort a
  # switch mid-linkGeneration.
  config.home.activation.hyprlockConf =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e ${lib.escapeShellArg "${hyprState}/hyprlock.conf"} ]; then
        run mkdir -p ${lib.escapeShellArg hyprState} \
          && run touch ${lib.escapeShellArg "${hyprState}/hyprlock.conf"} \
          || warnEcho "could not seed ${hyprState}/hyprlock.conf; the lock screen will render from hyprlock's built-in defaults until the theme switcher writes it"
      fi
    '';
}
