{ config, lib, pkgs, ... }:

let
  # The PATH that *launched applications* are resolved against. It is not this
  # unit's PATH and must not be confused with runtimeDeps below -- that list
  # answers "what does the shell run?", and this one answers "what can the
  # shell's users run?". One list was made to serve both, and 92 of 214 desktop
  # entries did not launch as a result: `systemd-run` resolves the executable in
  # its own process, against its own PATH, before it creates the unit, so an
  # entry whose Exec is a bare `foot` was handed to a PATH assembled to satisfy
  # `awk` and `nmcli`. See docs/2026-08-15-handover-suffer-applications-panel-launch.md.
  #
  # Session directories, not store paths, and deliberately so: these are the
  # directories a desktop entry's author could reasonably expect, and the same
  # ones a login shell has. They are strings rather than package outputs because
  # /usr/bin's contents are apt's business and no Nix expression can name them.
  #
  # Widened HERE and not in the unit's own PATH. Two `command -v` probes in the
  # shell are load-bearing and fail on purpose -- ddcutil in
  # brightness/BrightnessService.qml and swww in wallpaper/WallpaperService.qml
  # (both recorded in runtimeDeps' comment below). Putting /usr/bin on the
  # unit's PATH would make both start finding Debian's copies, which is a
  # behaviour change nobody asked for. This placement avoids the question.
  appPath = lib.concatStringsSep ":" [
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/games"
  ];

  # matugen reads its own TOML and cannot expand $dir the way set.sh does, so
  # input_path has to be an absolute store path -- which is not known until
  # this derivation is being built. That is why this one file is patched
  # rather than left alone. Note the two lines point opposite ways on
  # purpose: the template is source and lives in the store, the output is
  # state.
  #
  # substituteInPlace with --replace-fail rather than a blind `cat >`
  # heredoc: the checked-in config.toml carries the @quickshellStore@ /
  # @quickshellState@ placeholders as its honest, readable source, and
  # --replace-fail means a line that gets renamed or moved upstream fails
  # this build loudly instead of being silently overwritten with a heredoc
  # that never looked at what it was replacing. AppLaunch.qml's @appPath@
  # is substituted the same way and for the same reason.
  quickshellConfig = pkgs.runCommand "quickshell-config" { } ''
    cp -r ${./../quickshell} "$out"
    chmod -R u+w "$out"

    substituteInPlace "$out/theme-switcher/wallpaper-theme/matugen/config.toml" \
      --replace-fail "@quickshellStore@" "$out" \
      --replace-fail "@quickshellState@" "~/.local/state/quickshell"

    substituteInPlace "$out/common/AppLaunch.qml" \
      --replace-fail "@appPath@" '${appPath}'

    # Assert the substituted list still contains the two directories that carry
    # the applications, by content rather than by trusting the Nix list above.
    #
    # /usr/bin is where every apt application lives, and ~/.nix-profile/bin is
    # where every migrated one lives. A list that lost either would leave a
    # whole provenance unlaunchable, and the symptom is silence: the panel
    # closes and nothing opens. That is precisely how this went unnoticed for a
    # day.
    #
    # Checked against the FILE after substitution, not against the Nix
    # expression, so a substitution that failed to land is caught here too.
    #
    # It reads the appPath PROPERTY'S VALUE and compares whole `:`-separated
    # elements. The first version of this guard grepped the whole file for the
    # directory and was vacuous, because AppLaunch.qml's own comments contain
    # the literal `/usr/bin` -- one of them explains that quickshell.service's
    # PATH "has no /usr/bin" -- so the guard matched its own prose. Proven by
    # mutation: with `/usr/bin` deleted from the Nix list, the build passed.
    # A check that cannot fail is the third of this shape in this project, and
    # the only reason this one was caught is that it was mutated before it was
    # trusted.
    #
    # Whole-element comparison, not a substring: `/usr/bin` is a substring of
    # nothing else in this list today, but `/bin` is a substring of four of the
    # six, so a substring test would go on passing after the wrong deletion.
    #
    # `if ! grep -q` and an explicit `found` flag, NOT
    # `n="$(grep -c ...)"`. A Nix builder runs
    # with `set -e` and `pipefail` both on -- measured: `echo $-` gives `ehB`
    # and `set -o` reports `pipefail on`. So `grep -c` returning 1 for zero
    # matches aborts the assignment before any message prints, and a
    # `grep | wc -l` pipeline aborts on grep's status instead of yielding 0.
    # CLAUDE.md's rule to count explicitly rather than trust an empty pipeline
    # is about an interactive shell; inside a builder that same shape fails the
    # build for the wrong reason and with no diagnostic.
    val="$(sed -n 's/^ *readonly property string appPath: "\(.*\)"$/\1/p' \
             "$out/common/AppLaunch.qml")"
    if [ -z "$val" ]; then
      echo "Could not read appPath's value out of AppLaunch.qml." >&2
      echo "  The property was renamed or reformatted, so this guard is" >&2
      echo "  reading nothing and would pass vacuously. Fix the sed above." >&2
      exit 1
    fi

    for d in /usr/bin '${config.home.homeDirectory}/.nix-profile/bin'; do
      found=0
      oldIFS="$IFS"; IFS=":"
      for e in $val; do
        [ "$e" = "$d" ] && found=1
      done
      IFS="$oldIFS"
      if [ "$found" -eq 0 ]; then
        echo "AppLaunch.qml's appPath does not contain $d." >&2
        echo "  value: $val" >&2
        echo "  Applications resolved against it would not be found, and the" >&2
        echo "  panel reports that by closing and doing nothing at all." >&2
        echo "  /usr/bin carries every apt application and" >&2
        echo "  ~/.nix-profile/bin every migrated one, so losing either" >&2
        echo "  makes a whole provenance unlaunchable." >&2
        echo "  See home/quickshell.nix's appPath." >&2
        exit 1
      fi
    done

    # No @token@ may survive anywhere in the tree. Same guard and same invariant
    # as home/foot.nix and home/hyprland.nix: substitution tokens are
    # lowercase-alpha, so [a-zA-Z]* cannot match end to end against an
    # UPPERCASE placeholder. Enumerated by syntax over the whole copied tree
    # rather than by re-listing the files known to carry tokens -- which is the
    # rule this repo has paid for twice, and the reason appPath's own
    # placeholder cannot be forgotten here.
    if grep -rq '@[a-zA-Z]*@' "$out"; then
      echo "unsubstituted token left in the quickshell tree:" >&2
      grep -rn '@[a-zA-Z]*@' "$out" >&2
      exit 1
    fi
  '';

  # Everything the QML invokes by bare name. A systemd user unit gets a
  # minimal PATH and nothing on this machine adds the Nix profile to it, so
  # each of these is a runtime failure if omitted -- and a silent one: the
  # feature simply stops working, with no error anywhere.
  #
  # Derived by grepping the whole quickshell/ tree for every external command
  # it can invoke -- QML `command:`/`.command = ` Process arrays, the `sh -c`
  # strings inside them, and the .sh and .py scripts those in turn call --
  # rather than transcribed from a design document's table, which is how six
  # of these (grep, sed, awk, top/ps/pgrep, nmcli, uwsm) went missing the
  # first time and broke silently. See docs/superpowers/sdd/2026-08-14-quickshell
  # /final-fix-report.md for the full command-by-file derivation.
  runtimeDeps = with pkgs; [
    brightnessctl                                 # OSD, brightness keys
    cliphist                                      # clipboard picker (list/decode/delete)
    wl-clipboard                                  # clipboard picker (wl-copy)
    swaybg                                        # wallpaper
    glib                                          # gio (browser discovery), gsettings (theme switcher)
    libnotify                                     # notifications
    jq                                            # theme switcher, night-light locate.sh
    matugen                                       # wallpaper-derived theming
    wallust                                       # the matugen fallback
    curl                                          # night-light locate.sh geolocation
    hyprland                                      # hyprctl (monitors, layout, borders, blur)
    systemd                                       # systemctl, loginctl, systemd-run
    uwsm                                          # session/SessionMenu.qml "Log out"
    networkmanager                                # nmcli, bar/SystemInfo.qml network pill
    gnugrep                                       # grep, throughout bar/SystemInfo.qml, SystemPanel.qml, MonitorService.qml
    gnused                                        # sed, bar/SystemInfo.qml CPU pill
    gawk                                          # awk, bar/SystemInfo.qml, bar/SystemPanel.qml
    procps                                        # top (CPU pill), ps/pgrep (SystemPanel sampler, WallpaperService)
    findutils                                     # find, wallpaper/WallpaperService.qml scanner
    util-linux                                    # setsid, common/AppLaunch.qml, wallpaper/WallpaperService.qml
    bash coreutils                                # sh, cat, ls, sort, head, cut, mktemp, mv, dirname, ...
    (python3.withPackages (ps: [ ps.pillow ]))    # wallpaper/generate-abstract.py only.
                                                   # discover.py's own imports are stdlib
                                                   # only (configparser, json, os, re,
                                                   # shlex, subprocess, tempfile) -- see
                                                   # home/apps.nix's comment on
                                                   # calangoOpenPath, which reads
                                                   # discover.py end to end. pillow stays
                                                   # in this closure for generate-abstract.py.
    # NOT ddcutil: brightness/BrightnessService.qml's DDC backend self-guards
    # with `command -v ddcutil`, so omitting it fails silently-clean rather
    # than breaking. Enabling it needs i2c-dev group setup, out of scope here.
    # NOT swww: wallpaper/WallpaperService.qml probes for it and falls back to
    # swaybg. Deliberately absent from nixpkgs' search index as of this port
    # (see docs/superpowers/specs/2026-08-14-base-and-session-design.md), so
    # there is nothing to add; the probe's `command -v` fallback is the point.
    # NOT kitty: this project installs foot, not kitty (see
    # docs/superpowers/plans/2026-08-14-base-and-session.md), and nothing
    # under quickshell/ invokes a `kitty` binary any more -- the theme
    # switcher's old kitty-socket code path (applyKittyTheme) was deleted
    # along with kitty itself. Adding the package would just be installing an
    # unused terminal emulator to satisfy a PATH nothing reaches.
  ];

  # Qt Quick builds its scenegraph on first window show. Unwrapped, this unit
  # would reach "active (running)" and then abort with status=6/ABRT the
  # moment the bar tried to map -- exactly what hyprpolkitagent did in spec 1.
  quickshell-nixgl = pkgs.writeShellScript "quickshell-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
      ${pkgs.quickshell}/bin/quickshell "$@"
  '';
in
{
  options.calango.quickshellConfig = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The quickshell config tree, in the store.";
  };

  config.calango.quickshellConfig = quickshellConfig;

  # So `qs ipc call ...` (shell.qml, set.sh's header comment, and hyprland.lua's
  # keybinds) is reachable from an interactive terminal, not just from inside
  # the wrapped quickshell.service ExecStart above.
  config.home.packages = [ pkgs.quickshell ];

  # The stable path both halves of the IPC handshake resolve through, and the
  # reason quickshell.service passes no -p.
  #
  # It used to run with `-p <store path>`, and home/session.nix exported the
  # matching QS_CONFIG_PATH so the compositor's `qs ipc call` binds could find
  # it. That handshake was correct only for as long as the store path did not
  # change -- and it changes on any edit to the quickshell tree. The compositor
  # exports the variable once, at session start; the service restarts on the new
  # hash at the next `home-manager switch`. The two then name different paths,
  # `qs ipc call` reports "No running instances for <old path>/shell.qml", and
  # all fifteen IPC binds die silently until the user logs out. Measured, not
  # theorised: a one-line change to theme-switcher/Theme.qml did exactly this.
  #
  # A name resolves that: quickshell reads ~/.config/quickshell/shell.qml with no
  # arguments at all, so both the unit and every `qs` invocation go through this
  # symlink, and a switch retargets it atomically for both at once. There is no
  # environment variable left to go stale.
  #
  # Safe as a read-only store symlink because nothing writes here -- the shell's
  # runtime state lives under ~/.local/state/quickshell (see home.file below).
  # That was not true when spec 2 chose the store path, which is why it chose it.
  config.xdg.configFile."quickshell".source = quickshellConfig;

  # The only thing Home Manager may own under the state directory. A .keep
  # forces the parent to be created as a real directory; anything more would
  # make a state file a read-only store symlink, which is the failure this
  # whole spec exists to avoid.
  #
  # The directories must exist before quickshell writes: every write is a bare
  # `printf > path` with no mkdir, and a missing directory fails silently.
  config.home.file = {
    ".local/state/quickshell/.keep".text = "";
    ".local/state/quickshell/theme-switcher/.keep".text = "";
  };

  config.systemd.user.services.quickshell = {
    Unit = {
      Description = "Quickshell shell";
      Documentation = "https://quickshell.outfoxxed.me";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # Carried over from calango-desktop's unit. Under uwsm the race this
      # once guarded cannot happen, and it stays as a statement of what the
      # unit needs rather than as a guard.
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "simple";
      # No -p. quickshell finds ~/.config/quickshell/shell.qml on its own, and
      # that path is the xdg.configFile symlink below. See its comment for why
      # a store path here was actively harmful.
      ExecStart = "${quickshell-nixgl}";
      Environment = [
        "PATH=${lib.makeBinPath runtimeDeps}"
        # Without this, the theme switcher's `gsettings set
        # org.gnome.desktop.interface color-scheme ...` -- the dark/light
        # handoff gtk/appearance.conf deliberately delegates to quickshell,
        # see that file's comment -- writes to Nix glib's default
        # GKeyfileSettingsBackend (~/.config/glib-2.0/settings/keyfile)
        # instead of dconf, because Nix's glib ships no GSettings backend
        # modules of its own. dconf is what the portal, libadwaita and every
        # Debian GTK app actually read. Same defect, same fix, as
        # home/gtk.nix's apply-gtk-theme wrapper.
        "GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules"
      ];
      Restart = "on-failure";
      RestartSec = 2;
      Slice = "app.slice";
      # Was hypr/systemd/quickshell.service.d/killmode.conf in calango-desktop.
      # A drop-in exists to patch a unit you do not control; Home Manager
      # generates this one, so the setting belongs on it directly.
      KillMode = "process";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
